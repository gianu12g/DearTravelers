--!strict
--[[
	Renders the two authored launch landing bursts locally for every observer,
	and plays the launch sequence's audio (mush materialize, touchdown thud,
	explosion) off the separate Net.mergeLaunchAudio broadcast.

	The server owns when and where GroundHit/Explosion happen and broadcasts
	only that cosmetic event. Cloning and ParticleEmitter:Emit() happen here so
	the one-shot cannot race a newly-replicated server clone. Every emitter stays
	disabled; its authored EmitCount and EmitDelay attributes drive the burst.

	Audio is intentionally NOT bundled onto this broadcast: mergeLaunchVfx (and
	the equivalent GroundHit send) skip sending entirely when their authored
	template is missing, and a launch should still be audible then -- see
	Net.mergeLaunchAudio's own header note. All three launch sounds use
	SoundKit.Profiles.LAUNCH_IMPACT: they have to carry across the whole map
	(a launch always lands at ANOTHER player's base, never closer than ~145
	studs on this map's 8-base ring), not just to nearby observers.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AuthoredVfx = require(ReplicatedStorage.Shared.AuthoredVfx)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)
local VfxScaler = require(ReplicatedStorage.Shared.VfxScaler)

local log = Log.new("LaunchVfxController")
local VFX_LINGER = 0.5
local EXPLOSION_SOUND_VOLUME = 2
local LAND_SOUND_VOLUME = 2
local VFX_SCALE_OPTIONS: VfxScaler.Options = {
	motion = true,
	offsets = true,
	lights = true,
}

local launchVfxFolder = ReplicatedStorage.Assets.VFX.LaunchExplosion

local LaunchVfxController = {}

local function scaleLaunchVfx(root: Instance, effectMultiplier: number?)
	local multiplier = MergeConfig.LAUNCH_VFX_SCALE * (effectMultiplier or 1)
	VfxScaler.scale(root, multiplier, VFX_SCALE_OPTIONS)
end

local function playExplosion(template: Attachment, position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "LaunchImpactVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local explosion = template:Clone()
	-- Keep the authored orientation but discard its old scene-space offset.
	explosion.CFrame = explosion.CFrame.Rotation
	explosion.Parent = anchor
	scaleLaunchVfx(explosion, MergeConfig.LAUNCH_EXPLOSION_VFX_SCALE_MULTIPLIER)

	Debris:AddItem(anchor, AuthoredVfx.emitBurst(explosion) + VFX_LINGER)
end

local function playGroundHit(template: BasePart, position: Vector3)
	local hit = template:Clone()
	hit.Name = "LaunchGroundHitVfx"
	hit.Anchored = true
	hit.CanCollide = false
	hit.CanTouch = false
	hit.CanQuery = false
	hit.CastShadow = false
	-- The authored red ball is an editor handle; only its particles render.
	hit.Transparency = 1
	hit.CFrame = CFrame.new(position) * hit.CFrame.Rotation
	hit.Parent = Workspace
	scaleLaunchVfx(hit)

	Debris:AddItem(hit, AuthoredVfx.emitBurst(hit) + VFX_LINGER)
end

local function play(templateName: string, position: Vector3)
	local template = launchVfxFolder:FindFirstChild(templateName)
	if templateName == MergeConfig.LAUNCH_EXPLOSION_TEMPLATE_NAME then
		if template == nil or not template:IsA("Attachment") then
			log.warn(`LaunchExplosion.{templateName} is missing or is not an Attachment`)
			return
		end
		playExplosion(template, position)
	elseif templateName == MergeConfig.LAUNCH_GROUND_HIT_TEMPLATE_NAME then
		if template == nil or not template:IsA("BasePart") then
			log.warn(`LaunchExplosion.{templateName} is missing or is not a BasePart`)
			return
		end
		playGroundHit(template, position)
	end
end

-- See Net.mergeLaunchAudio's header: "Mush" carries a raw per-tier soundId
-- (no client-visible AssetIds entry exists for it), while "Land" and
-- "Explosion" resolve their own entry from the shared Sounds table, same as
-- every other AssetIds-backed sound in this codebase.
local function playLaunchAudio(kind: string, soundId: string, soundVolume: number, position: Vector3)
	if kind == "Mush" then
		if soundId == "" then
			return
		end
		SoundKit.playAtId(position, "MushSound", soundId, nil, soundVolume, SoundKit.Profiles.LAUNCH_IMPACT)
	elseif kind == "Land" then
		SoundKit.playAt(position, "LandSound", Sounds.SquishyLand, LAND_SOUND_VOLUME, SoundKit.Profiles.LAUNCH_IMPACT)
	elseif kind == "Explosion" then
		SoundKit.playAt(
			position,
			"LaunchExplosionSound",
			Sounds.SquishyPop,
			EXPLOSION_SOUND_VOLUME,
			SoundKit.Profiles.LAUNCH_IMPACT
		)
	else
		log.warn(`unknown launch audio kind "{kind}"`)
	end
end

function LaunchVfxController.Init()
	Net.mergeLaunchVfx.listen(function(data)
		play(data.templateName, Vector3.new(data.worldX, data.worldY, data.worldZ))
	end)

	Net.mergeLaunchAudio.listen(function(data)
		playLaunchAudio(data.kind, data.soundId, data.soundVolume, Vector3.new(data.worldX, data.worldY, data.worldZ))
	end)
end

function LaunchVfxController.Start()
	log.info("ready (client-authored launch bursts)")
end

return LaunchVfxController
