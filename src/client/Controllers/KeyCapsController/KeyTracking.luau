--!strict
--[[
	Per-key wiring and press detection. See init.luau's module comment for the
	full behavior this implements.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Appearance = require(script.Parent.Appearance)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local Log = require(ReplicatedStorage.Shared.Log)
local Sound = require(script.Parent.Sound)

local log = Log.new("LightUpKeysController")

local KEY_TAG = CosmeticsCatalog.KEY_TAG

local KEY_GUI_NAME = "KeyGui"
local LETTER_LABEL_NAME = "LetterLabel"
local LETTER_STROKE_NAME = "LetterStroke"

local DROP_DISTANCE = 1.4
local HORIZONTAL_MARGIN = 1
local HEIGHT_ABOVE_KEY = 6
local HEIGHT_BELOW_KEY = 2
local KEY_QUERY_SIZE = Vector3.new(HORIZONTAL_MARGIN * 2, HEIGHT_ABOVE_KEY + HEIGHT_BELOW_KEY, HORIZONTAL_MARGIN * 2)
local KEY_QUERY_OFFSET = Vector3.new(0, (HEIGHT_BELOW_KEY - HEIGHT_ABOVE_KEY) / 2, 0)

local PRESS_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

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
	originalMaterial: Enum.Material,
	createdGui: SurfaceGui?,
	themeConnection: RBXScriptConnection?,
	pressed: boolean,
	currentTween: Tween?,
	basePart: BasePart?,
}

local player = Players.LocalPlayer
local trackedKeys: { [MeshPart]: KeyState } = {}
local pressedKeys: { [MeshPart]: boolean } = {}
local keysUnderPlayer: { [MeshPart]: boolean } = {}
local previousLetter = ""
local excludedCharacter: Model? = nil

local keyOverlapParams = OverlapParams.new()
keyOverlapParams.MaxParts = 0
keyOverlapParams.RespectCanCollide = false

local KeyTracking = {}

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
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- Same 1.5px as before: the label spans the Top face, so its shortest
	-- pixel axis is min(X, Z) studs at the gui's PixelsPerStud.
	stroke.Thickness = 1.5 / (math.min(key.Size.X, key.Size.Z) * surfaceGui.PixelsPerStud)
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = textLabel

	textLabel.Parent = surfaceGui
	surfaceGui.Parent = key

	return surfaceGui
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
	pressedKeys[key] = true

	Sound.playKeySound(key)
	tweenKey(key, state, state.originalCFrame * CFrame.new(0, -DROP_DISTANCE, 0), PRESS_INFO)
end

local function releaseKey(key: MeshPart, state: KeyState)
	pressedKeys[key] = nil
	if not state.pressed then
		return
	end
	state.pressed = false

	tweenKey(key, state, state.originalCFrame, RELEASE_INFO)
end

local function isPlayerOnKey(position: Vector3, key: MeshPart): boolean
	local keyPosition = key.Position
	local keySize = key.Size

	return math.abs(position.X - keyPosition.X) <= keySize.X / 2 + HORIZONTAL_MARGIN
		and math.abs(position.Z - keyPosition.Z) <= keySize.Z / 2 + HORIZONTAL_MARGIN
		and position.Y <= keyPosition.Y + HEIGHT_ABOVE_KEY
		and position.Y >= keyPosition.Y - HEIGHT_BELOW_KEY
end

function KeyTracking.wireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		log.warn(
			`{instance:GetFullName()} is tagged {KEY_TAG} but is a {instance.ClassName} -- only MeshParts are keys`
		)
		return
	end
	if trackedKeys[instance] ~= nil then
		return
	end

	local basePart = Appearance.getBaseFromKey(instance)

	local state: KeyState = {
		originalCFrame = instance.CFrame,
		originalColor = instance.Color,
		originalMaterial = instance.Material,
		createdGui = nil,
		themeConnection = nil,
		pressed = false,
		currentTween = nil,
		basePart = basePart,
	}
	trackedKeys[instance] = state

	state.themeConnection = Appearance.connectKeyTheme(instance)
	state.createdGui = createLetterGui(instance)

	if basePart ~= nil then
		Appearance.wireBase(basePart)
	end
end

function KeyTracking.unwireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		return
	end

	local state = trackedKeys[instance]
	if state == nil then
		return
	end
	trackedKeys[instance] = nil
	pressedKeys[instance] = nil

	cancelTween(state)
	if state.themeConnection ~= nil then
		state.themeConnection:Disconnect()
	end
	if instance.Parent ~= nil then
		instance.CFrame = state.originalCFrame
		instance.Color = state.originalColor
		instance.Material = state.originalMaterial
	end

	local createdGui = state.createdGui
	if createdGui ~= nil then
		createdGui:Destroy()
	end

	if state.basePart ~= nil then
		Appearance.unwireBase(state.basePart)
	end
end

function KeyTracking.updateKeys()
	table.clear(keysUnderPlayer)

	local character = player.Character
	if excludedCharacter ~= character then
		excludedCharacter = character

		local excludedInstances: { Instance } = {}
		if character ~= nil then
			table.insert(excludedInstances, character)
		end
		keyOverlapParams.ExcludeInstances = excludedInstances
	end

	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local queryCFrame = CFrame.new(root.Position + KEY_QUERY_OFFSET)
		local nearbyParts = workspace:GetPartBoundsInBox(queryCFrame, KEY_QUERY_SIZE, keyOverlapParams)

		for _, part in nearbyParts do
			if part:IsA("MeshPart") then
				local state = trackedKeys[part]
				if state ~= nil and isPlayerOnKey(root.Position, part) then
					keysUnderPlayer[part] = true
					pressKey(part, state)
				end
			end
		end
	end

	for key in pressedKeys do
		if not keysUnderPlayer[key] then
			local state = trackedKeys[key]
			if state ~= nil then
				releaseKey(key, state)
			else
				pressedKeys[key] = nil
			end
		end
	end
end

return KeyTracking
