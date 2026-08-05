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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local VfxScaler = require(ReplicatedStorage.Shared.VfxScaler)

local log = Log.new("MushController")

local player = Players.LocalPlayer

local COMPRESS_SCALE = 0.55
local SPREAD_SCALE = 1.12
local SQUASH_IN = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local SQUASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local SQUASH_HOLD = 0.08
local REQUEST_TIMEOUT = 1

--[[
	Money burst. A loaded squishy drains over several clicks (see
	MergeConfig.drainClicksForPot), and every click in that sequence escalates:
	the burst grows and the sound pitches up, so the last click of a big drain
	lands hardest. A one-click drain is treated as the final click and gets the
	full-size burst rather than the smallest one.

	Scale is deliberately modest at the top. The authored asset is already sized
	for a squishy, and VfxScaler multiplies particle SIZE -- a large multiplier
	produces coins bigger than the thing that dropped them.
]]
local MONEY_BURST_ASSET = "MoneyBurst"
local MONEY_BURST_MIN_SCALE = 0.85
local MONEY_BURST_MAX_SCALE = 1.9
local MONEY_BURST_MIN_COUNT_FACTOR = 0.6
local MONEY_BURST_MAX_COUNT_FACTOR = 1.4
-- Hard per-emitter ceiling. One player can mush every MUSH_DRAIN_DEBOUNCE, and
-- a full server doing that at once is the case this has to stay cheap in.
local MONEY_BURST_MAX_PARTICLES = 120
-- Comfortably past the asset's longest particle Lifetime, so the clone is only
-- ever destroyed after its last coin has gone.
local MONEY_BURST_CLEANUP = 2.5
local MUSH_PITCH_MIN = 1
local MUSH_PITCH_MAX = 1.35
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
-- Local mirror of the server's mash debounce. Purely to keep the wire quiet
-- while a player holds the mouse down; the server enforces its own regardless.
local nextRequestAllowed = 0
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

-- Carried right in front of the player, so LOCAL_POP's tight falloff (8/80)
-- is ample -- this is a deliberate behaviour change from the previous
-- unlimited-range rolloff (SoundId was assigned raw, with no RollOffMode at
-- all, so the engine default Inverse had no cutoff) down to 80 studs.
--[[
	Where this click sits in the squishy's drain, as 0..1. A single-click drain
	returns 1: one click IS the last click, and it should land like one rather
	than getting the smallest, quietest burst in the set.
]]
local function drainRamp(step: number, total: number): number
	if total <= 1 then
		return 1
	end
	return math.clamp((step - 1) / (total - 1), 0, 1)
end

--[[
	Fires the coin burst at the carried squishy, escalating with `ramp`.

	Resolved defensively per call rather than cached: Assets.MoneyBurst lives in
	the place file, not on disk, so a session that predates it must fall through
	silently -- a missing effect asset is not a reason to break the mush.

	The clone is anchored and unparented from the squishy's motion on purpose:
	coins should stay where they were thrown, not ride the model as the player
	walks off.
]]
local function emitMoneyBurst(root: BasePart, ramp: number)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = if assets ~= nil then assets:FindFirstChild(MONEY_BURST_ASSET) else nil
	if template == nil or not template:IsA("BasePart") then
		return
	end

	local clone = template:Clone()
	-- motion = true so a bigger burst throws coins proportionally further.
	-- Scaling size alone just makes fatter coins in the same volume, which
	-- reads as a rendering glitch rather than a bigger payout.
	local scale = MONEY_BURST_MIN_SCALE + (MONEY_BURST_MAX_SCALE - MONEY_BURST_MIN_SCALE) * ramp
	VfxScaler.scale(clone, scale, { motion = true })

	clone.CFrame = root.CFrame
	clone.Parent = root

	local countFactor = MONEY_BURST_MIN_COUNT_FACTOR
		+ (MONEY_BURST_MAX_COUNT_FACTOR - MONEY_BURST_MIN_COUNT_FACTOR) * ramp
	for _, emitter in clone:GetChildren() do
		if emitter:IsA("ParticleEmitter") then
			local authored = emitter:GetAttribute("EmitCount")
			local base = if type(authored) == "number" then authored else 10
			emitter:Emit(math.clamp(math.round(base * countFactor), 1, MONEY_BURST_MAX_PARTICLES))
		end
	end

	task.delay(MONEY_BURST_CLEANUP, function()
		clone:Destroy()
	end)
end

local function playMushSound(root: BasePart, soundId: string, volume: number, pitch: number)
	if soundId == "" then
		return
	end

	local sound =
		SoundKit.playOnId(root, "MushSound", soundId, nil, math.clamp(volume, 0, 10), SoundKit.Profiles.LOCAL_POP)
	-- Pitch climbs across a drain so six clicks build instead of repeating.
	if sound ~= nil then
		sound.PlaybackSpeed = pitch
	end
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
	--[[
		Local-only marker so SquishyPotController leaves this model's welds alone
		for the duration. Both controllers drive the same VisualWeld C0/Size
		values, and the squash captures its restore targets at the start -- a pot
		swell landing mid-squash would be reverted when the squash finishes.

		Set client-side, so it never replicates and never reaches the server;
		this is purely two local controllers agreeing on who owns the welds.
	]]
	root:SetAttribute("Squashing", true)

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
		root:SetAttribute("Squashing", nil)
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

	--[[
		No countdown any more. This label used to show the boost's remaining
		seconds because the boost WAS the cooldown; at MUSH_BOOST_DURATION it
		would now just flicker a "2"/"1" while the player squeezes, which reads
		as a broken timer rather than state. The gradient above still carries
		"boost is up", which is the only part that was ever legible.
	]]
	setDisplayText(HIDDEN_COOLDOWN_TEXT)
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
	local screens = playerGui:WaitForChild("Screens")
	local ui = screens:WaitForChild("DropLaunchUI")
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
	if requestPending or player:GetAttribute("CarryingTier") == nil or root == nil then
		return
	end

	--[[
		Deliberately NOT gated on MushBoostActive any more. The boost used to
		double as the cooldown, so refusing while boosted was the throttle; now
		that a loaded squishy drains over several clicks, that guard would block
		every click after the first for the whole boost duration.
	]]
	local now = os.clock()
	if now < nextRequestAllowed then
		return
	end
	nextRequestAllowed = now + MergeConfig.MUSH_DRAIN_DEBOUNCE

	requestPending = true
	updateCooldownDisplay()
	Net.mergeMushRequest.send()

	-- Unconditional release: the reply clears this the moment it lands, and
	-- tying the fallback to MushBoostActive would strand requestPending true
	-- for as long as a refreshing boost stays up.
	task.delay(REQUEST_TIMEOUT, function()
		requestPending = false
		updateCooldownDisplay()
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

		-- A mush on an empty squishy is still a real mush -- squash, sound,
		-- speed boost -- it just has no money in it, so it stays at base pitch
		-- and skips the burst entirely.
		local ramp = if data.payout > 0 then drainRamp(data.drainStep, data.drainTotal) else 0
		playMushSound(root, data.soundId, data.soundVolume, MUSH_PITCH_MIN + (MUSH_PITCH_MAX - MUSH_PITCH_MIN) * ramp)
		squashVisual(root, data.direction)

		if data.payout > 0 then
			emitMoneyBurst(root, ramp)
		end
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
		local connectedScreensFolder: Instance? = nil
		local screensChildAddedConnection: RBXScriptConnection? = nil

		local function watchScreensFolder(folder: Instance)
			if connectedScreensFolder == folder then
				return
			end
			if screensChildAddedConnection ~= nil then
				screensChildAddedConnection:Disconnect()
			end
			connectedScreensFolder = folder
			screensChildAddedConnection = folder.ChildAdded:Connect(function(child)
				if child.Name == "DropLaunchUI" and child:IsA("ScreenGui") then
					task.spawn(resolveDisplay)
				end
			end)
		end

		playerGui.ChildAdded:Connect(function(child: Instance)
			if child.Name ~= "Screens" then
				return
			end
			-- ResetPlayerGuiOnSpawn re-clones the whole PlayerGui at once, so
			-- Screens arrives here as a single unit with DropLaunchUI already
			-- parented inside it -- resolve directly instead of waiting for a
			-- ChildAdded on the folder that already fired (if at all) before
			-- watchScreensFolder above could connect.
			task.spawn(resolveDisplay)
			watchScreensFolder(child)
		end)

		-- Screens can already exist by the time this connects (the common
		-- case, since resolveDisplay above already WaitForChild's it) or can
		-- still be on its way in on a slow first boot -- the ChildAdded
		-- connection above catches the late-arrival case, and this catches
		-- the already-there case, so individual re-clones of DropLaunchUI
		-- inside it are watched from here on regardless of which race won.
		local existingScreens = playerGui:FindFirstChild("Screens")
		if existingScreens ~= nil then
			watchScreensFolder(existingScreens)
		end
	end)
end

function MushController.Start()
	log.info("ready (any click/tap while carrying; DropLaunchUI.B.Mush cooldown)")
end

return MushController
