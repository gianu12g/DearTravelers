--!strict
--[[
	Background music playlist, looping sequentially forever. Ported from the
	source's Controllers/AmbientMusicController.luau. Start()-only, like the
	source -- there is nothing to register early, just a loop to run once
	everything else has settled.

	PORT-SPEC.md §6.2 / this task: SoundService.Music is expected to already
	exist in the target place, but creates one as a fallback if it doesn't,
	so a missing SoundGroup degrades to "plays without a mixer bus" instead
	of erroring the whole controller.

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

local log = Log.new("AmbientMusicController")

local AmbientMusicController = {}

function AmbientMusicController.Start()
	local musicGroup = SoundService:FindFirstChild("Music")
	if musicGroup == nil or not musicGroup:IsA("SoundGroup") then
		log.warn("SoundService.Music SoundGroup missing -- creating one as a fallback")
		local group = Instance.new("SoundGroup")
		group.Name = "Music"
		group.Parent = SoundService
		musicGroup = group
	end

	local tracksFolder = Instance.new("Folder")
	tracksFolder.Name = "AmbientMusicTracks"

	local tracks: { Sound } = {}
	for index, id in GeneralConfig.AmbientMusic do
		local track = Instance.new("Sound")
		track.SoundId = `rbxassetid://{id}`
		track.Name = tostring(index)
		track.SoundGroup = musicGroup :: SoundGroup
		track.Parent = tracksFolder
		table.insert(tracks, track)
	end

	tracksFolder.Parent = SoundService

	log.info(`ready ({#tracks} tracks)`)

	while true do
		for _, track in tracks do
			track:Play()
			track.Ended:Wait()
		end
		task.wait()
	end
end

return AmbientMusicController
