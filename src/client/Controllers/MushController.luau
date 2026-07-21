--!strict
--[[
	Binds DropLaunchUI.CarryActions.Mush. The server approves the interaction
	and owns the temporary WalkSpeed reward; this controller only plays the
	tier-configured ASMR sound and squashes the carried visual locally.

	Only the visual model's Weld C0 and BasePart sizes are animated. The hidden
	MergeObject gameplay root never changes size, so pickup/merge detection is
	stable throughout the effect.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("MushController")

local player = Players.LocalPlayer

local SQUASH_SCALE = Vector3.new(1.12, 0.55, 1.12)
local SQUASH_IN = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local SQUASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local SQUASH_HOLD = 0.08
local REQUEST_TIMEOUT = 1
local SOUND_LIFETIME = 10

type VisualState = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
	targetSize: Vector3,
	targetC0: CFrame,
}

local MushController = {}

local mushButton: TextButton? = nil
local connectedButton: TextButton? = nil
local activatedConnection: RBXScriptConnection? = nil
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

local function collectVisualStates(root: BasePart): { VisualState }
	local visual = root:FindFirstChild("Visual")
	if visual == nil then
		return {}
	end

	local states: { VisualState } = {}
	local candidates = if visual:IsA("BasePart") then { visual } else visual:GetDescendants()
	local bottom = -root.Size.Y / 2

	for _, candidate in candidates do
		if not candidate:IsA("BasePart") then
			continue
		end
		local weld = candidate:FindFirstChild("VisualWeld")
		if weld == nil or not weld:IsA("Weld") then
			continue
		end

		local c0 = weld.C0
		local position = c0.Position
		local targetPosition = Vector3.new(
			position.X * SQUASH_SCALE.X,
			bottom + (position.Y - bottom) * SQUASH_SCALE.Y,
			position.Z * SQUASH_SCALE.Z
		)
		table.insert(states, {
			part = candidate,
			weld = weld,
			size = candidate.Size,
			c0 = c0,
			targetSize = candidate.Size * SQUASH_SCALE,
			targetC0 = CFrame.new(targetPosition) * c0.Rotation,
		})
	end

	return states
end

local function squashVisual(root: BasePart)
	if activeSquishes[root] then
		return
	end

	local states = collectVisualStates(root)
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

local function updateButtonState()
	local button = mushButton
	if button == nil or button.Parent == nil then
		return
	end
	local enabled = player:GetAttribute("MushBoostActive") ~= true and not requestPending
	button.Active = enabled
	button.Selectable = enabled
end

local function bindButton(button: TextButton)
	if not CollectionService:HasTag(button, "UIButton") then
		CollectionService:AddTag(button, "UIButton")
	end

	mushButton = button
	if connectedButton == button then
		updateButtonState()
		return
	end
	if activatedConnection ~= nil then
		activatedConnection:Disconnect()
	end

	connectedButton = button
	activatedConnection = button.Activated:Connect(function()
		if requestPending or player:GetAttribute("MushBoostActive") == true then
			return
		end
		requestPending = true
		updateButtonState()
		Net.mergeMushRequest.send()

		task.delay(REQUEST_TIMEOUT, function()
			if player:GetAttribute("MushBoostActive") ~= true then
				requestPending = false
				updateButtonState()
			end
		end)
	end)
	updateButtonState()
end

local function resolveAndBindButton()
	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("DropLaunchUI")
	local actions = ui:WaitForChild("CarryActions")
	local button = actions:WaitForChild("Mush")
	if not button:IsA("TextButton") then
		log.error(`{button:GetFullName()} must be a TextButton`)
		return
	end
	bindButton(button)
end

function MushController.Init()
	Net.mergeMushActivated.listen(function(data)
		requestPending = false
		updateButtonState()

		local root = findCarriedRoot()
		if root == nil or root:GetAttribute("Tier") ~= data.tier then
			return
		end
		playMushSound(root, data.soundId, data.soundVolume)
		squashVisual(root)
	end)

	local boostChanged = player:GetAttributeChangedSignal("MushBoostActive")
	boostChanged:Connect(function()
		if player:GetAttribute("MushBoostActive") ~= true then
			requestPending = false
		end
		updateButtonState()
	end)

	task.spawn(resolveAndBindButton)
	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui")
		playerGui.ChildAdded:Connect(function(child)
			if child.Name == "DropLaunchUI" and child:IsA("ScreenGui") then
				task.spawn(resolveAndBindButton)
			end
		end)
	end)
end

function MushController.Start()
	log.info("ready (DropLaunchUI.Mush)")
end

return MushController
