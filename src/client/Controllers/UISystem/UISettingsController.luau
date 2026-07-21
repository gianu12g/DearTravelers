--!strict
--[[
	Music/SFX volume sliders. Ported from the source's
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

type SettingKey = "Music" | "SFX"

type SettingsData = {
	Music: number,
	SFX: number,
}

local settings: SettingsData = { Music = 0.1, SFX = 0.9 }

local UISettingsController = {}

local function roundVolume(value: number): number
	local rounded = math.round(value * 10) / 10
	if rounded < 0.05 then
		return 0
	end
	return rounded
end

local function setDragPosition(dragger: GuiObject, value: number)
	dragger.Position = UDim2.fromScale(roundVolume(value), dragger.Position.Y.Scale)
end

local function getDragValue(dragger: GuiObject): number
	return roundVolume(dragger.Position.X.Scale)
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

	local musicGroup = SoundService:FindFirstChild("Music") :: SoundGroup?
	local sfxGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?

	local function applyVolumes()
		if musicGroup ~= nil then
			musicGroup.Volume = settings.Music
		end
		if sfxGroup ~= nil then
			sfxGroup.Volume = settings.SFX
		end
	end

	local function updateSetting(key: SettingKey, value: number)
		if key == "Music" then
			settings.Music = value
		else
			settings.SFX = value
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
	applyVolumes()

	DataController.observe({ "UISystem", "Settings" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		settings = value
		setDragPosition(musicDrag, settings.Music or 0)
		setDragPosition(sfxDrag, settings.SFX or 0)
		applyVolumes()
	end)

	bindSlider(musicDrag, musicDetector, "Music")
	bindSlider(sfxDrag, sfxDetector, "SFX")

	log.info("ready")
end

return UISettingsController
