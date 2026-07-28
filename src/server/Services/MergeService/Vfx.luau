--!strict
--[[
	Merge/launch visual and audio effects, plus the cosmetic-template lookups
	that pick which one to play for a given player. Every burst here is a
	transient send/spawn with no module-level bookkeeping of its own -- Assets
	owns the discovered templates, this just plays them.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent.Assets)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local DataService = require(script.Parent.Parent.DataService)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local EXPLOSION_LIFETIME = 1.5
local EXPLOSION_PARTICLE_COUNT = 40
local SQUISHY_POP_LIFETIME = 1
local SQUISHY_POP_PARTICLE_COUNT = 18

local Vfx = {}

function Vfx.equippedLaunchBeamTemplate(player: Player): Model?
	local playerData = DataService.getData(player)
	if playerData == nil then
		return Assets.getDefaultLaunchBeamTemplate()
	end
	return Assets.getLaunchBeamTemplate(playerData.Cosmetics.SquishyBeamId) or Assets.getDefaultLaunchBeamTemplate()
end

local function equippedMergePopTemplateName(player: Player): string?
	local playerData = DataService.getData(player)
	if playerData ~= nil then
		local equippedId = playerData.Cosmetics.MergePopId
		if Assets.isMergePopTemplateId(equippedId) then
			return equippedId
		end
	end

	local defaultId = CosmeticsCatalog.DEFAULT_MERGE_POP_ID
	return if Assets.isMergePopTemplateId(defaultId) then defaultId else nil
end

--[[
	Placeholder-quality mini explosion at a merge's target (mergee) position --
	ParticleEmitter burst only, no Sound: the merge SFX is played per-client by
	MergeVfxController off the sendMergeSquishyVfx broadcast below.
	Parented under the pad's own MergeObjects folder per the naming rules
	(model-naming-style.md), so it is destroyed along with everything else if
	the pad deactivates mid-burst instead of leaking into Workspace.
]]
function Vfx.spawnMergeVfx(objectsFolder: Folder, position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "MergeVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = objectsFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Burst"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.35, 0.75)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.6)
	emitter.Parent = anchor
	emitter:Emit(EXPLOSION_PARTICLE_COUNT)

	Debris:AddItem(anchor, EXPLOSION_LIFETIME)
end

-- A light, bubbly death burst that survives after the authoritative squishy
-- Part is destroyed. It is purely visual: the invisible anchor cannot touch,
-- query, collide, or apply force, and Debris guarantees cleanup.
function Vfx.spawnSquishyPopVfx(objectsFolder: Folder, position: Vector3, color: Color3, squishySize: number)
	local anchor = Instance.new("Part")
	anchor.Name = "SquishyPopVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = objectsFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Bubbles"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.65))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.clamp(squishySize * 0.16, 0.35, 1.1)),
		NumberSequenceKeypoint.new(0.55, math.clamp(squishySize * 0.24, 0.5, 1.6)),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.6)
	emitter.Speed = NumberRange.new(4 + squishySize * 0.35, 7 + squishySize * 0.55)
	emitter.Drag = 4
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-100, 100)
	emitter.LightEmission = 0.65
	emitter.Parent = anchor
	emitter:Emit(SQUISHY_POP_PARTICLE_COUNT)

	Debris:AddItem(anchor, SQUISHY_POP_LIFETIME)
end

--[[
	ParticleEmitter:Emit() is a transient request. Calling it here immediately
	after parenting a fresh server clone races replication: observers can receive
	the clone after the burst already happened. Send only the server-owned effect
	name, position, and timing; LaunchVfxController clones the authored template
	and calls Emit locally after every emitter exists on that client.
]]
local function sendLaunchVfx(templateName: string, position: Vector3)
	Net.mergeLaunchVfx.sendToAll({
		templateName = templateName,
		worldX = position.X,
		worldY = position.Y,
		worldZ = position.Z,
	})
end

-- The squishy's own Explosion burst, pinned to explosionPosAtt on its body.
function Vfx.spawnLaunchImpactVfx(position: Vector3)
	if Assets.getLaunchExplosionTemplate() == nil then
		return
	end

	sendLaunchVfx(MergeConfig.LAUNCH_EXPLOSION_TEMPLATE_NAME, position)
end

-- The floor burst at the ground contact point directly under the squishy.
function Vfx.spawnGroundHitVfx(position: Vector3)
	if Assets.getLaunchGroundHitTemplate() == nil then
		return
	end

	sendLaunchVfx(MergeConfig.LAUNCH_GROUND_HIT_TEMPLATE_NAME, position)
end

--[[
	Launch-sequence audio (mush materialize, touchdown thud, explosion), sent
	independently of spawnLaunchImpactVfx/spawnGroundHitVfx above: both of
	those early-return when their authored VFX template is missing, and a
	launch should still be audible even then -- see Net.mergeLaunchAudio's own
	header note and MergeService.Launch's comment on why the thud was already
	pulled off the VFX broadcast for exactly this reason.
]]
local function sendLaunchAudio(kind: string, position: Vector3, soundId: string, soundVolume: number)
	Net.mergeLaunchAudio.sendToAll({
		kind = kind,
		soundId = soundId,
		soundVolume = soundVolume,
		worldX = position.X,
		worldY = position.Y,
		worldZ = position.Z,
	})
end

-- Per-tier mush sound: id and volume come off the model template's own
-- attributes (MergeObjectVisuals.getMushSound), not from AssetIds, so they
-- have to cross the wire raw -- there is no client-visible entry to name
-- instead. A no-op when the tier authored no sound.
function Vfx.sendLaunchMushAudio(position: Vector3, soundId: string, soundVolume: number)
	if soundId == "" then
		return
	end
	sendLaunchAudio("Mush", position, soundId, soundVolume)
end

-- Touchdown thud. The client already has Sounds.SquishyLand, so it resolves
-- the entry itself from `kind`; only the impact position is server-owned.
function Vfx.sendLaunchLandAudio(position: Vector3)
	sendLaunchAudio("Land", position, "", 0)
end

-- The squishy's own Explosion pop, pinned to explosionPosAtt on its body.
-- Same resolve-from-`kind` shape as sendLaunchLandAudio.
function Vfx.sendLaunchExplosionAudio(position: Vector3)
	sendLaunchAudio("Explosion", position, "", 0)
end

--[[
	The authored merge burst, broadcast for the same reason as the launch packs
	-- see sendLaunchVfx. Plays on top of spawnMergeVfx's procedural pop rather
	than replacing it; the template lookup is checked at boot (Start) so a
	missing pack costs one warn line, not one broadcast per merge.
]]
function Vfx.sendMergeSquishyVfx(player: Player, position: Vector3)
	local templateName = equippedMergePopTemplateName(player)
	if templateName == nil then
		return
	end

	Net.mergeSquishyVfx.sendToAll({
		templateName = templateName,
		worldX = position.X,
		worldY = position.Y,
		worldZ = position.Z,
	})
end

return Vfx
