--!strict
--[[
	Client-side keyboard interaction for every MeshPart tagged `Key`.

	Each key receives a random letter and a color from the palette named by its
	`Theme` attribute. A missing Theme uses Chocolate; invalid values are left
	unchanged and reported so an authored typo does not silently become another
	theme. Theme is intentionally read only when the key is connected.

	Press detection follows the local player's HumanoidRootPart every frame. All
	motion, UI, color selection, and audio are local-only. Sounds are created per
	press and destroyed after playback, so keys need no child Sound instances and
	overlapping presses never cut each other off.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("LightUpKeysController")

local KEY_TAG = "Key"
local THEME_ATTRIBUTE = "Theme"
local DEFAULT_THEME = "Chocolate"

local KEY_GUI_NAME = "KeyGui"
local LETTER_LABEL_NAME = "LetterLabel"
local LETTER_STROKE_NAME = "LetterStroke"

local SOUND_NAME = "ClickSound"
local SOUND_ID = "rbxassetid://84953529887338"
local SOUND_VOLUME = 0.75
local SOUND_LOAD_TIMEOUT = 3
local PLAYBACK_SPEED_MIN = 1
local PLAYBACK_SPEED_MAX = 1.2

local DROP_DISTANCE = 1.4
local HORIZONTAL_MARGIN = 1
local HEIGHT_ABOVE_KEY = 6
local HEIGHT_BELOW_KEY = 2

local PRESS_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local THEMES: { [string]: { Color3 } } = {
	Ocean = {
		Color3.fromRGB(24, 54, 62),
		Color3.fromRGB(95, 151, 170),
		Color3.fromRGB(45, 95, 110),
		Color3.fromRGB(62, 136, 165),
		Color3.fromRGB(147, 196, 209),
	},
	Candy = {
		Color3.fromRGB(255, 182, 193),
		Color3.fromRGB(255, 105, 180),
		Color3.fromRGB(173, 216, 230),
		Color3.fromRGB(152, 251, 152),
		Color3.fromRGB(221, 160, 221),
		Color3.fromRGB(255, 253, 208),
		Color3.fromRGB(255, 218, 185),
	},
	Chocolate = {
		Color3.fromRGB(62, 39, 35),
		Color3.fromRGB(136, 92, 62),
		Color3.fromRGB(93, 48, 11),
		Color3.fromRGB(77, 39, 0),
		Color3.fromRGB(156, 104, 78),
	},
	Blue = {
		Color3.fromRGB(60, 120, 255),
		Color3.fromRGB(90, 150, 255),
		Color3.fromRGB(120, 180, 255),
		Color3.fromRGB(40, 90, 220),
	},
	Sunset = {
		Color3.fromRGB(242, 196, 71),
		Color3.fromRGB(247, 98, 24),
		Color3.fromRGB(255, 29, 104),
		Color3.fromRGB(177, 0, 101),
		Color3.fromRGB(116, 5, 128),
	},
}

local ALPHABET = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
}

type KeyState = {
	originalCFrame: CFrame,
	originalColor: Color3,
	createdGui: SurfaceGui?,
	pressed: boolean,
	currentTween: Tween?,
}

local player = Players.LocalPlayer
local trackedKeys: { [MeshPart]: KeyState } = {}
local previousLetter = ""

local LightUpKeysController = {}

local function createLetterGui(key: MeshPart): SurfaceGui?
	if key:FindFirstChild(KEY_GUI_NAME) ~= nil then
		return nil
	end

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = KEY_GUI_NAME
	surfaceGui.Face = Enum.NormalId.Top
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 81

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = LETTER_LABEL_NAME
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.new(0, 0, 0)

	local chosenLetter = ""
	repeat
		chosenLetter = ALPHABET[math.random(1, #ALPHABET)]
	until chosenLetter ~= previousLetter
	previousLetter = chosenLetter
	textLabel.Text = chosenLetter

	local stroke = Instance.new("UIStroke")
	stroke.Name = LETTER_STROKE_NAME
	stroke.Thickness = 1.5
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = textLabel

	textLabel.Parent = surfaceGui
	surfaceGui.Parent = key

	return surfaceGui
end

local function applyTheme(key: MeshPart)
	local attribute = key:GetAttribute(THEME_ATTRIBUTE)
	local themeName = DEFAULT_THEME

	if attribute ~= nil then
		if typeof(attribute) ~= "string" then
			log.warn(
				`{key:GetFullName()}.{THEME_ATTRIBUTE} should be a string, got {typeof(attribute)} -- color unchanged`
			)
			return
		end
		themeName = attribute
	end

	local palette = THEMES[themeName]
	if palette == nil then
		log.warn(`{key:GetFullName()}.{THEME_ATTRIBUTE} has unknown theme "{themeName}" -- color unchanged`)
		return
	end

	key.Color = palette[math.random(1, #palette)]
end

-- One transient Sound per press allows rapid or overlapping presses to layer.
-- Ended/Stopped handle the normal path; the timeout also cleans up a SoundId
-- that never loads and therefore never emits either signal.
local function playKeySound(key: MeshPart)
	local sound = Instance.new("Sound")
	sound.Name = SOUND_NAME
	sound.SoundId = SOUND_ID
	sound.Volume = SOUND_VOLUME
	sound.PlaybackSpeed = math.random(PLAYBACK_SPEED_MIN * 100, PLAYBACK_SPEED_MAX * 100) / 100
	sound.Parent = key

	local destroyed = false
	local function destroySound()
		if destroyed then
			return
		end
		destroyed = true
		sound:Destroy()
	end

	sound.Ended:Once(destroySound)
	sound.Stopped:Once(destroySound)
	task.delay(SOUND_LOAD_TIMEOUT, destroySound)

	sound:Play()
end

local function cancelTween(state: KeyState)
	local tween = state.currentTween
	if tween == nil then
		return
	end

	state.currentTween = nil
	tween:Cancel()
end

local function tweenKey(key: MeshPart, state: KeyState, target: CFrame, info: TweenInfo)
	cancelTween(state)

	local tween = TweenService:Create(key, info, { CFrame = target })
	state.currentTween = tween

	tween.Completed:Once(function()
		if state.currentTween == tween then
			state.currentTween = nil
		end
	end)

	tween:Play()
end

local function pressKey(key: MeshPart, state: KeyState)
	if state.pressed then
		return
	end
	state.pressed = true

	playKeySound(key)
	tweenKey(key, state, state.originalCFrame * CFrame.new(0, -DROP_DISTANCE, 0), PRESS_INFO)
end

local function releaseKey(key: MeshPart, state: KeyState)
	if not state.pressed then
		return
	end
	state.pressed = false

	tweenKey(key, state, state.originalCFrame, RELEASE_INFO)
end

local function isPlayerOnKey(key: MeshPart): boolean
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	local position = root.Position
	local keyPosition = key.Position
	local keySize = key.Size

	return math.abs(position.X - keyPosition.X) <= keySize.X / 2 + HORIZONTAL_MARGIN
		and math.abs(position.Z - keyPosition.Z) <= keySize.Z / 2 + HORIZONTAL_MARGIN
		and position.Y <= keyPosition.Y + HEIGHT_ABOVE_KEY
		and position.Y >= keyPosition.Y - HEIGHT_BELOW_KEY
end

local function wireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		log.warn(
			`{instance:GetFullName()} is tagged {KEY_TAG} but is a {instance.ClassName} -- only MeshParts are keys`
		)
		return
	end
	if trackedKeys[instance] ~= nil then
		return
	end

	local state: KeyState = {
		originalCFrame = instance.CFrame,
		originalColor = instance.Color,
		createdGui = nil,
		pressed = false,
		currentTween = nil,
	}
	trackedKeys[instance] = state

	applyTheme(instance)
	state.createdGui = createLetterGui(instance)
end

local function unwireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		return
	end

	local state = trackedKeys[instance]
	if state == nil then
		return
	end
	trackedKeys[instance] = nil

	cancelTween(state)
	if instance.Parent ~= nil then
		instance.CFrame = state.originalCFrame
		instance.Color = state.originalColor
	end

	local createdGui = state.createdGui
	if createdGui ~= nil then
		createdGui:Destroy()
	end
end

local function updateKeys()
	for key, state in trackedKeys do
		if key.Parent == nil then
			unwireKey(key)
		elseif isPlayerOnKey(key) then
			pressKey(key, state)
		else
			releaseKey(key, state)
		end
	end
end

function LightUpKeysController.Init()
	CollectionService:GetInstanceAddedSignal(KEY_TAG):Connect(wireKey)
	CollectionService:GetInstanceRemovedSignal(KEY_TAG):Connect(unwireKey)

	for _, instance in CollectionService:GetTagged(KEY_TAG) do
		wireKey(instance)
	end

	RunService.Heartbeat:Connect(updateKeys)
	log.info(`ready ({#CollectionService:GetTagged(KEY_TAG)} tagged instances)`)
end

return LightUpKeysController
