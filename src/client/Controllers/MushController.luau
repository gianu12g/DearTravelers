--!strict
--[[
	Mush is a contextual carry action: any click or completed touch tap while an
	object is picked up asks the server to activate it. B.Mush is display-only
	and shows the server-owned five-second cooldown.

	The server approves the interaction and owns the temporary WalkSpeed reward;
	this controller plays the tier-configured ASMR sound and squashes the carried
	visual locally. Only VisualWeld C0 values and visual BasePart sizes animate.
	The hidden MergeObject gameplay root never changes size, so pickup/merge
	detection remains stable throughout the effect.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("MushController")

local player = Players.LocalPlayer

local COMPRESS_SCALE = 0.55
local SPREAD_SCALE = 1.12
local SQUASH_IN = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local SQUASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local SQUASH_HOLD = 0.08
local REQUEST_TIMEOUT = 1
local SOUND_LIFETIME = 10
local COOLDOWN_FALLBACK = 5
local HIDDEN_COOLDOWN_TEXT = ""
local INSTRUCTION_FADE_DELAY = 1
local INSTRUCTION_FADE_INFO = TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
local INSTRUCTION_PULSE_SCALE = 1.08
local INSTRUCTION_PULSE_UP_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local INSTRUCTION_PULSE_DOWN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local COOLDOWN_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 95, 95)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 25, 25)),
})

type VisualState = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
	targetSize: Vector3,
	targetC0: CFrame,
}

local MushController = {}

local cooldownDisplay: TextLabel? = nil
local cooldownGradient: UIGradient? = nil
local readyGradientColor: ColorSequence? = nil
local gradientIsCooldown: boolean? = nil
local displayLabels: { TextLabel } = {}
local lastDisplayText: string? = nil
local instructionLabel: TextLabel? = nil
local instructionStroke: UIStroke? = nil
local instructionScale: UIScale? = nil
local instructionFadeMotion: Motion.Handle? = nil
local instructionPulseMotion: Motion.Handle? = nil
local instructionVisibilityConnection: RBXScriptConnection? = nil
local instructionFadeRevision = 0
local requestPending = false
local activeSquishes: { [BasePart]: boolean } = {}

local function findCarriedRoot(): BasePart?
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return nil
	end

	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local bases = mapLayout and mapLayout:FindFirstChild("Bases")
	local base = bases and bases:FindFirstChild(baseName)
	local folder = base and base:FindFirstChild("MergeObjects")
	local character = player.Character
	if folder == nil or character == nil then
		return nil
	end

	for _, child in folder:GetChildren() do
		if not child:IsA("BasePart") or child.Name ~= "MergeObject" then
			continue
		end
		local weld = child:FindFirstChild("CarryWeld")
		if
			weld ~= nil
			and weld:IsA("WeldConstraint")
			and weld.Part0 ~= nil
			and weld.Part0:IsDescendantOf(character)
		then
			return child
		end
	end

	return nil
end

local function playMushSound(root: BasePart, soundId: string, volume: number)
	if soundId == "" then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "MushSound"
	sound.SoundId = soundId
	sound.Volume = math.clamp(volume, 0, 10)
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	sound.Parent = root
	Debris:AddItem(sound, SOUND_LIFETIME)
	sound:Play()
end

local function squashGeometry(root: BasePart, direction: string): (Vector3, Vector3)
	if direction == "Bottom" then
		return Vector3.new(SPREAD_SCALE, COMPRESS_SCALE, SPREAD_SCALE), Vector3.new(0, root.Size.Y / 2, 0)
	elseif direction == "Left" then
		return Vector3.new(COMPRESS_SCALE, SPREAD_SCALE, SPREAD_SCALE), Vector3.new(root.Size.X / 2, 0, 0)
	elseif direction == "Right" then
		return Vector3.new(COMPRESS_SCALE, SPREAD_SCALE, SPREAD_SCALE), Vector3.new(-root.Size.X / 2, 0, 0)
	elseif direction == "Front" then
		return Vector3.new(SPREAD_SCALE, SPREAD_SCALE, COMPRESS_SCALE), Vector3.new(0, 0, root.Size.Z / 2)
	elseif direction == "Back" then
		return Vector3.new(SPREAD_SCALE, SPREAD_SCALE, COMPRESS_SCALE), Vector3.new(0, 0, -root.Size.Z / 2)
	end

	-- Top is both the default and the invalid-value fallback.
	return Vector3.new(SPREAD_SCALE, COMPRESS_SCALE, SPREAD_SCALE), Vector3.new(0, -root.Size.Y / 2, 0)
end

local function collectVisualStates(root: BasePart, direction: string): { VisualState }
	local visual = root:FindFirstChild("Visual")
	if visual == nil then
		return {}
	end

	local scale, anchor = squashGeometry(root, direction)
	local states: { VisualState } = {}
	local candidates = if visual:IsA("BasePart") then { visual } else visual:GetDescendants()

	for _, candidate in candidates do
		if not candidate:IsA("BasePart") then
			continue
		end
		local weld = candidate:FindFirstChild("VisualWeld")
		if weld == nil or not weld:IsA("Weld") then
			continue
		end

		local c0 = weld.C0
		local targetPosition = anchor + (c0.Position - anchor) * scale
		table.insert(states, {
			part = candidate,
			weld = weld,
			size = candidate.Size,
			c0 = c0,
			targetSize = candidate.Size * scale,
			targetC0 = CFrame.new(targetPosition) * c0.Rotation,
		})
	end

	return states
end

local function squashVisual(root: BasePart, direction: string)
	if activeSquishes[root] then
		return
	end

	local states = collectVisualStates(root, direction)
	if #states == 0 then
		return
	end
	activeSquishes[root] = true

	task.spawn(function()
		local driver = Instance.new("NumberValue")
		local changedConnection = driver.Changed:Connect(function(alpha: number)
			for _, state in states do
				if state.part.Parent ~= nil and state.weld.Parent ~= nil then
					state.part.Size = state.size:Lerp(state.targetSize, alpha)
					state.weld.C0 = state.c0:Lerp(state.targetC0, alpha)
				end
			end
		end)

		local squashIn = TweenService:Create(driver, SQUASH_IN, { Value = 1 })
		squashIn:Play()
		squashIn.Completed:Wait()
		task.wait(SQUASH_HOLD)

		local squashOut = TweenService:Create(driver, SQUASH_OUT, { Value = 0 })
		squashOut:Play()
		squashOut.Completed:Wait()

		changedConnection:Disconnect()
		for _, state in states do
			if state.part.Parent ~= nil and state.weld.Parent ~= nil then
				state.part.Size = state.size
				state.weld.C0 = state.c0
			end
		end
		driver:Destroy()
		activeSquishes[root] = nil
	end)
end

local function setDisplayText(text: string)
	if text == lastDisplayText then
		return
	end
	lastDisplayText = text

	for _, label in displayLabels do
		if label.Parent ~= nil then
			label.Text = text
		end
	end
end

local function setCooldownGradient(onCooldown: boolean)
	local gradient = cooldownGradient
	local readyColor = readyGradientColor
	if gradient == nil or gradient.Parent == nil or readyColor == nil or gradientIsCooldown == onCooldown then
		return
	end

	gradientIsCooldown = onCooldown
	gradient.Color = if onCooldown then COOLDOWN_GRADIENT else readyColor
end

local function updateCooldownDisplay()
	local display = cooldownDisplay
	if display == nil or display.Parent == nil then
		return
	end

	local boostActive = player:GetAttribute("MushBoostActive") == true
	setCooldownGradient(boostActive or requestPending)

	if boostActive then
		local rawEndsAt = player:GetAttribute("MushBoostEndsAt")
		local remaining = if type(rawEndsAt) == "number"
			then math.max(0, rawEndsAt - Workspace:GetServerTimeNow())
			else COOLDOWN_FALLBACK
		setDisplayText(`{math.max(1, math.ceil(remaining))}`)
	else
		setDisplayText(HIDDEN_COOLDOWN_TEXT)
	end
end

local function cancelInstructionMotions()
	local fadeMotion = instructionFadeMotion
	if fadeMotion ~= nil then
		fadeMotion.cancel()
		instructionFadeMotion = nil
	end

	local pulseMotion = instructionPulseMotion
	if pulseMotion ~= nil then
		pulseMotion.cancel()
		instructionPulseMotion = nil
	end
end

local function scheduleInstructionFade(
	actions: Frame,
	label: TextLabel,
	stroke: UIStroke,
	uiScale: UIScale,
	revision: number
)
	task.delay(INSTRUCTION_FADE_DELAY, function()
		if
			revision ~= instructionFadeRevision
			or not actions.Visible
			or label ~= instructionLabel
			or stroke ~= instructionStroke
			or uiScale ~= instructionScale
		then
			return
		end

		instructionFadeMotion = Motion.value(0, 1, INSTRUCTION_FADE_INFO, function(alpha)
			label.TextTransparency = alpha
			stroke.Transparency = alpha
		end)
	end)
end

local function updateInstructionMotion(actions: Frame, label: TextLabel, stroke: UIStroke, uiScale: UIScale)
	instructionFadeRevision += 1
	local thisRevision = instructionFadeRevision

	cancelInstructionMotions()
	label.TextTransparency = 0
	stroke.Transparency = 0
	uiScale.Scale = 1

	if not actions.Visible then
		return
	end

	instructionPulseMotion = Motion.tween(
		uiScale,
		{ Scale = INSTRUCTION_PULSE_SCALE },
		INSTRUCTION_PULSE_UP_INFO,
		function()
			if thisRevision ~= instructionFadeRevision or uiScale ~= instructionScale or not actions.Visible then
				return
			end

			instructionPulseMotion = Motion.tween(uiScale, { Scale = 1 }, INSTRUCTION_PULSE_DOWN_INFO, function()
				if thisRevision ~= instructionFadeRevision or uiScale ~= instructionScale or not actions.Visible then
					return
				end

				instructionPulseMotion = nil
				scheduleInstructionFade(actions, label, stroke, uiScale, thisRevision)
			end)
		end
	)
end

local function bindInstructionMotion(actions: Frame, label: TextLabel, stroke: UIStroke)
	if instructionVisibilityConnection ~= nil then
		instructionVisibilityConnection:Disconnect()
	end

	local uiScale = label:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Parent = label

	instructionLabel = label
	instructionStroke = stroke
	instructionScale = uiScale
	local visibleChanged = actions:GetPropertyChangedSignal("Visible")
	instructionVisibilityConnection = visibleChanged:Connect(function()
		updateInstructionMotion(actions, label, stroke, uiScale)
	end)
	updateInstructionMotion(actions, label, stroke, uiScale)
end

local function resolveDisplay()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("DropLaunchUI")
	local actions = ui:WaitForChild("CarryActions")
	if not actions:IsA("Frame") then
		log.error(`{actions:GetFullName()} must be a Frame`)
		return
	end
	local display = actions:WaitForChild("B.Mush")
	if not display:IsA("TextLabel") then
		log.error(`{display:GetFullName()} must be a TextLabel`)
		return
	end

	local cooldown = display:WaitForChild("TextLabel")
	if not cooldown:IsA("TextLabel") then
		log.error(`{cooldown:GetFullName()} must be a TextLabel`)
		return
	end
	local gradient = display:WaitForChild("UIGradient")
	if not gradient:IsA("UIGradient") then
		log.error(`{gradient:GetFullName()} must be a UIGradient`)
		return
	end
	local instruction = display:WaitForChild("Instruc")
	if not instruction:IsA("TextLabel") then
		log.error(`{instruction:GetFullName()} must be a TextLabel`)
		return
	end
	local stroke = instruction:FindFirstChildOfClass("UIStroke")
	if stroke == nil then
		log.error(`{instruction:GetFullName()} must contain a UIStroke`)
		return
	end

	-- B.Mush.Instruc is authored helper copy, not stateful UI. Cooldown state
	-- only changes the dedicated TextLabel and the container's direct gradient.
	cooldownDisplay = cooldown
	cooldownGradient = gradient
	readyGradientColor = gradient.Color
	gradientIsCooldown = nil
	displayLabels = { cooldown }
	lastDisplayText = nil
	updateCooldownDisplay()
	bindInstructionMotion(actions, instruction, stroke)
end

local function requestMush()
	local root = findCarriedRoot()
	if
		requestPending
		or player:GetAttribute("MushBoostActive") == true
		or player:GetAttribute("CarryingTier") == nil
		or root == nil
	then
		return
	end

	requestPending = true
	updateCooldownDisplay()
	Net.mergeMushRequest.send()

	task.delay(REQUEST_TIMEOUT, function()
		if player:GetAttribute("MushBoostActive") ~= true then
			requestPending = false
			updateCooldownDisplay()
		end
	end)
end

function MushController.Init()
	Net.mergeMushActivated.listen(function(data)
		requestPending = false
		updateCooldownDisplay()

		local root = findCarriedRoot()
		if root == nil or root:GetAttribute("Tier") ~= data.tier then
			return
		end
		playMushSound(root, data.soundId, data.soundVolume)
		squashVisual(root, data.direction)
	end)

	local boostChanged = player:GetAttributeChangedSignal("MushBoostActive")
	boostChanged:Connect(function()
		requestPending = false
		updateCooldownDisplay()
	end)

	local boostEndsAtChanged = player:GetAttributeChangedSignal("MushBoostEndsAt")
	boostEndsAtChanged:Connect(updateCooldownDisplay)

	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			requestMush()
		end
	end)

	-- TouchTap excludes thumbstick/camera drags, so mobile movement does not
	-- consume Mush; only a completed tap behaves like a mouse click.
	UserInputService.TouchTap:Connect(function()
		requestMush()
	end)

	RunService.Heartbeat:Connect(updateCooldownDisplay)

	task.spawn(resolveDisplay)
	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui")
		playerGui.ChildAdded:Connect(function(child)
			if child.Name == "DropLaunchUI" and child:IsA("ScreenGui") then
				task.spawn(resolveDisplay)
			end
		end)
	end)
end

function MushController.Start()
	log.info("ready (any click/tap while carrying; DropLaunchUI.B.Mush cooldown)")
end

return MushController
