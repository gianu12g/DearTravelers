--!strict
--[[
	Data for the merge-gameplay loop: tier definitions and placement tuning.

	Shared, not server-only: MergeService is the only reader today, but the
	tier ramp (Color/Size/Name) is exactly what a later phase's client-side
	drag-and-drop UI needs to render objects and preview a merge result before
	the server confirms it -- the same both-sides argument Progression.luau
	makes for the XP curve (ARCHITECTURE.md:12). Keeping it here now means
	Phase 2 doesn't have to move it.

	A plain module -- the name ends in neither Service nor Controller, so the
	Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.
]]

export type TierDef = {
	Name: string,
	Color: Color3,
	-- Cube edge length in studs.
	Size: number,
}

local MergeConfig = {}

MergeConfig.MAX_OBJECTS = 25
MergeConfig.SPAWN_INTERVAL = 5 -- seconds between auto-spawn attempts, per pad
MergeConfig.MAX_TIER = 10

-- Placement (free placement, no grid -- see the Phase 1 spec).
-- Kept clear of the pad's edge so a tier-10 cube (9 studs) never visually
-- overhangs the SpawnArea part.
MergeConfig.PAD_MARGIN = 2
-- Minimum gap between two objects' SURFACES, not their centers -- summed
-- with both objects' half-sizes at the call site to get a center-to-center
-- minimum distance. Keeps freely-placed cubes from visually touching/
-- z-fighting even when rejection sampling places them as close as allowed.
MergeConfig.MIN_GAP = 1
-- Rejection-sampling attempts per auto-spawn tick before giving up and
-- waiting for the next tick -- a crowded-but-under-cap pad just waits
-- rather than spinning or forcing an overlapping placement.
MergeConfig.MAX_PLACEMENT_ATTEMPTS = 20

--[[
	10 tiers, gray -> near-white. Size grows per tier; tier 10 stays at 9
	studs so it never exceeds the pad inset (35 - PAD_MARGIN on a 70-stud
	SpawnArea). Adding tier 11 later is one entry -- nothing else in this
	module or MergeService indexes tiers by a hardcoded count other than
	MAX_TIER above.
]]
MergeConfig.Tiers = {
	{ Name = "Pebble", Color = Color3.fromRGB(150, 150, 150), Size = 2.0 },
	{ Name = "Bark Chunk", Color = Color3.fromRGB(139, 90, 43), Size = 2.8 },
	{ Name = "Mossy Bud", Color = Color3.fromRGB(76, 175, 80), Size = 3.6 },
	{ Name = "Azure Shard", Color = Color3.fromRGB(33, 150, 243), Size = 4.4 },
	{ Name = "Violet Core", Color = Color3.fromRGB(156, 39, 176), Size = 5.2 },
	{ Name = "Ember Cell", Color = Color3.fromRGB(211, 47, 47), Size = 6.0 },
	{ Name = "Sunforged Ingot", Color = Color3.fromRGB(255, 112, 0), Size = 6.7 },
	{ Name = "Golden Relic", Color = Color3.fromRGB(255, 193, 7), Size = 7.4 },
	{ Name = "Aurora Crystal", Color = Color3.fromRGB(0, 229, 255), Size = 8.2 },
	{ Name = "Radiant Prism", Color = Color3.fromRGB(245, 245, 255), Size = 9.0 },
} :: { TierDef }

return MergeConfig
