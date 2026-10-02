--[[
	DinoHUDSetup.luau
	Type:   NOT a persistent script -- paste this into Studio's Command Bar
	        (View > Command Bar) and run it ONCE after the Dinosaur model
	        exists in Workspace. It builds the on-screen compass/status HUD
	        and the floating name-tag above the dinosaur's head, then those
	        built objects are saved as part of the place like any other
	        Instance -- no script needs to keep running afterwards.

	Creates:
		StarterGui.DinoHUD                (ScreenGui)
		  .Panel                          (compass + status, top of screen)
		  .RoarButton                     (the button DinoClient.luau hooks up)
		Workspace.Dinosaur.Skull.DinoTag  (BillboardGui above the head)

	Requires Workspace.Dinosaur.Skull to already exist.
]]

local StarterGui = game:GetService("StarterGui")

local BONE = Color3.fromRGB(226, 214, 176)

local function addCorner(instance, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = instance
end

local function addStroke(instance, color, thickness, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.Parent = instance
end

local function addLabel(parent, name, text, position, size, font, textSize, color, alignment)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Text = text
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextSize = textSize
	label.TextColor3 = color
	label.TextXAlignment = alignment or Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

-- ===================== Top-of-screen HUD =====================
local existingHud = StarterGui:FindFirstChild("DinoHUD")
if existingHud then existingHud:Destroy() end

local hud = Instance.new("ScreenGui")
hud.Name = "DinoHUD"
hud.ResetOnSpawn = false
hud.DisplayOrder = 5

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 12)
panel.Size = UDim2.fromOffset(300, 86)
panel.BackgroundColor3 = Color3.fromRGB(14, 24, 18)
panel.BackgroundTransparency = 0.15
panel.BorderSizePixel = 0
panel.Parent = hud
addCorner(panel, UDim.new(0, 14))
addStroke(panel, BONE, 1.5, 0.3)

local panelGradient = Instance.new("UIGradient")
panelGradient.Color = ColorSequence.new(Color3.fromRGB(36, 64, 42), Color3.fromRGB(10, 18, 14))
panelGradient.Rotation = 90
panelGradient.Parent = panel

local compass = Instance.new("Frame")
compass.Name = "Compass"
compass.Position = UDim2.new(0, 12, 0.5, -30)
compass.Size = UDim2.fromOffset(60, 60)
compass.BackgroundColor3 = Color3.fromRGB(10, 18, 14)
compass.BackgroundTransparency = 0.1
compass.BorderSizePixel = 0
compass.Parent = panel
addCorner(compass, UDim.new(1, 0))
addStroke(compass, Color3.fromRGB(120, 180, 100), 2, 0.2)

local arrow = addLabel(compass, "Arrow", "\226\150\178", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(44, 44),
	Enum.Font.GothamBlack, 34, Color3.fromRGB(150, 220, 120), Enum.TextXAlignment.Center)
arrow.AnchorPoint = Vector2.new(0.5, 0.5)

addLabel(panel, "Title", "TYRANT REX", UDim2.fromOffset(88, 8), UDim2.new(1, -100, 0, 26), Enum.Font.GothamBlack, 22, BONE)
addLabel(panel, "Status", "Wandering", UDim2.fromOffset(88, 36), UDim2.new(1, -100, 0, 20), Enum.Font.GothamBold, 16, Color3.fromRGB(150, 220, 120))
addLabel(panel, "Dist", "-- studs away", UDim2.fromOffset(88, 58), UDim2.new(1, -100, 0, 18), Enum.Font.Gotham, 14, Color3.fromRGB(180, 190, 170))

local roarButton = Instance.new("TextButton")
roarButton.Name = "RoarButton"
roarButton.AnchorPoint = Vector2.new(0.5, 0)
roarButton.Position = UDim2.new(0.5, 0, 0, 106)
roarButton.Size = UDim2.fromOffset(300, 36)
roarButton.BackgroundColor3 = Color3.fromRGB(150, 44, 36)
roarButton.BorderSizePixel = 0
roarButton.Font = Enum.Font.GothamBlack
roarButton.TextSize = 18
roarButton.TextColor3 = Color3.fromRGB(240, 230, 200)
roarButton.Text = "ROAR   [R]"
roarButton.Parent = hud
addCorner(roarButton, UDim.new(0, 12))
addStroke(roarButton, BONE, 1.5, 0.3)

hud.Parent = StarterGui

-- ===================== Floating name-tag above the head =====================
local skull = workspace.Dinosaur.Skull
local existingTag = skull:FindFirstChild("DinoTag")
if existingTag then existingTag:Destroy() end

local tag = Instance.new("BillboardGui")
tag.Name = "DinoTag"
tag.Adornee = skull
tag.Size = UDim2.fromOffset(250, 92)
tag.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
tag.MaxDistance = 220
tag.LightInfluence = 0

local card = Instance.new("Frame")
card.Name = "Card"
card.Size = UDim2.fromScale(1, 1)
card.BackgroundColor3 = Color3.fromRGB(14, 24, 18)
card.BackgroundTransparency = 0.15
card.BorderSizePixel = 0
card.Parent = tag
addCorner(card, UDim.new(0, 12))
addStroke(card, BONE, 1.5, 0.25)

local cardGradient = Instance.new("UIGradient")
cardGradient.Color = ColorSequence.new(Color3.fromRGB(36, 64, 42), Color3.fromRGB(10, 18, 14))
cardGradient.Rotation = 90
cardGradient.Parent = card

addLabel(card, "Title", "TYRANT REX", UDim2.fromOffset(8, 4), UDim2.new(1, -16, 0, 26), Enum.Font.GothamBlack, 22, BONE, Enum.TextXAlignment.Center)
addLabel(card, "Sub", "Lv. 60  \194\183  Apex Predator", UDim2.fromOffset(8, 30), UDim2.new(1, -16, 0, 16), Enum.Font.GothamMedium, 13, Color3.fromRGB(170, 190, 150), Enum.TextXAlignment.Center)
addLabel(card, "Status", "Wandering", UDim2.fromOffset(8, 47), UDim2.new(1, -16, 0, 18), Enum.Font.GothamBold, 15, Color3.fromRGB(150, 220, 120), Enum.TextXAlignment.Center)

local hpBarBackground = Instance.new("Frame")
hpBarBackground.Name = "HPBar"
hpBarBackground.Position = UDim2.new(0, 14, 1, -18)
hpBarBackground.Size = UDim2.new(1, -28, 0, 9)
hpBarBackground.BackgroundColor3 = Color3.fromRGB(40, 50, 44)
hpBarBackground.BorderSizePixel = 0
hpBarBackground.Parent = card
addCorner(hpBarBackground, UDim.new(1, 0))

local hpFill = Instance.new("Frame")
hpFill.Name = "Fill"
hpFill.Size = UDim2.fromScale(1, 1)
hpFill.BackgroundColor3 = Color3.new(1, 1, 1)
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBarBackground
addCorner(hpFill, UDim.new(1, 0))

local hpGradient = Instance.new("UIGradient")
hpGradient.Color = ColorSequence.new(Color3.fromRGB(120, 230, 90), Color3.fromRGB(60, 170, 70))
hpGradient.Parent = hpFill

tag.Parent = skull

print("DinoHUDSetup: built StarterGui.DinoHUD and Workspace.Dinosaur.Skull.DinoTag")
