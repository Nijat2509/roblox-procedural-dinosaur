--[[
	DinoBrain.luau
	Type:  Script (server)
	Path:  ServerScriptService.DinoBrain

	Server-authoritative decision-maker for when the dinosaur roars. A roar
	can be triggered three ways:
		1. A player presses the ROAR button / R key (via the DinoRoar RemoteEvent).
		2. A player wanders within PROXIMITY_RANGE studs of the dinosaur.
		3. A random idle timer fires on its own.

	All three funnel through tryTriggerRoar(), which enforces one shared
	cooldown (read from the dinosaur's "Clock" attribute) so the dinosaur
	can't be spammed into roaring constantly, regardless of which path
	triggered it.

	Expects:
		ReplicatedStorage.DinoAnimator  (ModuleScript, see DinoAnimator.luau)
		ReplicatedStorage.DinoRoar      (RemoteEvent)
		Workspace.Dinosaur              (Model, PrimaryPart set)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Animator = require(ReplicatedStorage:WaitForChild("DinoAnimator"))
local roarRemote = ReplicatedStorage:WaitForChild("DinoRoar")
local dinosaur = workspace:WaitForChild("Dinosaur")

local PROXIMITY_RANGE = 45          -- studs; a player closer than this can provoke a roar
local PROXIMITY_HOLD  = 1.5         -- seconds a player must stay close before it counts
local RANDOM_ROAR_MIN = 45          -- seconds, lower bound of the idle-roar timer
local RANDOM_ROAR_MAX = 85          -- seconds, upper bound of the idle-roar timer

if not dinosaur:GetAttribute("Clock") then
	dinosaur:SetAttribute("Clock", "0,0,0")
end

-- Attempts to start a roar right now. Returns false (does nothing) if the
-- dinosaur is still mid-roar or still cooling down from the last one.
local function tryTriggerRoar()
	local now = workspace:GetServerTimeNow()
	local pausedBefore, roarStart, roarLength = Animator.parseClock(dinosaur:GetAttribute("Clock"))

	if now < roarStart + roarLength + Animator.COOLDOWN then
		return false -- still recovering from the last roar
	end

	-- Fold the just-finished pause into the accumulated "paused" history so
	-- the walk-cycle clock continues smoothly from where it left off.
	local foldedPause = pausedBefore + (roarLength > 0 and (roarLength - 0.9) or 0)
	dinosaur:SetAttribute("Clock", string.format("%.3f,%.3f,%.3f", foldedPause, now + 0.25, Animator.FREEZE_LEN))
	return true
end

-- 1) Player-requested roars (button press or 'R' key, sent from the client).
roarRemote.OnServerEvent:Connect(function(_player)
	tryTriggerRoar()
end)

-- 2) + 3) Autonomous behaviour: roar at nearby players, or occasionally at random.
task.spawn(function()
	local proximityTimer, idleTimer = 0, 0
	local nextRandomRoar = RANDOM_ROAR_MIN + math.random() * (RANDOM_ROAR_MAX - RANDOM_ROAR_MIN)

	while task.wait(0.5) do
		local now = workspace:GetServerTimeNow()
		local dinoPos = Animator.samplePosition(now, dinosaur:GetAttribute("Clock"))

		local closestPlayerDist = math.huge
		for _, player in ipairs(Players:GetPlayers()) do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root then
				closestPlayerDist = math.min(closestPlayerDist, (root.Position - dinoPos).Magnitude)
			end
		end

		if closestPlayerDist < PROXIMITY_RANGE then
			proximityTimer += 0.5
		else
			proximityTimer = 0
		end
		idleTimer += 0.5

		if proximityTimer >= PROXIMITY_HOLD then
			if tryTriggerRoar() then
				proximityTimer, idleTimer = 0, 0
			end
		elseif idleTimer >= nextRandomRoar then
			if tryTriggerRoar() then
				idleTimer = 0
				nextRandomRoar = RANDOM_ROAR_MIN + math.random() * (RANDOM_ROAR_MAX - RANDOM_ROAR_MIN)
			end
		end
	end
end)
