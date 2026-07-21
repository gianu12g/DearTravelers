--!strict
--[[
	Music/SFX/keyboard volume sliders. Ported from the source's
	Controllers/SettingsController.luau (renamed: this repo has no existing
	SettingsController to collide with, but UISystem/ keeps every ported
	controller namespaced together per PORT-SPEC.md §1).

	Live-applies on every drag frame (immediate feedback); only fires
	settingUpdate on DragEnd (PORT-SPEC.md §3), same as the source fired
	Packets.Settings.UpdateSetting only there. Re-applies whenever
	{"UISystem","Settings"} changes, whether that's this client's own write
	round-tripping back or a change made elsewhere (e.g. a dev console
	edit).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("UISettingsController")

type SettingKey = "Music" | "SFX" | "Keyboard"

type SettingsData = {
	Music: number,
	SFX: number,
	Keyboard: number,
}

local settings: SettingsData = { Music = 0.1, SFX = 0.9, Keyboard = 1 }

local UISettingsController = {}

local function roundVolume(value: number): number
	return math.clamp(math.round(value * 10) / 10, 0, 1)
end

local function setDragPosition(dragger: GuiObject, value: number)
	local bar = dragger.Parent
	if bar == nil or not bar:IsA("GuiObject") or bar.AbsoluteSize.X <= 0 then
		dragger.Position = UDim2.new(roundVolume(value), 0, dragger.Position.Y.Scale, dragger.Position.Y.Offset)
		return
	end

	-- UIDragDetector keeps the entire thumb inside the bar, so the thumb's
	-- Position.X.Scale cannot physically reach 0 or 1. Map the logical 0..1
	-- volume range onto the thumb's actual left-to-right travel instead.
	local thumbWidth = math.min(dragger.AbsoluteSize.X, bar.AbsoluteSize.X)
	local travelWidth = bar.AbsoluteSize.X - thumbWidth
	local left = roundVolume(value) * travelWidth
	local anchorPosition = left + thumbWidth * dragger.AnchorPoint.X
	local xScale = anchorPosition / bar.AbsoluteSize.X
	dragger.Position = UDim2.new(xScale, 0, dragger.Position.Y.Scale, dragger.Position.Y.Offset)
end

local function getDragValue(dragger: GuiObject): number
	local bar = dragger.Parent
	if bar == nil or not bar:IsA("GuiObject") then
		return roundVolume(dragger.Position.X.Scale)
	end

	local travelWidth = bar.AbsoluteSize.X - dragger.AbsoluteSize.X
	if travelWidth <= 0 then
		return 0
	end

	local anchorPosition = dragger.Position.X.Scale * bar.AbsoluteSize.X + dragger.Position.X.Offset
	local traveled = anchorPosition - dragger.AbsoluteSize.X * dragger.AnchorPoint.X
	return roundVolume(traveled / travelWidth)
end

function UISettingsController.Start()
	local frame = Frames.get("Settings")
	local main = frame:WaitForChild("Main")
	local holder = main:WaitForChild("Holder")

	local musicHolder = holder:WaitForChild("Music")
	local musicBar = musicHolder:WaitForChild("Bar")
	local musicDrag = musicBar:WaitForChild("Dragger") :: GuiObject
	local musicDetector = musicDrag:WaitForChild("UIDragDetector") :: UIDragDetector

	local sfxHolder = holder:WaitForChild("Sfx")
	local sfxBar = sfxHolder:WaitForChild("Bar")
	local sfxDrag = sfxBar:WaitForChild("Dragger") :: GuiObject
	local sfxDetector = sfxDrag:WaitForChild("UIDragDetector") :: UIDragDetector

	local keyboardHolder = holder:WaitForChild("Keyboard")
	local keyboardBar = keyboardHolder:WaitForChild("Bar")
	local keyboardDrag = keyboardBar:WaitForChild("Dragger") :: GuiObject
	local keyboardDetector = keyboardDrag:WaitForChild("UIDragDetector") :: UIDragDetector

	local musicGroup = SoundService:FindFirstChild("Music") :: SoundGroup?
	local sfxGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	local keyboardGroup = SoundService:FindFirstChild("Keyboard") :: SoundGroup?

	local function applyVolumes()
		if musicGroup ~= nil then
			musicGroup.Volume = settings.Music
		end
		if sfxGroup ~= nil then
			sfxGroup.Volume = settings.SFX
		end
		if keyboardGroup ~= nil then
			keyboardGroup.Volume = settings.Keyboard
		end
	end

	local function updateSetting(key: SettingKey, value: number)
		if key == "Music" then
			settings.Music = value
		elseif key == "SFX" then
			settings.SFX = value
		else
			settings.Keyboard = value
		end
		applyVolumes()
	end

	local function bindSlider(dragger: GuiObject, detector: UIDragDetector, key: SettingKey)
		dragger:GetPropertyChangedSignal("Position"):Connect(function()
			updateSetting(key, getDragValue(dragger))
		end)

		detector.DragEnd:Connect(function()
			Net.settingUpdate.send({ key = key, value = getDragValue(dragger) })
		end)
	end

	setDragPosition(musicDrag, settings.Music)
	setDragPosition(sfxDrag, settings.SFX)
	setDragPosition(keyboardDrag, settings.Keyboard)
	applyVolumes()

	DataController.observe({ "UISystem", "Settings" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		settings = value
		setDragPosition(musicDrag, settings.Music or 0)
		setDragPosition(sfxDrag, settings.SFX or 0)
		setDragPosition(keyboardDrag, settings.Keyboard or 0)
		applyVolumes()
	end)

	bindSlider(musicDrag, musicDetector, "Music")
	bindSlider(sfxDrag, sfxDetector, "SFX")
	bindSlider(keyboardDrag, keyboardDetector, "Keyboard")

	log.info("ready")
end

return UISettingsController
