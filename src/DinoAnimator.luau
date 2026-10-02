--[[
	DinoAnimator.luau
	Type:  ModuleScript
	Path:  ReplicatedStorage.DinoAnimator

	Pure procedural animation for a rigged dinosaur model. Given the model and
	a time value, this computes every joint's pose for that instant -- no
	animation clips are used. Walking, breathing, blinking, the jaw, and the
	tail are generated from sine waves and eased interpolation.

	Because every pose is a function of a single synced time value, every
	client (and the server) renders the exact same pose at the same moment
	without needing to replicate per-frame joint state.

	Expected rig (Motor6D names), all parented under Workspace.Dinosaur:
		Root (PrimaryPart, anchored, invisible anchor for the whole rig)
		 └ Torso (Motor6D "Torso")
		    ├ Neck1 (Motor6D "Neck1") -> Neck2 ("Neck2") -> Skull ("Head")
		    │   └ Skull: Jaw ("Jaw"), LidUpR/LidUpL/LidLoR/LidLoL (eyelids)
		    ├ ThighR/L ("HipR"/"HipL") -> ShinR/L ("KneeR"/"KneeL")
		    │        -> FootR/L ("AnkleR"/"AnkleL")
		    ├ UpperArmR/L ("ShoulderR"/"ShoulderL") -> ForeArmR/L ("ElbowR"/"ElbowL")
		    └ Tail1..Tail8 ("Tail1".."Tail8")
	Every Motor6D must have a "BaseC0" CFrame Attribute set to its rest-pose
	C0 (set this once when the rig is built; see the model-export note in
	the README for how the model itself was created).
]]

local M = {}

-- ===================== Tunable gait / timing constants =====================
local SPEED  = 6                 -- studs walked per second
local STRIDE = 9                 -- studs covered per full leg-swing cycle
local SEG    = 84                -- studs walked before stopping to rest
local W      = SEG / SPEED + 1   -- seconds spent walking per cycle
local P      = 8                 -- seconds spent resting (yawn / roar / sniff)
local T      = W + P             -- full cycle length (walk + rest)
local ROAR_EASE = 0.9            -- seconds to slow to a stop / speed back up around a commanded roar

M.ROAR_LEN   = 5.0                       -- how long a commanded roar holds the dinosaur still
M.FREEZE_LEN = 2 * ROAR_EASE + 5.0       -- total time the walk-clock is paused for a commanded roar
M.COOLDOWN   = 8                         -- seconds before another roar can be triggered

-- Smoothstep: eases a 0..1 value in and out instead of moving linearly.
local function smooth(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Integral of smooth(), used to turn an eased *speed* into eased *distance*,
-- so starting/stopping a walk accelerates and decelerates naturally.
local function F(x)
	return x ^ 3 - x ^ 4 / 2
end

-- Converts elapsed time in a cycle into distance travelled, with ease-in at
-- the start of a walk and ease-out just before resting.
local function walkDistance(t)
	local n = math.floor(t / T)
	local u = math.min(t - n * T, W)
	local I
	if u <= 1 then
		I = F(u)
	elseif u <= W - 1 then
		I = 0.5 + (u - 1)
	else
		I = 0.5 + (W - 2) + (0.5 - F(W - u))
	end
	return SPEED * (n * (W - 1) + I)
end

-- ===================== Commanded-roar clock =====================
-- The server can force a roar at any time by setting the dinosaur's "Clock"
-- attribute to "pausedBefore,freezeStart,freezeLen". This function decodes
-- that string and returns the dinosaur's *internal* animation clock, which
-- smoothly slows to a stop, holds during the roar, then speeds back up --
-- all derived from real time, so it replicates with zero extra network cost.
local function parseClock(s)
	if type(s) ~= "string" then return 0, 0, 0 end
	local a, b, c = string.match(s, "^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
	return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end
M.parseClock = parseClock

local function clockState(t, pausedBefore, freezeStart, freezeLen)
	local lostTime, speed, roarClock = 0, 1, nil
	if freezeLen > 0 then
		if t >= freezeStart + freezeLen then
			lostTime = freezeLen - ROAR_EASE
		elseif t >= freezeStart then
			local elapsed = t - freezeStart
			if elapsed < ROAR_EASE then
				local x = elapsed / ROAR_EASE
				lostTime = ROAR_EASE * F(x)
				speed = 1 - smooth(x)
			elseif elapsed < freezeLen - ROAR_EASE then
				lostTime = 0.5 * ROAR_EASE + (elapsed - ROAR_EASE)
				speed = 0
			else
				local x = (elapsed - (freezeLen - ROAR_EASE)) / ROAR_EASE
				lostTime = 0.5 * ROAR_EASE + (freezeLen - 2 * ROAR_EASE) + ROAR_EASE * (x - F(x))
				speed = smooth(x)
			end
			roarClock = elapsed - ROAR_EASE -- 0 once the body has fully stopped
		end
	end
	return t - pausedBefore - lostTime, speed, roarClock
end

-- ===================== Patrol route (Catmull-Rom spline) =====================
-- Builds a smooth closed loop through randomized waypoints, rejecting any
-- layout that is too tight to walk or leaves the play area.
local BOUND = 110
local pathPoints, cumulativeDist, totalLength

local function catmullRom(p0, p1, p2, p3, s)
	local s2, s3 = s * s, s * s * s
	return 0.5 * (
		(2 * p1)
		+ (p2 - p0) * s
		+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * s2
		+ (3 * p1 - p0 - 3 * p2 + p3) * s3
	)
end

local function tryBuildRoute(seed)
	local rng = Random.new(seed)
	local waypoints, guard = {}, 0
	while #waypoints < 18 and guard < 4000 do
		guard += 1
		local p = Vector3.new(rng:NextNumber(-BOUND, BOUND), 0, rng:NextNumber(-BOUND, BOUND))
		local ok = p.Magnitude > 30
		if ok and #waypoints > 0 then
			ok = (p - waypoints[#waypoints]).Magnitude > 60
			if ok and #waypoints > 1 then
				ok = (waypoints[#waypoints] - waypoints[#waypoints - 1]).Unit:Dot((p - waypoints[#waypoints]).Unit) > 0.1
			end
		end
		if ok then table.insert(waypoints, p) end
	end
	if #waypoints < 18 or (waypoints[1] - waypoints[#waypoints]).Magnitude < 60 then
		return nil
	end

	local n, samples = #waypoints, {}
	for i = 1, n do
		local p0 = waypoints[(i - 2) % n + 1]
		local p1 = waypoints[i]
		local p2 = waypoints[i % n + 1]
		local p3 = waypoints[(i + 1) % n + 1]
		for k = 0, 29 do
			table.insert(samples, catmullRom(p0, p1, p2, p3, k / 30))
		end
	end

	local m, total, cum = #samples, 0, { 0 }
	local minTurnRadius, minDistFromCentre = math.huge, math.huge
	for i = 1, m do
		local a, b = samples[i], samples[i % m + 1]
		total += (b - a).Magnitude
		if i < m then cum[i + 1] = total end
		minDistFromCentre = math.min(minDistFromCentre, Vector3.new(a.X, 0, a.Z).Magnitude)
		if math.abs(a.X) > 135 or math.abs(a.Z) > 135 then return nil end
	end
	for i = 1, m do
		local prev, cur, nxt = samples[(i - 2) % m + 1], samples[i], samples[i % m + 1]
		local d1, d2 = cur - prev, nxt - cur
		if d1.Magnitude > 0.01 and d2.Magnitude > 0.01 then
			local turnAngle = math.acos(math.clamp(d1.Unit:Dot(d2.Unit), -1, 1))
			if turnAngle > 1e-4 then
				minTurnRadius = math.min(minTurnRadius, ((d1.Magnitude + d2.Magnitude) / 2) / turnAngle)
			end
		end
	end
	if minTurnRadius < 16 or minDistFromCentre < 10 then return nil end
	return samples, cum, total
end

for seed = 1, 400 do
	local pts, cum, len = tryBuildRoute(20260920 + seed)
	if pts then
		pathPoints, cumulativeDist, totalLength = pts, cum, len
		break
	end
end
if not pathPoints then
	-- Fallback: a plain circle, in case no random layout validated.
	pathPoints, cumulativeDist, totalLength = {}, { 0 }, 0
	for i = 0, 119 do
		local a = i / 120 * math.pi * 2
		table.insert(pathPoints, Vector3.new(math.cos(a) * 70, 0, math.sin(a) * 70))
	end
	for i = 1, #pathPoints do
		totalLength += (pathPoints[i % #pathPoints + 1] - pathPoints[i]).Magnitude
		if i < #pathPoints then cumulativeDist[i + 1] = totalLength end
	end
end

-- Binary search: the point on the route at a given distance travelled.
local function pointAtDistance(d)
	d = d % totalLength
	local lo, hi = 1, #pathPoints
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if cumulativeDist[mid] <= d then lo = mid else hi = mid - 1 end
	end
	local a, b = pathPoints[lo], pathPoints[lo % #pathPoints + 1]
	local segLen = (lo == #pathPoints) and (totalLength - cumulativeDist[lo]) or (cumulativeDist[lo + 1] - cumulativeDist[lo])
	local frac = segLen > 0 and (d - cumulativeDist[lo]) / segLen or 0
	return a:Lerp(b, frac)
end
M.pathAt = pointAtDistance
M.pathLength = function() return totalLength end

-- Where is the dinosaur right now? Used by the server for proximity checks
-- without needing to bind the whole rig.
function M.samplePosition(t, clockAttr)
	local pausedBefore, freezeStart, freezeLen = parseClock(clockAttr)
	local tau = clockState(t, pausedBefore, freezeStart, freezeLen)
	return pointAtDistance(walkDistance(tau % 100000))
end

-- ===================== Eyelids =====================
-- Independent upper + lower lids per eye, each sliding out of the skull.
local function blink(t)
	local b = 0
	for _, period in ipairs({ 3.7, 5.3 }) do -- two offset timers so both eyes don't blink in lockstep
		local x = (t % period) / 0.22
		if x < 1 then b = math.max(b, math.sin(math.pi * x)) end
	end
	return b
end

-- Lid travel curves: 2D offset (studs) at closure amount p in [0, 1].
local UPPER_A, UPPER_B, UPPER_C = Vector2.new(-0.75, 0.40), Vector2.new(-0.10, 0.62), Vector2.new(0, 0.20)
local LOWER_A, LOWER_B = Vector2.new(-0.55, -0.85), Vector2.new(0, -0.22)

local function upperLidOffset(p)
	local pos
	if p < 0.45 then pos = UPPER_A:Lerp(UPPER_B, p / 0.45)
	else pos = UPPER_B:Lerp(UPPER_C, (p - 0.45) / 0.55) end
	return pos - UPPER_A
end
local function lowerLidOffset(p)
	return LOWER_A:Lerp(LOWER_B, p) - LOWER_A
end

-- ===================== Rig binding =====================
function M.bind(model)
	local rig = { model = model, root = model.PrimaryPart, joints = {} }
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			rig.joints[d.Name] = { motor = d, restPose = d:GetAttribute("BaseC0") or d.C0 }
		end
	end
	rig.center = model:GetAttribute("Center") or Vector3.zero
	rig.groundY = model:GetAttribute("GroundY") or 0
	return rig
end

function M.reset(rig)
	for _, j in pairs(rig.joints) do
		j.motor.C0 = j.restPose
	end
end

-- Applies a pose on top of a joint's rest pose for this frame.
-- rx/ry/rz = rotation (radians), dx/dy/dz = translation (studs), all local.
local function pose(rig, jointName, rx, ry, rz, dx, dy, dz)
	local j = rig.joints[jointName]
	if not j then return end
	j.motor.C0 = j.restPose * CFrame.new(dx or 0, dy or 0, dz or 0) * CFrame.Angles(rx or 0, ry or 0, rz or 0)
end

-- ===================== Main update: pure f(rig, t) -> applies a full pose =====================
-- extra (optional): { loudness = <0..~300> } live mic loudness of the roar
-- sound, used to make the jaw open in sync with how loud the roar actually is.
-- Returns a small info table describing the current state (used by the
-- client for dust, camera shake, and the HUD/name-tag text).
function M.update(rig, t, extra)
	local pausedBefore, freezeStart, freezeLen = parseClock(rig.model:GetAttribute("Clock"))
	local tauRaw, speed, roarClock = clockState(t, pausedBefore, freezeStart, freezeLen)
	local tt = tauRaw % 100000
	local cycle = math.floor(tt / T)
	local u = tt - cycle * T

	-- Walk-weight: 0 at rest, 1 while walking, eased at the edges, and
	-- additionally scaled down while a commanded roar is slowing the body.
	local walkWeight0
	if u < 1 then walkWeight0 = smooth(u)
	elseif u < W - 1 then walkWeight0 = 1
	elseif u < W then walkWeight0 = smooth(W - u)
	else walkWeight0 = 0 end
	local walkWeight = walkWeight0 * speed

	local dist = walkDistance(tt)
	local stridePhase = dist * 2 * math.pi / STRIDE

	-- Scheduled rest behaviour: even cycles roar, odd cycles sniff; both yawn first.
	local restTime = u - W
	local isRoarCycle = (cycle % 2 == 0)
	local scheduledRoar, sniff = 0, 0
	if restTime > 0 then
		if isRoarCycle then
			scheduledRoar = smooth((restTime - 3.2) / 0.5) * smooth((7.2 - restTime) / 0.9)
		else
			sniff = smooth((restTime - 3) / 0.6) * smooth((7 - restTime) / 0.6)
		end
	end
	local yawnX = (restTime - 0.8) / 1.8
	local yawn = (restTime > 0 and yawnX > 0 and yawnX < 1) and math.sin(math.pi * yawnX) or 0

	-- Commanded roar (server sets the Clock attribute).
	local commandedRoar = 0
	if roarClock and roarClock >= 0 then
		local roarDuration = freezeLen - 2 * ROAR_EASE
		commandedRoar = smooth(roarClock / 0.45) * smooth((roarDuration - roarClock) / 0.8)
	end
	local roar = math.max(scheduledRoar, commandedRoar)
	local breath = math.sin(t * 2.0)
	local loudness = (extra and extra.loudness) or 0

	-- Placement along the route, facing the direction of travel.
	local pos = pointAtDistance(dist) + rig.center + Vector3.new(0, rig.groundY, 0)
	local ahead1, ahead2 = pointAtDistance(dist - 2.5), pointAtDistance(dist + 2.5)
	local facing = Vector3.new(ahead2.X - ahead1.X, 0, ahead2.Z - ahead1.Z)
	if facing.Magnitude < 1e-4 then facing = Vector3.new(0, 0, -1) end
	facing = facing.Unit

	-- Turn rate (positive = turning left), used to lean the body into curves.
	local back, forward = pointAtDistance(dist) - pointAtDistance(dist - 4), pointAtDistance(dist + 4) - pointAtDistance(dist)
	local turnCurvature = 0
	if back.Magnitude > 0.01 and forward.Magnitude > 0.01 then
		turnCurvature = back.Unit:Cross(forward.Unit).Y / 4
	end
	local turnRate = math.clamp(turnCurvature * SPEED * walkWeight, -0.6, 0.6)

	local base = CFrame.lookAt(pos, pos + facing)
	local bob = 0.22 * walkWeight * math.cos(2 * stridePhase) + 0.05 * breath
	local roll = 0.04 * walkWeight * math.sin(stridePhase) + math.clamp(0.5 * turnRate, -0.1, 0.1)
	rig.root.CFrame = base * CFrame.new(0, 7 + bob, 0) * CFrame.Angles(0, 0, roll)

	-- Torso
	local torsoPitch = 0.025 * breath + 0.05 * walkWeight * math.sin(2 * stridePhase + 0.6) + 0.22 * roar
	local torsoYaw = 0.07 * walkWeight * math.sin(stridePhase) + math.clamp(0.35 * turnRate, -0.15, 0.15)
	pose(rig, "Torso", torsoPitch, torsoYaw, 0.03 * walkWeight * math.sin(stridePhase))

	-- Neck + head: looks around, leads into turns, rears up + thrusts forward on a roar, dips to sniff.
	local look = (0.45 * math.sin(t * 0.55) + 0.2 * math.sin(t * 1.3 + 1)) * (1 - 0.7 * walkWeight) * (1 - roar)
		+ math.clamp(1.4 * turnRate, -0.5, 0.5)
	local headPitch = -torsoPitch * 0.8 + 0.30 * roar + 0.05 * roar * math.sin(t * 9) + 0.04 * breath
		+ 0.05 * walkWeight * math.sin(2 * stridePhase + 1.8) + 0.06 * math.sin(t * 0.9) * (1 - walkWeight)
		- 0.34 * sniff + 0.04 * sniff * math.sin(t * 7)
	local thrust = -0.4 * roar * (0.5 + 0.5 * math.sin(t * 4.5))
	pose(rig, "Neck1", 0.35 * headPitch, 0.30 * look, 0, 0, 0, thrust)
	pose(rig, "Neck2", 0.35 * headPitch, 0.30 * look, 0, 0, 0, thrust * 0.6)
	pose(rig, "Head", 0.30 * headPitch, 0.40 * look, 0)

	-- Jaw: opens for walking/yawning/sniffing, and wide + loudness-driven during a roar.
	-- (front-down rotation is negative X; capped so it never over-rotates)
	local open = 0.03 + 0.015 * breath + 0.03 * walkWeight * math.sin(2 * stridePhase) + 0.42 * yawn
		+ roar * (0.46 + 0.08 * math.sin(t * 9) + 0.05 * math.sin(t * 23))
		+ 0.30 * roar * math.clamp(loudness / 280, 0, 1)
		+ 0.06 * sniff * (0.5 + 0.5 * math.sin(t * 5))
	pose(rig, "Jaw", -math.min(open, 0.9))

	-- Eyelids: independent upper/lower, with blinking, droop, and roar/yawn/sniff squint.
	local droop = 0.22 - 0.12 * walkWeight
	local upperClose = droop + 0.8 * yawn + 0.45 * roar + 0.3 * sniff
	local lowerClose = 0.5 * yawn + 0.35 * roar
	for side, sign in pairs({ R = 1, L = -1 }) do
		local b = blink(t + (side == "R" and 0 or 0.035))
		-- An optional per-eye manual override (0..1), e.g. for cutscenes: set the
		-- "EyeCloseR"/"EyeCloseL" NumberAttribute on the model.
		local override = rig.model:GetAttribute("EyeClose" .. side)
		local up, lo
		if type(override) == "number" then
			up, lo = override, override
		else
			up, lo = math.max(b, upperClose), math.max(b, lowerClose)
		end
		local upOff = upperLidOffset(math.clamp(up, 0, 1))
		local loOff = lowerLidOffset(math.clamp(lo, 0, 1))
		pose(rig, "LidUp" .. side, 0, 0, 0, sign * upOff.X, upOff.Y, 0)
		pose(rig, "LidLo" .. side, 0, 0, 0, sign * loOff.X, loOff.Y, 0)
	end

	-- Legs, with footfall detection (returned for dust particles).
	local footPlanted = { R = false, L = false }
	rig.prevStridePhaseCos = rig.prevStridePhaseCos or {}
	for side, phaseOffset in pairs({ R = 0, L = math.pi }) do
		local phase = stridePhase + phaseOffset
		local c = math.cos(phase)
		local hip = walkWeight * 0.42 * math.sin(phase) + (1 - walkWeight) * 0.02 * math.sin(t * 0.8 + phaseOffset)
		local knee = -walkWeight * 0.85 * math.max(0, c) ^ 2
		pose(rig, "Hip" .. side, hip)
		pose(rig, "Knee" .. side, knee)
		pose(rig, "Ankle" .. side, -(hip + knee) * 0.9)
		local prev = rig.prevStridePhaseCos[side]
		if prev and prev > 0 and c <= 0 and walkWeight > 0.4 then footPlanted[side] = true end
		rig.prevStridePhaseCos[side] = c
	end

	-- Small arms: idle twitch, curled, pulled back when roaring.
	for side, sign in pairs({ R = 1, L = -1 }) do
		local o = (side == "R") and 0 or 1.7
		pose(rig, "Shoulder" .. side,
			0.25 * math.sin(t * 1.9 + o) + 0.15 * walkWeight * math.sin(2 * stridePhase) - 0.4 * roar,
			0, 0.05 * sign)
		pose(rig, "Elbow" .. side, -(0.5 + 0.3 * math.sin(t * 2.3 + 1 + o)))
	end

	-- Tail: idle sway, counter-swings while walking, swings wide on turns, lifts on a roar.
	local turnBias = math.clamp(turnRate * 0.18, -0.1, 0.1)
	for i = 1, 8 do
		local amp = 0.03 + 0.012 * i
		local yaw = amp * (0.35 * math.sin(t * 1.1 - 0.7 * i) + walkWeight * 1.2 * math.sin(stridePhase - 0.8 * i + 1.0))
			+ turnBias * (i / 8)
		local pitch = 0.015 * math.sin(t * 1.5 - 0.5 * i) - 0.05 * roar
		pose(rig, "Tail" .. i, pitch, yaw)
	end

	-- Overall state label, used for the HUD and name-tag text.
	local state = "Resting"
	if roar > 0.25 then state = "Roaring"
	elseif walkWeight > 0.4 then state = "Wandering"
	elseif yawn > 0.2 then state = "Yawning"
	elseif sniff > 0.3 then state = "Sniffing" end

	return {
		state = state,
		walkWeight = walkWeight,
		roar = roar,
		commanded = commandedRoar > 0.05,
		plantR = footPlanted.R,
		plantL = footPlanted.L,
	}
end

return M
