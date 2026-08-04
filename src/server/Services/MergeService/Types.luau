--!strict
--[[
	Shared type definitions for MergeService's split modules, plus the small
	pure sanitize/clamp helpers those types imply and the carry-attribute
	clearing helper several siblings need. Kept dependency-free (besides
	MergeConfig/LaunchBeamRuntime) so every sibling -- and init -- can require
	this without risking a require cycle.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LaunchBeamRuntime = require(ReplicatedStorage.Shared.LaunchBeamRuntime)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)

-- Mirrors the shape written into DataService's TEMPLATE.Merge.Squishies
-- exactly (DataService.luau, Merge field) -- kept local rather than shared
-- for the same "DataService stays generic" reason documented there.
export type MergeObjectEntry = {
	Tier: number,
	X: number,
	Z: number,
	Health: number,
}

export type BaseRecord = {
	part: BasePart,
	spawnArea: BasePart,
}

export type LaunchMapBounds = {
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
}

export type LiveBase = {
	baseName: string,
	spawnArea: BasePart,
	objectsFolder: Folder,
	-- See the header's IDENTITY note: keys are the Parts this service
	-- created, values are the exact entry table each Part represents.
	parts: { [BasePart]: MergeObjectEntry },
	--[[
		Phase 2 UX fix: parts placed where the owner could otherwise
		instantly re-grab them (a drop, a cancelled carry, a merge result)
		start here and leave once the owner has stood CONTINUOUSLY outside
		MergeConfig.REARM_CLEARANCE for MergeConfig.REARM_OUTSIDE_SECONDS --
		see markDisarmed and reArmSweep. Presence = disarmed; the value is
		accumulated continuous-outside seconds, reset to 0 on every frame the
		owner is inside the radius (or has no character at all).

		A plain Lua map, not an Attribute: nothing client-side needs to see
		this, same call `parts` above already makes for server-only
		bookkeeping.
	]]
	disarmed: { [BasePart]: number },
}

-- Phase 2. `entry` is the SAME table referenced from data.Merge.Squishies and
-- from `live.parts[part]` (see the header's IDENTITY note). Drop and damage
-- replace that entry transactionally and update both references together;
-- merge consumes it.
export type CarryState = {
	live: LiveBase,
	part: BasePart,
	entry: MergeObjectEntry,
	weld: WeldConstraint,
}

-- Recorded once by applyLaunchScale so restoreLaunchScale can put a scaled
-- launch's cosmetic children back exactly as MergeObjectVisuals.attach and
-- materializeObject originally left them, regardless of what a squash
-- animation was doing to these same values when the launch ended.
export type LaunchVisualScale = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
	transparency: number,
}

export type LaunchScale = {
	rootSize: Vector3,
	rootTransparency: number,
	visuals: { LaunchVisualScale },
	incomeLabel: BillboardGui?,
	incomeLabelOffset: Vector3?,
	incomeLabelEnabled: boolean?,
}

export type LaunchState = {
	live: LiveBase,
	-- The real owned squishy remains welded to the player's character for the
	-- whole launch. `part` below is only the temporary projectile clone.
	sourcePart: BasePart,
	part: BasePart,
	entry: MergeObjectEntry,
	-- Resolved from the owner's persisted SquishyBeamId when the launch is
	-- accepted. Holding the exact template keeps a mid-launch equip change
	-- from swapping artwork between the spawn squash and descent.
	beamTemplate: Model?,
	-- Attached at the top of the fall, not at the drop teleport -- so nil for
	-- the spawn-squish phase of every launch. See attachLaunchBeams.
	beams: LaunchBeamRuntime.Handle?,
	-- Set once by applyLaunchScale, right after the drop teleport; nil only in
	-- the brief window before that runs. See restoreLaunchScale.
	scale: LaunchScale?,
	-- Resolved once by launchCarried (this tier's LaunchSize override, or the
	-- MergeConfig default) and read by everything that has to agree on how big
	-- this projectile is: the landing-height solve, applyLaunchScale, and the
	-- beam anchor. Resolving it per launch rather than per call keeps those
	-- three consistent even if the artwork's attribute is edited mid-flight.
	sizeMultiplier: number,
	-- Set at the exact descent frame where an active dome intercepts this
	-- projectile. Damage immunity follows this physical collision rather than
	-- merely checking whether a shield happens to be active later.
	blockedByForcefield: Player?,
}

export type MushBoostState = {
	humanoid: Humanoid,
	originalWalkSpeed: number,
}

local Types = {}

--[[
	Clamps `tier` into [1, MAX_TIER] and floors it, defaulting to 1 for
	anything that isn't a real number (NaN included -- every comparison
	against NaN is false, so it must be caught before the clamp, same trap
	Progression.sanitizeLevel guards against). Profile data for this field is
	only ever written by trySpawnObject below today, but the dev console can
	still plant a bad value directly, and a corrupted Tier must not propagate
	into an out-of-bounds MergeConfig.Tiers lookup.
]]
function Types.sanitizeTier(tier: number): number
	if type(tier) ~= "number" or tier ~= tier then
		return 1
	end
	return math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
end

function Types.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Types.sanitizeHealth(health: number, tier: number, healthMultiplier: any?): number
	local maxHealth = MergeConfig.maxHealthForTier(tier, healthMultiplier)
	if type(health) ~= "number" or health ~= health or health == math.huge or health == -math.huge then
		return maxHealth
	end
	return math.clamp(health, 0, maxHealth)
end

function Types.tierDefFor(tier: number): MergeConfig.TierDef
	return MergeConfig.Tiers[Types.sanitizeTier(tier)]
end

function Types.clearCarryingAttributes(player: Player)
	player:SetAttribute("CarryingTier", nil)
	player:SetAttribute("CarryingLaunchReadyAt", nil)
end

return Types
