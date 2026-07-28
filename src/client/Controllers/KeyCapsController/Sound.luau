--!strict
--[[
	Per-press key click sound, played on the key MeshPart itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)

local SOUND_NAME = "ClickSound"
local SOUND_VOLUME = 0.75
local SOUND_GROUP_NAME = "Keyboard"
local SOUND_LOAD_TIMEOUT = 3
local PLAYBACK_SPEED_MIN = 1
local PLAYBACK_SPEED_MAX = 1.2

-- Resolved once at module load, same as before, but through SoundKit's shared
-- resolver rather than a hand-rolled lookup: it warns once instead of
-- hard-erroring the whole script if "Keyboard" is ever missing/misconfigured,
-- and creates the client-side fallback the same way AmbientMusicController
-- does for "Music" -- see SoundKit.getSoundGroup's own header note on why
-- that fallback is client-only. Everything below this (Ended/Stopped +
-- timeout cleanup, PlaybackSpeed randomisation) is untouched.
local keyboardSoundGroup = SoundKit.getSoundGroup(SOUND_GROUP_NAME)

local Sound = {}

-- One transient Sound per press allows rapid or overlapping presses to layer.
-- Ended/Stopped handle the normal path; the timeout also cleans up a SoundId
-- that never loads and therefore never emits either signal.
function Sound.playKeySound(key: MeshPart)
	local sound = Instance.new("Sound")
	sound.Name = SOUND_NAME
	SoundKit.apply(sound, Sounds.KeyPress)
	sound.Volume = SOUND_VOLUME
	sound.SoundGroup = keyboardSoundGroup
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

return Sound
