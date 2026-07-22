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

-- Phase 2: carry + ram-to-merge tuning.
-- Gap between a carried object's near surface and the character's torso, so
-- a large tier's cube doesn't clip into the character model.
MergeConfig.CARRY_GAP = 1.5
-- Extra slack beyond the sum of both objects' half-sizes before a ram counts
-- as a merge -- exact-contact-only would feel unresponsive given the carried
-- part only updates position once per Heartbeat.
MergeConfig.MERGE_EPSILON = 0.75
-- How far (horizontal, matching this module's 2D pad model) the owning
-- player's character must move away from a just-dropped/just-merged/
-- just-cancelled part before it re-arms for pickup. Without this a part
-- placed at or right beside the player's own feet gets instantly re-grabbed,
-- and the player can never actually put anything down. Deliberately a
-- distance, not a timer: walking away and back gets it re-armed exactly
-- when that feels earned, not on an arbitrary clock.
MergeConfig.REARM_CLEARANCE = 3
-- How long the owner must stay CONTINUOUSLY outside REARM_CLEARANCE before a
-- part re-arms. A pure instant-outside check fires too early for a merge
-- result specifically: at the moment commitMerge runs, the ramming player's
-- root is already past halfSize + CARRY_GAP (the carry offset) plus
-- 2*halfSize + MERGE_EPSILON (the merge threshold) from the result's
-- position -- comfortably outside REARM_CLEARANCE on the very first
-- Heartbeat -- and their own ramming momentum then carries them forward
-- back over the part it just re-armed. At walkspeed 16 a player crosses the
-- ~0.75-stud MERGE_EPSILON gap into the radius within a couple of frames, so
-- any momentum overrun resets the accumulator before it matters; a player
-- genuinely walking away clears this window imperceptibly.
MergeConfig.REARM_OUTSIDE_SECONDS = 0.5

-- Phase 3: passive income. Every owned object earns BASE_INCOME * 2^(tier-1)
-- per pulse -- $1 at tier 1, doubling each tier up to $512 at MAX_TIER (10).
-- The doubling is deliberate (spec): a merge visibly doubles that object's
-- earning rate, which is the whole point of merging rather than just hoarding.
MergeConfig.INCOME_INTERVAL = 1 -- seconds between income pulses
MergeConfig.BASE_INCOME = 1 -- $ per pulse at tier 1
-- Offline income uses the exact same per-tier pulse as live income, capped so
-- a long absence cannot destabilize the economy. Change this one value to
-- tune the maximum banked duration.
MergeConfig.MAX_OFFLINE_SECONDS = 8 * 60 * 60
-- Persist a recent server timestamp while the player is online. This bounds
-- duplicate income after an unclean session handoff without adding a write
-- to every one-second income pulse.
MergeConfig.ACTIVITY_CHECKPOINT_INTERVAL = 60

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

--[[
	The one place tier -> income is computed, so the server billboard (Phase
	3's income tick) and the client's floating popups can never disagree on
	what a given tier is worth -- both call this instead of each doing its
	own math.

	Guards its input the same way MergeService.sanitizeTier does (NaN
	included -- every comparison against NaN is false, so it must be caught
	before the clamp): callers on the client read this straight off a Part's
	Tier attribute, which is `any` from Luau's perspective and not something
	this module can assume was validated upstream.
]]
function MergeConfig.incomeForTier(tier: number): number
	local safeTier = tier
	if type(safeTier) ~= "number" or safeTier ~= safeTier then
		safeTier = 1
	end
	safeTier = math.clamp(math.floor(safeTier), 1, MergeConfig.MAX_TIER)

	return MergeConfig.BASE_INCOME * (2 ^ (safeTier - 1))
end

return MergeConfig
