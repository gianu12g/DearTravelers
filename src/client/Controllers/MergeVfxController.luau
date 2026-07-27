--!strict
--[[
	Renders the authored merge burst locally for every observer.

	Same split as LaunchVfxController, for the same reason: MergeService owns
	whether a merge happened and where, and broadcasts only that cosmetic fact.
	The clone and the ParticleEmitter:Emit() happen HERE, because Emit() is a
	transient request that can fire before a freshly-parented server clone has
	reached this client -- which shows up as a merge that silently produces no
	particles for everyone except the host.

	Every emitter in the pack stays disabled; its authored EmitCount/EmitDelay
	attributes drive the one-shot (see Shared.AuthoredVfx).

	The merge SFX rides the same broadcast, so every observer hears the pop
	where it happened.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local AuthoredVfx = require(ReplicatedStorage.Shared.AuthoredVfx)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)
local VfxScaler = require(ReplicatedStorage.Shared.VfxScaler)

local log = Log.new("MergeVfxController")
-- Grace period past the longest authored particle lifetime before the clone is
-- destroyed, so nothing pops out mid-fade.
local VFX_LINGER = 0.5
-- One of these is picked per merge so back-to-back merges don't sound cloned.
-- Each entry carries its own head trim (AssetIds/Sounds `Start`), since the two
-- uploads don't open with the same amount of dead air.
local MERGE_SOUND_ENTRIES: { Sounds.Entry } = {
	Sounds.MergeSquishyA,
	Sounds.MergeSquishyB,
}
local MERGE_SOUND_VOLUME = 1
-- Same generous fixed cleanup window MushController uses: covers the whole clip
-- (and a SoundId that never loads, so Ended never fires) without a Length wait.
local MERGE_SOUND_LIFETIME = 10
local VFX_SCALE_OPTIONS: VfxScaler.Options = {
	motion = true,
	offsets = true,
	lights = true,
}

local mergeVfxFolder = ReplicatedStorage.Assets.VFX.Merge

local MergeVfxController = {}

-- Resolved once in Init rather than searching ReplicatedStorage per merge.
-- Missing catalog assets warn at boot, not once per burst.
local mergeVfxTemplates: { [string]: Instance } = {}

local function preparePart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	-- Authored holder parts are editor handles; only their particles render.
	part.Transparency = 1
end

local function isMergePopTemplate(template: Instance): boolean
	if not template:IsA("BasePart") and not template:IsA("Model") then
		return false
	end
	if not template:IsA("BasePart") and template:FindFirstChildWhichIsA("BasePart", true) == nil then
		return false
	end
	return template:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
end

--[[
	The pop SFX gets its own anchored, inert emitter Part instead of riding the
	cosmetic burst clone: `play` bails out entirely when a player's Merge Pop
	template is missing or malformed, and a merge should still be audible then.
	A fresh Sound per merge lets rapid merges layer instead of restarting one.
]]
local function playMergeSound(position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "MergeSoundEmitter"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local sound = Instance.new("Sound")
	sound.Name = "MergeSound"
	sound.Volume = MERGE_SOUND_VOLUME
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	SoundKit.apply(sound, MERGE_SOUND_ENTRIES[math.random(#MERGE_SOUND_ENTRIES)])
	sound.Parent = anchor

	Debris:AddItem(anchor, MERGE_SOUND_LIFETIME)
	sound:Play()
end

local function play(templateName: string, position: Vector3)
	local template = mergeVfxTemplates[templateName] or mergeVfxTemplates[CosmeticsCatalog.DEFAULT_MERGE_POP_ID]
	if template == nil then
		return
	end

	local burst = template:Clone()
	burst.Name = "MergeSquishyVfx"
	if burst:IsA("BasePart") then
		preparePart(burst)
		-- Keep the authored orientation, discard its old scene-space position.
		burst.CFrame = CFrame.new(position) * burst.CFrame.Rotation
	elseif burst:IsA("Model") then
		for _, descendant in burst:GetDescendants() do
			if descendant:IsA("BasePart") then
				preparePart(descendant)
			end
		end
		burst:PivotTo(CFrame.new(position) * burst:GetPivot().Rotation)
	else
		burst:Destroy()
		return
	end
	burst.Parent = Workspace
	VfxScaler.scale(burst, MergeConfig.MERGE_VFX_SCALE, VFX_SCALE_OPTIONS)

	Debris:AddItem(burst, AuthoredVfx.emitBurst(burst) + VFX_LINGER)
end

function MergeVfxController.Init()
	table.clear(mergeVfxTemplates)
	for _, entry in CosmeticsCatalog.MergePops do
		local template = mergeVfxFolder:FindFirstChild(entry.Id)
		if template ~= nil and isMergePopTemplate(template) then
			mergeVfxTemplates[entry.Id] = template
		else
			log.warn(`Assets.VFX.Merge.{entry.Id} is missing or malformed -- Merge Pop cosmetic unavailable`)
		end
	end

	Net.mergeSquishyVfx.listen(function(data)
		local position = Vector3.new(data.worldX, data.worldY, data.worldZ)
		playMergeSound(position)
		play(data.templateName, position)
	end)
end

function MergeVfxController.Start()
	log.info("ready (client-authored cosmetic merge bursts)")
end

return MergeVfxController
