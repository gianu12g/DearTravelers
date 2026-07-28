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

	Extended to be the one place every OTHER Sound property gets set too --
	named rolloff profiles, SoundGroup resolution, one-shot lifetime -- so the
	~8-line `Instance.new("Sound")` block that used to be copy-pasted at every
	call site (LaunchVfxController, MergeVfxController, MushController,
	UIKitController, NotificationController) collapses into one function call
	each. MergeService.Launch used to be on this list too, but the launch
	sounds moved off the server entirely: it now only broadcasts
	Net.mergeLaunchAudio, and LaunchVfxController -- already above -- is what
	plays them, through this same module, on the client. See `Profiles` for
	the named rolloff presets and `playOn`/`playAt`/`playOnId`/`playAtId` for
	the one-shot helpers.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)

local log = Log.new("SoundKit")

-- A region needs an end as well as a start. Nothing in this project is
-- remotely this long, and the engine stops at the real end of the asset --
-- this value only has to sit past it.
local REGION_END = 3600

-- One-shot lifetime for playOn/playAt(Id): long enough to cover any clip in
-- this project -- and a SoundId that never loads, so `Ended` never fires --
-- without waiting on Length. Every call site used this same fixed 10s window
-- before migrating here.
local ONE_SHOT_LIFETIME = 10

-- Every one-shot SFX in this project mixes through the same bus. Profiles
-- that need a different one (AmbientMusicController's "Music", KeyCaps'
-- "Keyboard") resolve their own group name directly through getSoundGroup
-- instead of going through playOn/playAt.
local SFX_GROUP_NAME = "SFX"

local SoundKit = {}

export type Profile = {
	Spatial: boolean,
	RollOffMode: Enum.RollOffMode?,
	RollOffMinDistance: number?,
	RollOffMaxDistance: number?,
}

--[[
	Named rolloff presets, so a call site picks a NAME instead of re-deciding
	min/max distances every time it copies the Sound-construction block.

	LOCAL_POP -- effects that happen at the local player's own base (merge
	pop, carried-squishy mush): the source is always close, so a short
	InverseTapered falloff is plenty.

	LAUNCH_IMPACT -- launch sequence audio (mush materialize, touchdown thud,
	explosion). InverseTapered still reaches exactly zero at
	RollOffMaxDistance (see the header above), so THIS max has to clear the
	whole map, not just "far enough": 8 bases ring a radius-190 layout on a
	770x841 map, and a launch always lands at ANOTHER player's base, so the
	impact is never closer than ~145 studs. 550 comfortably reaches the
	farthest corner while still tapering with distance instead of playing at
	a map-wide constant volume -- the bug that made the explosion inaudible
	on every launch (max 80, closest possible impact ~145) is exactly this
	profile existing to fix.

	UI -- non-spatial: for sounds parented to a GuiObject rather than a
	BasePart (UIKitController's hover/click, NotificationController's toast
	chime), where no RollOff* property means anything.
]]
SoundKit.Profiles = {
	LOCAL_POP = {
		Spatial = true,
		RollOffMode = Enum.RollOffMode.InverseTapered,
		RollOffMinDistance = 8,
		RollOffMaxDistance = 80,
	} :: Profile,

	LAUNCH_IMPACT = {
		Spatial = true,
		RollOffMode = Enum.RollOffMode.InverseTapered,
		RollOffMinDistance = 60,
		RollOffMaxDistance = 550,
	} :: Profile,

	UI = {
		Spatial = false,
	} :: Profile,
}

local warnedGroups: { [string]: boolean } = {}

--[[
	Looks up a SoundGroup under SoundService by name, warning ONCE if it is
	absent instead of returning nil silently.

	The server must never create the group itself: SoundService replicates,
	so a server-side `Instance.new("SoundGroup")` would create a SECOND group
	alongside the place-authored one rather than standing in for it -- the
	place's own SFX/Music/Keyboard groups are expected to already exist by the
	time a server Sound needs one, and a server that "fixes" a missing one
	only duplicates it for every client. A client missing the group creates
	one locally as a fallback instead -- AmbientMusicController's "Music" and
	KeyCaps' "Keyboard" both rely on this.
]]
function SoundKit.getSoundGroup(groupName: string): SoundGroup?
	local existing = SoundService:FindFirstChild(groupName)
	if existing ~= nil then
		if existing:IsA("SoundGroup") then
			return existing
		end
		if not warnedGroups[groupName] then
			warnedGroups[groupName] = true
			log.warn(`SoundService.{groupName} exists but is a {existing.ClassName}, not a SoundGroup`)
		end
		return nil
	end

	if not warnedGroups[groupName] then
		warnedGroups[groupName] = true
		log.warn(`SoundService.{groupName} SoundGroup missing`)
	end

	if RunService:IsServer() then
		return nil
	end

	local group = Instance.new("SoundGroup")
	group.Name = groupName
	group.Parent = SoundService
	return group
end

-- Applies a named profile's rolloff. A no-op for non-spatial profiles (UI):
-- nothing there is parented to a BasePart, so RollOff* would do nothing.
-- Public because UIKitController/NotificationController build ONE persistent
-- Sound per decorated item/kind and replay it forever (same "set once, obeyed
-- on every future Play()" shape as a PlaybackRegion -- see the header), so
-- they call this directly instead of going through playOn/playAt, which both
-- create-and-discard a single-use Sound.
function SoundKit.applyProfile(sound: Sound, profile: Profile)
	if not profile.Spatial then
		return
	end
	sound.RollOffMode = profile.RollOffMode or Enum.RollOffMode.Inverse
	sound.RollOffMinDistance = profile.RollOffMinDistance or 10
	sound.RollOffMaxDistance = profile.RollOffMaxDistance or 10000
end

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

local function newSoundAnchor(name: string, position: Vector3): Part
	local anchor = Instance.new("Part")
	anchor.Name = `{name}Anchor`
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace
	return anchor
end

--[[
	Attaches a fresh one-shot Sound to an EXISTING part -- the carried
	squishy, the launch projectile -- so it moves/replicates with whatever
	that part is already doing. Returns nil (and creates nothing) if the part
	has already been destroyed/unparented, which every call site used to
	guard by hand.
]]
function SoundKit.playOn(part: BasePart, name: string, entry: Sounds.Entry, volume: number, profile: Profile): Sound?
	if part.Parent == nil then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.Volume = volume
	sound.SoundGroup = SoundKit.getSoundGroup(SFX_GROUP_NAME)
	SoundKit.applyProfile(sound, profile)
	SoundKit.apply(sound, entry)
	sound.Parent = part
	Debris:AddItem(sound, ONE_SHOT_LIFETIME)
	sound:Play()
	return sound
end

-- Raw-ID counterpart of playOn -- see SoundKit.applyId's own note on why the
-- per-tier mush sounds need this form instead of a Sounds.Entry.
function SoundKit.playOnId(
	part: BasePart,
	name: string,
	assetId: string,
	start: number?,
	volume: number,
	profile: Profile
): Sound?
	if part.Parent == nil then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.Volume = volume
	sound.SoundGroup = SoundKit.getSoundGroup(SFX_GROUP_NAME)
	SoundKit.applyProfile(sound, profile)
	SoundKit.applyId(sound, assetId, start)
	sound.Parent = part
	Debris:AddItem(sound, ONE_SHOT_LIFETIME)
	sound:Play()
	return sound
end

--[[
	Same as playOn, but for a position with no existing part to ride on -- a
	merge or launch impact point. Builds the invisible anchor Part (Anchored,
	non-interactive, Transparency 1) every call site used to hand-roll, plays
	the Sound on it via playOn, and Debris's both independently: the anchor's
	own timer is a backstop (destroying it cascades to the Sound too), not a
	substitute for the Sound's own.
]]
function SoundKit.playAt(position: Vector3, name: string, entry: Sounds.Entry, volume: number, profile: Profile)
	local anchor = newSoundAnchor(name, position)
	SoundKit.playOn(anchor, name, entry, volume, profile)
	Debris:AddItem(anchor, ONE_SHOT_LIFETIME)
end

-- Raw-ID counterpart of playAt -- see playOnId.
function SoundKit.playAtId(
	position: Vector3,
	name: string,
	assetId: string,
	start: number?,
	volume: number,
	profile: Profile
)
	local anchor = newSoundAnchor(name, position)
	SoundKit.playOnId(anchor, name, assetId, start, volume, profile)
	Debris:AddItem(anchor, ONE_SHOT_LIFETIME)
end

return SoundKit
