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
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AuthoredVfx = require(ReplicatedStorage.Shared.AuthoredVfx)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local VfxScaler = require(ReplicatedStorage.Shared.VfxScaler)

local log = Log.new("MergeVfxController")
-- Grace period past the longest authored particle lifetime before the clone is
-- destroyed, so nothing pops out mid-fade.
local VFX_LINGER = 0.5
local VFX_SCALE_OPTIONS: VfxScaler.Options = {
	motion = true,
	offsets = true,
	lights = true,
}

local mergeVfxFolder = ReplicatedStorage.Assets.VFX.Merge

local MergeVfxController = {}

-- Resolved once in Init rather than per merge: merges are frequent, and a
-- missing template should warn at boot, not spam a line per merge.
local mergeVfxTemplate: BasePart? = nil

local function play(position: Vector3)
	local template = mergeVfxTemplate
	if template == nil then
		return
	end

	local burst = template:Clone()
	burst.Name = "MergeSquishyVfx"
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanTouch = false
	burst.CanQuery = false
	burst.CastShadow = false
	-- The authored ball is an editor handle; only its particles render.
	burst.Transparency = 1
	-- Keep the authored orientation, discard its old scene-space position.
	burst.CFrame = CFrame.new(position) * burst.CFrame.Rotation
	burst.Parent = Workspace
	VfxScaler.scale(burst, MergeConfig.MERGE_VFX_SCALE, VFX_SCALE_OPTIONS)

	Debris:AddItem(burst, AuthoredVfx.emitBurst(burst) + VFX_LINGER)
end

function MergeVfxController.Init()
	local template = mergeVfxFolder:FindFirstChild(MergeConfig.MERGE_VFX_TEMPLATE_NAME)
	if
		template ~= nil
		and template:IsA("BasePart")
		and template:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
	then
		mergeVfxTemplate = template
	else
		log.warn(
			`Assets.VFX.Merge.{MergeConfig.MERGE_VFX_TEMPLATE_NAME} is missing or malformed -- merges have no burst`
		)
	end

	Net.mergeSquishyVfx.listen(function(data)
		play(Vector3.new(data.worldX, data.worldY, data.worldZ))
	end)
end

function MergeVfxController.Start()
	log.info("ready (client-authored merge bursts)")
end

return MergeVfxController
