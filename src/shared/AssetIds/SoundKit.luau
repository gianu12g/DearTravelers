--!strict
--[[
	The one place an AssetIds/Sounds entry becomes a configured Sound: content
	ID plus the entry's optional `Start` head trim.

	The trim is a PlaybackRegion, not a post-Play `TimePosition` seek. A seek
	has to be redone after every `Play()` (and is discarded outright if the
	Sound has not started yet), which makes it wrong for the Sounds that are
	created once and replayed forever -- UIKit builds one hover Sound per
	button and plays it on every hover. A region is set once and every later
	play obeys it, so no call site has to remember anything.

	Entries without a `Start` are left completely alone: regions stay off, and
	`Ended`/`TimeLength` keep their stock behavior for everything that was
	already relying on them.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)

-- A region needs an end as well as a start. Nothing in this project is
-- remotely this long, and the engine stops at the real end of the asset --
-- this value only has to sit past it.
local REGION_END = 3600

local SoundKit = {}

-- Raw-ID form, for the sounds that are authored per-model rather than listed
-- in AssetIds/Sounds (MergeObjectVisuals' per-tier mush sounds read their ID
-- off a template attribute). Pass `start = nil` to leave playback untrimmed.
function SoundKit.applyId(sound: Sound, assetId: string, start: number?)
	sound.SoundId = assetId

	if start ~= nil and start > 0 then
		sound.PlaybackRegion = NumberRange.new(start, REGION_END)
		sound.PlaybackRegionsEnabled = true
	end
end

function SoundKit.apply(sound: Sound, entry: Sounds.Entry)
	SoundKit.applyId(sound, `rbxassetid://{entry.Id}`, entry.Start)
end

return SoundKit
