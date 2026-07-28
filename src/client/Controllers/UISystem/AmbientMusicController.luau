--!strict
--[[
	Background music playlist, looping sequentially forever. Ported from the
	source's Controllers/AmbientMusicController.luau. Start()-only, like the
	source -- there is nothing to register early, just a loop to run once
	everything else has settled.

	PORT-SPEC.md §6.2 / this task: SoundService.Music is expected to already
	exist in the target place. Resolved through SoundKit.getSoundGroup, which
	creates one as a client-side fallback if it doesn't, so a missing
	SoundGroup degrades to "plays without a mixer bus" instead of erroring the
	whole controller.

	Bug fixed in passing: the source named its per-track container Folder
	"Music" -- the SAME name as the SoundGroup it plays through, so
	SoundService ends up with two direct children both called "Music" (a
	Folder and a SoundGroup). Not a crash, but exactly the kind of ambiguous
	naming .claude/rules/model-naming-style.md calls out; renamed to
	"AmbientMusicTracks" here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local GeneralConfig = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)

local log = Log.new("AmbientMusicController")

local AmbientMusicController = {}

function AmbientMusicController.Start()
	local musicGroup = SoundKit.getSoundGroup("Music")

	local tracksFolder = Instance.new("Folder")
	tracksFolder.Name = "AmbientMusicTracks"

	local tracks: { Sound } = {}
	for index, entry in GeneralConfig.AmbientMusic do
		local track = Instance.new("Sound")
		SoundKit.apply(track, entry)
		track.Name = tostring(index)
		track.SoundGroup = musicGroup
		track.Parent = tracksFolder
		table.insert(tracks, track)
	end

	tracksFolder.Parent = SoundService

	log.info(`ready ({#tracks} tracks)`)

	-- Sequencing hangs off Ended, so a music entry must not be given a `Start`
	-- in AssetIds/Sounds without checking that assumption: SoundKit turns a
	-- trim into a playback region, and a region's end is what Ended then
	-- reports. The trim exists for short SFX; nothing here uses one.
	while true do
		for _, track in tracks do
			track:Play()
			track.Ended:Wait()
		end
		task.wait()
	end
end

return AmbientMusicController
