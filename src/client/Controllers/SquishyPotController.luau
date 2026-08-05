--!strict
--[[
	Swells resting squishies in proportion to their squeeze pot, so a loaded one
	is readable from across the pad with no UI at all -- and deflates them again
	as Mush drains the pot.

	DERIVED LOCALLY, NEVER REPLICATED. The server publishes only the two raw pot
	fields as Part attributes (Spawning.publishPot), and those change solely when
	the pot is written: mush, merge, drop, pickup/drop-or-cancel (the carry
	freeze/resume). This controller turns them into a live scale on its own.
	Replicating the scale itself would be one write per squishy per second,
	which is the exact cost the pot's timestamp design exists to avoid -- see
	Types.MergeObjectEntry's Pot field.

	VISUAL ONLY. Only the Visual children's welds and sizes move; the MergeObject
	root keeps its authored size, because pad packing, drop placement, and merge
	detection all measure the root. MushController's squash follows the same rule
	for the same reason.

	Ownership of those welds is shared with MushController's squash, but the
	two COMPOSE rather than take turns: this controller keeps `state.applied`
	current every Heartbeat regardless of whether a squash is running, and
	publishes it through PotScale for MushController to read live. Only the
	final WRITE to the welds is suspended while "Squashing" is set, because
	MushController owns that write for the duration -- it reads the same
	published value and folds it into its own squash math every frame (see
	MushController's composeWeld), so the swell keeps visibly deflating
	through a mash instead of freezing until the squash lets go.

	TARGET/APPLIED SPLIT. `state.target` is the raw scale potScaleFor computes
	right now; `state.applied` is what the welds show (or would show, while
	Squashing defers the write -- see above). A drain click moves the target
	hard and instantly (the pot itself just dropped), but applied EASES toward
	it a little every Heartbeat instead of snapping, which is what turns a
	drain click from a pop into a gradual deflate. Recomputing the target stays
	on the throttled interval below (cheap: attribute reads and arithmetic);
	easing runs every Heartbeat regardless (also cheap: it only touches roots
	whose applied/target actually differ) so the motion itself stays smooth
	independent of how coarse the target recompute is.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local PotScale = require(script.Parent.PotScale)

local log = Log.new("SquishyPotController")

local player = Players.LocalPlayer

-- How often `state.target` is recomputed from the pot attributes. The pot
-- takes MUSH_POT_CAP_PULSES seconds to fill, so there is nothing to gain from
-- reading attributes and recomputing every frame -- this is still far coarser
-- than the swell itself moves. The actual visual motion is eased every
-- Heartbeat regardless of this interval; see easeToTargets.
local UPDATE_INTERVAL = 0.15
-- Skip a rewrite when applied has closed to within this of target. In the
-- steady state (a full pot, or an empty one, and nothing draining) this makes
-- the easing pass a handful of comparisons.
local APPLY_EPSILON = 0.004
-- Exponential approach rate for applied -> target, in closed-fraction-per-
-- second: see easeToTargets. At this rate a hard target jump (a drain click)
-- is about 89% closed after one second and effectively settled (within
-- APPLY_EPSILON) within a few seconds -- "as gradual as possible" without
-- reading as sluggish on a six-click drain happening within that same window.
local POT_EASE_RATE = 2.2
-- How long before the wall-clock anchor below is refreshed.
local CLOCK_RESYNC = 30

type VisualState = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
}

type RootState = {
	visuals: { VisualState },
	anchor: Vector3,
	-- What the welds currently show.
	applied: number,
	-- What potScaleFor says right now -- may be well ahead of `applied` for as
	-- long as it takes easeToTargets to close the gap.
	target: number,
}

local SquishyPotController = {}

local roots: { [BasePart]: RootState } = {}
local accumulator = 0
local timeAnchor = 0
local clockAnchor = 0

--[[
	PotSince is an os.time() stamp, but os.time() only ticks once a second --
	reading it directly would make the swell visibly step about sixty times on
	its way up. Anchor it once and advance with os.clock() for a smooth
	sub-second value, re-anchoring periodically so it cannot drift.
]]
local function wallClockNow(): number
	local clock = os.clock()
	if timeAnchor == 0 or clock - clockAnchor > CLOCK_RESYNC then
		timeAnchor = os.time()
		clockAnchor = clock
	end
	return timeAnchor + (clock - clockAnchor)
end

local function findObjectsFolder(): Folder?
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return nil
	end

	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local bases = if mapLayout ~= nil then mapLayout:FindFirstChild("Bases") else nil
	local base = if bases ~= nil then bases:FindFirstChild(baseName) else nil
	local folder = if base ~= nil then base:FindFirstChild("MergeObjects") else nil
	return if folder ~= nil and folder:IsA("Folder") then folder :: Folder else nil
end

--[[
	Records each visual piece's authored size and weld offset, which every later
	scale is computed from. Captured on first sight, while the model is still at
	its authored scale -- the only other writer of these welds is MushController's
	squash, which reads the live PotScale published below rather than a frozen
	copy of these fields (see applyScale's header).

	Returns nil when the artwork has not been welded on yet, so the caller simply
	retries on the next pass rather than caching a half-built model.
]]
local function captureRoot(root: BasePart): RootState?
	local visual = root:FindFirstChild("Visual")
	if visual == nil then
		return nil
	end

	local candidates = if visual:IsA("BasePart") then { visual } else visual:GetDescendants()
	local visuals: { VisualState } = {}
	for _, candidate in candidates do
		if not candidate:IsA("BasePart") then
			continue
		end
		local weld = candidate:FindFirstChild("VisualWeld")
		if weld ~= nil and weld:IsA("Weld") then
			table.insert(visuals, {
				part = candidate,
				weld = weld,
				size = candidate.Size,
				c0 = weld.C0,
			})
		end
	end

	if #visuals == 0 then
		return nil
	end

	return {
		visuals = visuals,
		-- Grow upward from the pad rather than about the centre, so a swollen
		-- squishy never sinks half of itself through the base it sits on.
		anchor = Vector3.new(0, -root.Size.Y / 2, 0),
		-- Seeded properly by the caller (recomputeTargets) right after capture,
		-- from the pot attributes already on the part -- these placeholders are
		-- never left live. Easing must apply only to CHANGES after capture, not
		-- to a squishy inflating from nothing the instant it's first seen.
		applied = 1,
		target = 1,
	}
end

--[[
	Advances `state.applied` and publishes it unconditionally -- MushController
	reads the published value every frame a squash is running, so this must
	stay current even while the weld write below is deferred, or the squash's
	own composition would be reading a stale number.

	The weld write itself is skipped while Squashing is set: MushController
	owns those welds for the duration and performs the equivalent write
	itself, folding this same published scale into its squash math (see its
	composeWeld). Writing here too would have both controllers touching the
	same C0/Size in the same frame with no ordering guarantee between them.
]]
local function applyScale(root: BasePart, state: RootState, scale: number)
	state.applied = scale
	PotScale.set(root, scale)

	if root:GetAttribute("Squashing") == true then
		return
	end

	for _, visual in state.visuals do
		if visual.part.Parent == nil or visual.weld.Parent == nil then
			continue
		end
		visual.part.Size = visual.size * scale
		local position = state.anchor + (visual.c0.Position - state.anchor) * scale
		visual.weld.C0 = CFrame.new(position) * visual.c0.Rotation
	end
end

--[[
	Recomputes `state.target` for every live squishy on the pad, on the
	throttled UPDATE_INTERVAL cadence -- see its header note. Never writes a
	weld itself; easeToTargets (via applyScale) is the only thing that does
	that, every frame, which is what makes the drain gradual regardless of how
	coarsely target moves.

	A brand-new root is still skipped entirely while Squashing is set: captureRoot
	reads the CURRENT Size/C0 off the part as the resting baseline, and
	mid-squash geometry is not a resting baseline. An ALREADY-captured root
	keeps its target (and, via easeToTargets, its applied/PotScale) current
	even while squashed, so MushController's composeWeld has a live number to
	read for the whole session instead of a stale one from before the mash
	started.
]]
local function recomputeTargets()
	local folder = findObjectsFolder()
	if folder == nil then
		return
	end

	local now = wallClockNow()
	for _, child in folder:GetChildren() do
		if not child:IsA("BasePart") or child.Name ~= "MergeObject" then
			continue
		end

		local tier = child:GetAttribute("Tier")
		if type(tier) ~= "number" then
			continue
		end

		local state = roots[child]
		local justCaptured = false
		if state == nil then
			-- MushController owns these welds while squashing -- see the header.
			if child:GetAttribute("Squashing") == true then
				continue
			end
			state = captureRoot(child)
			if state == nil then
				continue
			end
			roots[child] = state
			justCaptured = true
		end

		local pot = MergeConfig.potFor(child:GetAttribute("PotBanked"), child:GetAttribute("PotSince"), tier, now)
		state.target = MergeConfig.potScaleFor(pot, tier)
		if justCaptured then
			-- Seed rather than ease: this root's real pot scale is already
			-- known on the very pass it was captured, so applying it directly
			-- here (instead of leaving `applied` at captureRoot's 1x
			-- placeholder for easeToTargets to close over the next second or
			-- so) means a squishy already loaded when first seen -- on join,
			-- after a pad rebuild, or a merge result that inherited both
			-- parents' pots -- renders at its correct size immediately rather
			-- than visibly inflating from nothing.
			applyScale(child, state, state.target)
		end
	end
end

--[[
	Runs every Heartbeat, independent of the throttled recompute above: eases
	each known root's `applied` a fraction of the remaining gap to `target`,
	frame-rate independent via the standard exponential-decay form (1 -
	e^(-rate*dt)) so the motion looks the same at 30fps or 144fps and never
	overshoots even after a lag spike hands it a large `deltaTime`.

	Runs (and publishes to PotScale) even while Squashing is set -- only
	applyScale's actual weld write is deferred for that window, not the easing
	itself. See applyScale's header for why that's what lets the two
	controllers compose instead of fight.
]]
local function easeToTargets(deltaTime: number)
	-- Stale roots are collected then removed after the loop, not inside it --
	-- the same "don't mutate a table's KEYS while traversing it" convention
	-- Carry.reArmSweep documents (Carry.luau's toRearm pattern). Updating an
	-- EXISTING key's value (applied, via applyScale below) is fine and done
	-- directly.
	local stale: { BasePart } = {}
	for root, state in roots do
		if root.Parent == nil then
			-- Squishies are destroyed on merge, launch, and death, and the pad is
			-- torn down entirely on leave. Drop the capture rather than holding
			-- the last reference to every Part the player has ever owned this
			-- session.
			table.insert(stale, root)
			continue
		end
		if math.abs(state.target - state.applied) < APPLY_EPSILON then
			continue
		end

		local alpha = 1 - math.exp(-POT_EASE_RATE * deltaTime)
		applyScale(root, state, state.applied + (state.target - state.applied) * alpha)
	end

	for _, root in stale do
		roots[root] = nil
		PotScale.clear(root)
	end
end

function SquishyPotController.Init() end

function SquishyPotController.Start()
	RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulator += deltaTime
		if accumulator >= UPDATE_INTERVAL then
			accumulator = 0
			recomputeTargets()
		end
		easeToTargets(deltaTime)
	end)

	log.info("ready (pot swell on resting squishies)")
end

return SquishyPotController
