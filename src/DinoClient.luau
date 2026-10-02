--[[
	DinoClient.luau
	Type:  LocalScript
	Path:  StarterPlayer.StarterPlayerScripts.DinoClient

	Drives the dinosaur's visuals on each player's machine: calls into
	DinoAnimator every frame, emits footstep dust, plays the roar sound in
	sync with the animation, shakes the camera when a roar happens nearby,
	and keeps the HUD compass / name-tag / ROAR button up to date.

	Expects:
		ReplicatedStorage.DinoAnimator           (ModuleScript)
		ReplicatedStorage.DinoRoar                (RemoteEvent)
		Workspace.Dinosaur                        (Model, tagged "AnimatedDino"
		                                            via CollectionService)
		  Dinosaur.Skull.RoarSound                (Sound)
		  Dinosaur.Skull.DinoTag                  (BillboardGui, see README)
		  Dinosaur.FootR / Dinosaur.FootL          (Parts, for dust emitters)
		StarterGui.DinoHUD                        (ScreenGui, see README)
		  DinoHUD.Panel.Compass.Arrow / .Status / .Dist
		  DinoHUD.RoarButton                      (TextButton)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Animator = require(ReplicatedStorage:WaitForChild("DinoAnimator"))
local roarRemote = ReplicatedStorage:WaitForChild("DinoRoar", 10)

local localPlayer = Players.LocalPlayer

local STATE_COLORS = {
	Wandering = Color3.fromRGB(150, 220, 120),
	Resting   = Color3.fromRGB(205, 210, 195),
	Roaring   = Color3.fromRGB(255, 90, 70),
	Sniffing  = Color3.fromRGB(120, 200, 255),
	Yawning   = Color3.fromRGB(240, 200, 120),
}

local boundRigs = {}
local hud, roarButton

local function fireRoarRequest()
	if roarRemote then roarRemote:FireServer() end
end

task.spawn(function()
	hud = localPlayer:WaitForChild("PlayerGui"):WaitForChild("DinoHUD", 15)
	if hud then
		roarButton = hud:FindFirstChild("RoarButton")
		if roarButton then
			roarButton.Activated:Connect(fireRoarRequest)
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if not gameProcessedEvent and input.KeyCode == Enum.KeyCode.R then
		fireRoarRequest()
	end
end)

-- Attaches a disabled-by-default smoke ParticleEmitter to each foot, so the
-- animator's footstep info can trigger a short dust burst per step.
local function attachDustEmitters(rig)
	rig.dust = {}
	for _, side in ipairs({ "R", "L" }) do
		local foot = rig.model:FindFirstChild("Foot" .. side)
		if foot then
			local attachment = Instance.new("Attachment")
			attachment.Position = Vector3.new(0, -0.4, -1.2)
			attachment.Parent = foot

			local emitter = Instance.new("ParticleEmitter")
			emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
			emitter.Color = ColorSequence.new(Color3.fromRGB(150, 130, 95))
			emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 5) })
			emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
			emitter.Lifetime = NumberRange.new(0.8, 1.5)
			emitter.Speed = NumberRange.new(3, 8)
			emitter.SpreadAngle = Vector2.new(180, 60)
			emitter.Drag = 3
			emitter.Rate = 0 -- emits only via :Emit(), never continuously
			emitter.LightInfluence = 1
			emitter.Parent = attachment

			rig.dust[side] = emitter
		end
	end
end

local function bindDinosaur(model)
	if boundRigs[model] then return end
	model:WaitForChild("Root")
	model:WaitForChild("Skull")
	model.PrimaryPart = model.PrimaryPart or model.Root

	local rig = Animator.bind(model)
	attachDustEmitters(rig)
	rig.tag = model.Skull:FindFirstChild("DinoTag")
	rig.smoothedLoudness = 0
	boundRigs[model] = rig
end

for _, model in ipairs(CollectionService:GetTagged("AnimatedDino")) do
	task.spawn(bindDinosaur, model)
end
CollectionService:GetInstanceAddedSignal("AnimatedDino"):Connect(function(model)
	task.spawn(bindDinosaur, model)
end)
CollectionService:GetInstanceRemovedSignal("AnimatedDino"):Connect(function(model)
	boundRigs[model] = nil
end)

local cameraShaking = false

RunService.RenderStepped:Connect(function()
	local now = workspace:GetServerTimeNow()
	local camera = workspace.CurrentCamera
	local shakeAmount = 0
	local hudUpdatedThisFrame = false

	for _, rig in pairs(boundRigs) do
		if not (rig.root and rig.root.Parent) then continue end

		-- Feed the roar sound's live loudness back into the animator so the
		-- jaw visually opens in sync with how loud the sound actually is.
		local roarSound = rig.model.Skull:FindFirstChild("RoarSound")
		local rawLoudness = (roarSound and roarSound.IsPlaying) and roarSound.PlaybackLoudness or 0
		rig.smoothedLoudness = rig.smoothedLoudness * 0.7 + rawLoudness * 0.3

		local info = Animator.update(rig, now, { loudness = rig.smoothedLoudness })

		-- Footstep dust.
		if rig.dust then
			if info.plantR and rig.dust.R then rig.dust.R:Emit(7) end
			if info.plantL and rig.dust.L then rig.dust.L:Emit(7) end
			if info.roar > 0.25 and not rig.isRoaring then
				rig.isRoaring = true
				if roarSound then roarSound:Play() end
				for _, emitter in pairs(rig.dust) do emitter:Emit(16) end
			elseif info.roar < 0.05 then
				rig.isRoaring = false
			end
		end

		-- Name-tag status text/colour.
		if rig.tag and rig.tag:FindFirstChild("Card") then
			local statusLabel = rig.tag.Card:FindFirstChild("Status")
			if statusLabel then
				statusLabel.Text = info.state
				statusLabel.TextColor3 = STATE_COLORS[info.state] or Color3.new(1, 1, 1)
			end
		end

		if camera then
			local toDino = rig.root.Position - camera.CFrame.Position
			local distance = toDino.Magnitude

			-- Camera shake falls off with distance and roar intensity.
			if info.roar > 0.05 and distance < 90 then
				shakeAmount = math.max(shakeAmount, info.roar * (1 - distance / 90) * 0.5)
			end

			-- Only one dinosaur drives the HUD per frame (there's normally just one).
			if hud and not hudUpdatedThisFrame then
				hudUpdatedThisFrame = true
				local panel = hud:FindFirstChild("Panel")
				if panel then
					local rightOffset = toDino:Dot(camera.CFrame.RightVector)
					local forwardOffset = toDino:Dot(camera.CFrame.LookVector)
					local stateColor = STATE_COLORS[info.state] or Color3.new(1, 1, 1)
					panel.Compass.Arrow.Rotation = math.deg(math.atan2(rightOffset, forwardOffset))
					panel.Compass.Arrow.TextColor3 = stateColor
					panel.Status.Text = info.state
					panel.Status.TextColor3 = stateColor
					panel.Dist.Text = string.format("%d studs away", distance)
				end
				if roarButton then
					local _, roarStart, roarLength = Animator.parseClock(rig.model:GetAttribute("Clock"))
					local secondsLeft = roarStart + roarLength + Animator.COOLDOWN - now
					if secondsLeft > 0 and roarLength > 0 then
						roarButton.Text = string.format("Recovering...  %d", math.ceil(secondsLeft))
						roarButton.BackgroundColor3 = Color3.fromRGB(60, 66, 62)
					else
						roarButton.Text = "ROAR   [R]"
						roarButton.BackgroundColor3 = Color3.fromRGB(150, 44, 36)
					end
				end
			end
		end
	end

	-- Apply/clear the camera shake on the local player's humanoid.
	local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if shakeAmount > 0.01 then
			humanoid.CameraOffset = Vector3.new(
				(math.random() - 0.5) * shakeAmount,
				(math.random() - 0.5) * shakeAmount,
				0
			)
			cameraShaking = true
		elseif cameraShaking then
			humanoid.CameraOffset = Vector3.zero
			cameraShaking = false
		end
	end
end)
