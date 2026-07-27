--!strict
--[[
	The floating status billboard every MergeObject Part carries: its health
	bar and its launch-cooldown counter. Pure presentation -- every function
	here takes the Part (and whatever value it should display) as a parameter
	and touches no module-level state, so materializeObject (Spawning),
	applySquishyDamage (Damage), and startLaunchCooldown (Launch) can all
	build or refresh this Gui without depending on each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Types = require(script.Parent.Types)

local StatusUI = {}

-- Keeps the public attributes and the replicated in-world bar in lockstep.
-- The attributes make health available to future effects without requiring
-- them to understand this Gui hierarchy; the Gui itself stays disabled at
-- full health so healthy pads remain visually quiet.
function StatusUI.updateHealthVisual(part: BasePart, tier: number, health: number)
	local maxHealth = MergeConfig.healthForTier(tier)
	local safeHealth = Types.sanitizeHealth(health, tier)
	part:SetAttribute("Health", safeHealth)
	part:SetAttribute("MaxHealth", maxHealth)

	local statusBillboard = part:FindFirstChild("IncomeLabel")
	local healthBar = if statusBillboard ~= nil then statusBillboard:FindFirstChild("HealthBar", true) else nil
	if healthBar == nil or not healthBar:IsA("GuiObject") then
		return
	end
	healthBar.Visible = safeHealth < maxHealth

	local fill = healthBar:FindFirstChild("Fill", true)
	if fill ~= nil and fill:IsA("Frame") then
		fill.Size = UDim2.fromScale(safeHealth / maxHealth, 1)
	end

	local healthText = healthBar:FindFirstChild("HealthText", true)
	if healthText ~= nil and healthText:IsA("TextLabel") then
		local percentage = math.round((safeHealth / maxHealth) * 100)
		healthText.Text = `♥ {percentage}%`
	end
end

function StatusUI.createHealthBar(part: BasePart, statusBillboard: BillboardGui, tier: number, health: number)
	local healthBar = Instance.new("Frame")
	healthBar.Name = "HealthBar"
	healthBar.Size = UDim2.fromScale(1, 22 / 52)
	healthBar.BackgroundTransparency = 1
	healthBar.Visible = false
	healthBar.Parent = statusBillboard

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Position = UDim2.fromOffset(0, 3)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = Color3.fromRGB(117, 55, 83)
	shadow.BackgroundTransparency = 0.45
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	shadow.Parent = healthBar

	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(1, 0)
	shadowCorner.Parent = shadow

	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.Size = UDim2.fromScale(1, 1)
	bubble.BackgroundColor3 = Color3.fromRGB(255, 244, 249)
	bubble.BorderSizePixel = 0
	bubble.ZIndex = 2
	bubble.Parent = healthBar

	local bubbleCorner = Instance.new("UICorner")
	bubbleCorner.CornerRadius = UDim.new(1, 0)
	bubbleCorner.Parent = bubble

	local bubbleStroke = Instance.new("UIStroke")
	bubbleStroke.Color = Color3.fromRGB(255, 139, 180)
	bubbleStroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- 2px on the billboard's 116x52 design grid; the bubble's shortest axis there is 22px.
	bubbleStroke.Thickness = 2 / 22
	bubbleStroke.Parent = bubble

	local track = Instance.new("Frame")
	track.Name = "Track"
	-- Keep a slim cream inset so the red HP fill reads more prominently while
	-- retaining the soft inner outline that makes the bar feel bubbly.
	track.Position = UDim2.fromOffset(2, 2)
	track.Size = UDim2.new(1, -4, 1, -4)
	track.BackgroundColor3 = Color3.fromRGB(255, 214, 228)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 3
	track.Parent = bubble

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 106, 154)
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local fillGradient = Instance.new("UIGradient")
	fillGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 126, 170)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 86, 126)),
	})
	fillGradient.Parent = fill

	-- A tiny glossy bubble gives the pill-shaped bar a toy-like finish without
	-- adding an image asset that would need separate loading/failure handling.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Position = UDim2.fromOffset(8, 2)
	shine.Size = UDim2.fromOffset(6, 4)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.35
	shine.BorderSizePixel = 0
	shine.ZIndex = 4
	shine.Parent = fill

	local shineCorner = Instance.new("UICorner")
	shineCorner.CornerRadius = UDim.new(1, 0)
	shineCorner.Parent = shine

	local healthText = Instance.new("TextLabel")
	healthText.Name = "HealthText"
	healthText.Size = UDim2.fromScale(1, 1)
	healthText.BackgroundTransparency = 1
	healthText.Font = Enum.Font.FredokaOne
	healthText.TextColor3 = Color3.fromRGB(255, 255, 255)
	healthText.TextStrokeColor3 = Color3.fromRGB(126, 48, 76)
	healthText.TextStrokeTransparency = 0.35
	healthText.TextScaled = true
	healthText.ZIndex = 5
	healthText.Parent = bubble

	StatusUI.updateHealthVisual(part, tier, health)
end

function StatusUI.createLaunchCooldownCounter(part: BasePart, statusBillboard: BillboardGui)
	local statusWidth = statusBillboard.Size.X.Scale
	local statusHeight = statusBillboard.Size.Y.Scale
	local counterHeight = math.max(0.8, statusHeight * 0.52)
	local counterBillboard = Instance.new("BillboardGui")
	counterBillboard.Name = "LaunchCooldownBillboard"
	counterBillboard.Size = UDim2.fromScale(statusWidth * 0.76, counterHeight)
	counterBillboard.StudsOffset =
		Vector3.new(0, statusBillboard.StudsOffset.Y + statusHeight / 2 + counterHeight / 2 + 0.12, 0)
	counterBillboard.AlwaysOnTop = true
	counterBillboard.LightInfluence = 0
	counterBillboard.Enabled = false
	counterBillboard.Parent = part

	local counter = Instance.new("TextLabel")
	counter.Name = "LaunchCooldownText"
	counter.Size = UDim2.fromScale(1, 1)
	counter.BackgroundTransparency = 1
	counter.BorderSizePixel = 0
	counter.Font = Enum.Font.FredokaOne
	counter.Text = ""
	counter.TextColor3 = Color3.fromRGB(255, 244, 249)
	counter.TextScaled = true
	counter.TextStrokeColor3 = Color3.fromRGB(255, 86, 136)
	counter.TextStrokeTransparency = 0
	counter.ZIndex = 2
	counter.Parent = counterBillboard

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = Color3.fromRGB(126, 48, 76)
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- 1.5px at the status billboard's 116x52 design reference. The counter's
	-- shortest axis is its height: counterHeight studs at (116 / statusWidth)
	-- px-per-stud on that grid.
	stroke.Thickness = 1.5 / (counterHeight * (116 / statusWidth))
	stroke.Parent = counter
end

function StatusUI.setLaunchCooldownCounter(part: BasePart, secondsRemaining: number)
	local counterBillboard = part:FindFirstChild("LaunchCooldownBillboard")
	local counter = if counterBillboard ~= nil then counterBillboard:FindFirstChild("LaunchCooldownText") else nil
	if counter == nil or not counter:IsA("TextLabel") then
		return
	end

	local wholeSeconds = math.max(0, math.ceil(secondsRemaining))
	if counterBillboard:IsA("BillboardGui") then
		counterBillboard.Enabled = wholeSeconds > 0
	end
	counter.Text = if wholeSeconds > 0 then Format.FormatCountdown(secondsRemaining) else ""
end

return StatusUI
