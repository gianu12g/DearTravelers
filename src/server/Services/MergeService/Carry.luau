--!strict
--[[
	Phase 2 carry/merge/drop, the re-arm sweep, and the Mush speed boost. See
	the MergeService init.luau header's PHASE 2, DISARM/RE-ARM, and Mush notes
	for the surrounding design; Launch.luau is the other half of Phase 2 (the
	projectile side).

	`liveBases`, `carries`, and `activeLaunches` are owned by init.luau and
	handed to this module once via Carry.setup() -- see Spawning.luau's own
	note on the same pattern. `mushBoosts` and `maxLevelNotifiedCarry` are this
	module's own state: nothing outside Carry needs either.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local CoinsService = require(script.Parent.Parent.CoinsService)
local DataService = require(script.Parent.Parent.DataService)
local Launch = require(script.Parent.Launch)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local Net = require(ReplicatedStorage.Shared.Net)
local QuestsService = require(script.Parent.Parent.UISystem.QuestsService)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local Spawning = require(script.Parent.Spawning)
local Types = require(script.Parent.Types)
local UINotificationService = require(script.Parent.Parent.UISystem.UINotificationService)
local Vfx = require(script.Parent.Vfx)

local log = Log.new("MergeService")

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
	carries: { [Player]: Types.CarryState },
	activeLaunches: { [Player]: Types.LaunchState },
}

-- Set once by Carry.setup(), called from init.Init(). See Spawning.luau's
-- own header note on why these are references to init-owned tables.
local liveBases: { [Player]: Types.LiveBase } = nil :: any
local carries: { [Player]: Types.CarryState } = nil :: any
local activeLaunches: { [Player]: Types.LaunchState } = nil :: any

local mushBoosts: { [Player]: Types.MushBoostState } = {}
-- The same carried object can overlap a target for many Heartbeats. Remember
-- the exact CarryState already notified so one continuous push produces one
-- toast; dropping and picking up again creates a new CarryState and therefore
-- a new, legitimate attempt.
local maxLevelNotifiedCarry: { [Player]: Types.CarryState } = {}

--[[
	Last os.clock() at which this player's mush was accepted. This -- not the
	WalkSpeed boost -- is what rate-limits mushing now.

	The two used to be the same timer: activateMush refused while a boost was
	running, so the boost duration doubled as the cooldown. That cannot work
	once a loaded squishy drains over several clicks, because a multi-click
	drain at a multi-second cooldown is just standing still. They are now
	independent: payout clicks are bounded by MUSH_DRAIN_DEBOUNCE (about human
	mash speed, and a real server-side request bound), while the boost refreshes
	on its own duration below.
]]
local mushDebounce: { [Player]: number } = {}

--[[
	The drain currently in progress for this player: how many clicks it was
	planned to take, how much each one pays, and how far in they are.

	The plan is fixed WHEN THE DRAIN STARTS and then followed to the end. It
	cannot be re-derived per click from the remaining pot: drainClicksForPot is
	logarithmic, so a pot that keeps shrinking keeps asking for nearly as many
	clicks as it did when full, and a capped pot takes fourteen clicks to empty
	instead of the six it was supposed to. Fixing the plan up front is what
	makes "a full squishy is exactly MUSH_MAX_DRAIN_CLICKS clicks" true.

	Keyed to the exact CarryState, not just the player: picking up a different
	squishy is a different drain and must re-plan from that squishy's own pot.
]]
type DrainPlan = {
	carry: Types.CarryState,
	step: number,
	totalSteps: number,
	perClick: number,
}

local drainProgress: { [Player]: DrainPlan } = {}

local MUSH_BOOST_AMOUNT = 5
-- Short enough that continuous squeezing keeps you fast but it lapses shortly
-- after you stop. A long duration paired with the fast debounce above would
-- make the boost permanently on for anyone holding a squishy.
local MUSH_BOOST_DURATION = 2

local Carry = {}

function Carry.setup(deps: Deps)
	liveBases = deps.liveBases
	carries = deps.carries
	activeLaunches = deps.activeLaunches
end

-- Called from onPlayerRemoving: forgets this player's max-level notification
-- latch entirely so the table does not carry a stale entry for a Player
-- instance that will never rejoin.
function Carry.clearPlayer(player: Player)
	mushDebounce[player] = nil
	drainProgress[player] = nil
	maxLevelNotifiedCarry[player] = nil
end

--[[
	Ends a carry without a merge or a deliberate drop: character removing
	(death/respawn/leaving) or the pad going away underneath the player. The
	entry's X/Z never changed while carried (see the init.luau header's PHASE 2
	note), so this needs no DataService write -- putting the SAME part back
	where it already persists is enough.

	Safe to call when nothing is being carried (every caller does, rather
	than checking first) and safe to call right before the pad's whole
	objectsFolder gets destroyed a moment later -- Spawning.reAnchorPart's own
	Parent-nil guard covers that.
]]
function Carry.cancelCarry(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	carries[player] = nil
	Types.clearCarryingAttributes(player)

	carry.weld:Destroy()
	Spawning.reAnchorPart(carry.live, carry.part, carry.entry)
	-- The respawned player can land right on top of this spot (base center)
	-- -- see MergeConfig.REARM_CLEARANCE's comment.
	Spawning.markDisarmed(carry.live, carry.part)
end

--[[
	Commits a ram-to-merge: `carry` (tier t, still attached to the player)
	touched `targetPart`/`targetEntry` (also tier t, resting on the same
	pad). Rebuilds Squishies removing BOTH entries and appending one {t+1,
	targetEntry.X, targetEntry.Z} in a single DataService.set -- no yields
	between the read and the write (quality-gate.md trap #5), so this cannot
	race a second commit for the same player (there is only ever one
	Heartbeat loop, and carries[player] is cleared before this returns).
]]
local function commitMerge(
	player: Player,
	carry: Types.CarryState,
	targetPart: BasePart,
	targetEntry: Types.MergeObjectEntry
)
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but a merge must not vanish the carried
		-- object into thin air if it somehow happens -- leave everything as
		-- it is and let the next Heartbeat tick try again.
		return
	end

	local mergedTier = carry.entry.Tier + 1
	--[[
		Both pots come along. Merging is the one place two squishies become one,
		and quietly eating their banked money would punish the exact action the
		whole game is built around.

		Summed as DERIVED values rather than raw Pot fields, so whatever accrued
		since each one's last write is included rather than lost.

		The clamp is almost never reached and that is by construction: income
		doubles per tier, so two full pots at tier N sum to exactly the cap at
		tier N+1. A player who fills two squishies and merges them keeps the
		whole thing.
	]]
	local nowSeconds = os.time()
	local mergedPot = MergeConfig.potFor(carry.entry.Pot, carry.entry.PotSince, carry.entry.Tier, nowSeconds)
		+ MergeConfig.potFor(targetEntry.Pot, targetEntry.PotSince, targetEntry.Tier, nowSeconds)

	local newEntry: Types.MergeObjectEntry = {
		Tier = mergedTier,
		X = targetEntry.X,
		Z = targetEntry.Z,
		Health = MergeConfig.maxHealthForTier(mergedTier, data.Merge.SquishyHealthMultiplier),
		Pot = math.min(mergedPot, MergeConfig.potCapForTier(mergedTier)),
		PotSince = nowSeconds,
	}

	local updated = table.create(#data.Merge.Squishies)
	for _, existingEntry in data.Merge.Squishies do
		if existingEntry ~= carry.entry and existingEntry ~= targetEntry then
			table.insert(updated, existingEntry)
		end
	end
	table.insert(updated, newEntry)
	DataService.set(player, { "Merge", "Squishies" }, updated)

	-- Captured before Destroy: the VFX plays at the mergee's position, and
	-- reading .Position after Destroy is not something to rely on.
	local vfxPosition = targetPart.Position
	local serverNow = Workspace:GetServerTimeNow()
	local carryReadyAt = carry.part:GetAttribute("LaunchReadyAt")
	local targetReadyAt = targetPart:GetAttribute("LaunchReadyAt")
	local restartLaunchCooldown = (typeof(carryReadyAt) == "number" and carryReadyAt > serverNow)
		or (typeof(targetReadyAt) == "number" and targetReadyAt > serverNow)

	carries[player] = nil
	Types.clearCarryingAttributes(player)
	carry.weld:Destroy()

	live.parts[carry.part] = nil
	live.parts[targetPart] = nil
	-- Cleared rather than left to dangle: carry.part is never disarmed while
	-- actively carried, but targetPart (a resting object) could have been
	-- rammed while still disarmed itself -- merges don't check armed state,
	-- only pickup does. Either way, both are about to be destroyed, and a
	-- stale key pointing at a destroyed Part is exactly the leak the
	-- LiveBase.disarmed comment promises not to have.
	live.disarmed[carry.part] = nil
	live.disarmed[targetPart] = nil
	carry.part:Destroy()
	targetPart:Destroy()

	-- Quest metric. Counted here, after the transaction has committed, so a
	-- merge that bailed out above never credits progress. Yield-free, like the
	-- rest of this function.
	QuestsService.award(player, "Merges", 1)

	Vfx.spawnMergeVfx(live.objectsFolder, vfxPosition)
	Vfx.sendMergeSquishyVfx(player, vfxPosition)
	-- The result appears wherever the target sat -- which the carrying
	-- player was, by definition, standing right next to. Same instant-
	-- re-grab problem as a drop, same fix.
	local newPart = Spawning.spawnRestingPart(player, live, newEntry)
	Spawning.markDisarmed(live, newPart)
	if restartLaunchCooldown then
		Launch.startCooldown(player, newPart)
	end
end

--[[
	One carrying player's merge check for this Heartbeat tick. See the
	init.luau header's PHASE 2 note for why this is distance polling and not
	Touched.
]]
local function tryMergeCarry(player: Player, carry: Types.CarryState)
	local entry = carry.entry
	local data = DataService.getData(player)
	local rebirths = if data ~= nil then RebirthConfig.sanitizeRebirths(data.Rebirths) else 0
	local maxModelLevel = RebirthConfig.maxModelLevel(rebirths)
	local mergeLocked = entry.Tier >= maxModelLevel

	local halfSize = Types.tierDefFor(entry.Tier).Size / 2
	local threshold = halfSize + halfSize + MergeConfig.MERGE_EPSILON -- same tier -> same size
	local carryPosition = carry.part.Position

	-- Horizontal-only, matching findOpenSpot/computeDropSpot's 2D model of
	-- the pad: the carried part floats at torso height, well above a resting
	-- object's center, so 3D distance would let that vertical gap eat most
	-- of the threshold -- worst for small tiers, whose whole size is close
	-- to the gap itself.
	local target: BasePart? = nil
	local targetEntry: Types.MergeObjectEntry? = nil
	local activeLaunch = activeLaunches[player]
	for otherPart, otherEntry in carry.live.parts do
		if
			otherPart == carry.part
			or (activeLaunch ~= nil and otherPart == activeLaunch.part)
			or otherPart:GetAttribute("AutoMerging") == true
			or otherEntry.Tier ~= entry.Tier
		then
			continue
		end

		local dx = carryPosition.X - otherPart.Position.X
		local dz = carryPosition.Z - otherPart.Position.Z
		if dx * dx + dz * dz <= threshold * threshold then
			target = otherPart
			targetEntry = otherEntry
			break
		end
	end

	-- Committed AFTER the loop closes, not inside it: commitMerge's
	-- spawnRestingPart inserts a NEW key into this same live.parts table
	-- (the merge result), and mutating a table while a `for...in` is still
	-- traversing it is undefined behaviour in Luau.
	if target ~= nil and targetEntry ~= nil then
		if mergeLocked then
			if maxLevelNotifiedCarry[player] ~= carry then
				maxLevelNotifiedCarry[player] = carry
				local message = if rebirths >= RebirthConfig.MAX_REBIRTHS
					then RebirthConfig.MAX_TIER_MESSAGE
					else RebirthConfig.REQUIRES_REBIRTH_MESSAGE
				UINotificationService.SendNotification(player, "Error", message)
			end
			return
		end

		commitMerge(player, carry, target, targetEntry)
	end
end

function Carry.checkAllCarriesForMerge()
	for player, carry in carries do
		tryMergeCarry(player, carry)
	end
end

--[[
	Re-arms disarmed parts once the OWNING player's character has stood
	CONTINUOUSLY outside REARM_CLEARANCE (horizontal, same 2D model as
	everywhere else in this module) for REARM_OUTSIDE_SECONDS. See
	LiveBase.disarmed and MergeConfig.REARM_OUTSIDE_SECONDS's comment for why
	an instant-outside check is not enough: a merge result's own ramming
	momentum satisfies "instantly outside" on the very next Heartbeat,
	before the player has actually moved away, and carries them straight
	back over it.

	`dt` is threaded through from the shared Heartbeat connection in
	init.Start() rather than read from RunService here, keeping this a pure
	function of its arguments like the rest of this module's Heartbeat-driven
	code.

	`liveBases` is bounded by the server's discovered base count, so iterating all of it every
	Heartbeat is cheap on its own; the `next(live.disarmed) == nil` check
	skips the character lookup and inner scan entirely for the (usual) case
	of a pad with nothing disarmed on it right now.
]]
function Carry.reArmSweep(dt: number)
	for player, live in liveBases do
		if next(live.disarmed) == nil then
			continue
		end

		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil

		if root == nil or not root:IsA("BasePart") then
			-- No character to measure from (dead/respawning): every
			-- accumulator resets and every part stays disarmed -- the spawn
			-- point can land the respawned player right back on top of one.
			-- Only VALUES change here, no keys added or removed, so mutating
			-- mid-traversal is fine (unlike the insert/remove below).
			for part, _ in live.disarmed do
				live.disarmed[part] = 0
			end
			continue
		end
		local rootPosition = root.Position

		-- Removals collected then applied after the loop, not inside it --
		-- the same "don't mutate a table's KEYS while traversing it" rule
		-- tryMergeCarry's own restructure above exists for. Updating an
		-- EXISTING key's value mid-traversal (the accumulator) is fine and
		-- done directly below.
		local toRearm: { BasePart } = {}
		for part, outsideSeconds in live.disarmed do
			if part.Parent == nil then
				table.insert(toRearm, part) -- destroyed elsewhere; stop tracking it
				continue
			end

			local entry = live.parts[part]
			local halfSize = if entry ~= nil then Types.tierDefFor(entry.Tier).Size / 2 else 0
			local clearance = halfSize + MergeConfig.REARM_CLEARANCE

			local dx = rootPosition.X - part.Position.X
			local dz = rootPosition.Z - part.Position.Z
			if dx * dx + dz * dz > clearance * clearance then
				local accumulated = outsideSeconds + dt
				if accumulated >= MergeConfig.REARM_OUTSIDE_SECONDS then
					table.insert(toRearm, part)
				else
					live.disarmed[part] = accumulated
				end
			else
				live.disarmed[part] = 0 -- back inside -- momentum overrun, reset the window
			end
		end

		for _, part in toRearm do
			live.disarmed[part] = nil
		end
	end
end

--[[
	Where a dropped object should land: the character's CURRENT world
	position projected into the pad's local space (never a client-sent
	coordinate -- see Net.luau's mergeDropRequest comment), clamped to the
	same PAD_MARGIN inset auto-spawn uses. Falls back to the object's own
	prior spot if there is no character to read a position from, or if the
	pad is too crowded for findOpenSpot to find anything at all.
]]
local function computeDropSpot(live: Types.LiveBase, carry: Types.CarryState, character: Model?): (number, number)
	local tierDef = Types.tierDefFor(carry.entry.Tier)
	local halfSize = tierDef.Size / 2
	local rangeX = live.spawnArea.Size.X / 2 - MergeConfig.PAD_MARGIN - halfSize
	local rangeZ = live.spawnArea.Size.Z / 2 - MergeConfig.PAD_MARGIN - halfSize

	local wantX, wantZ = carry.entry.X, carry.entry.Z
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") and rangeX > 0 and rangeZ > 0 then
		local localPosition = live.spawnArea.CFrame:PointToObjectSpace(root.Position)
		wantX = math.clamp(localPosition.X, -rangeX, rangeX)
		wantZ = math.clamp(localPosition.Z, -rangeZ, rangeZ)
	end

	local fits = true
	for _, otherEntry in live.parts do
		if otherEntry == carry.entry then
			continue
		end
		local otherHalf = Types.tierDefFor(otherEntry.Tier).Size / 2
		local minDistance = halfSize + otherHalf + MergeConfig.MIN_GAP
		local dx = wantX - otherEntry.X
		local dz = wantZ - otherEntry.Z
		if dx * dx + dz * dz < minDistance * minDistance then
			fits = false
			break
		end
	end
	if fits then
		return wantX, wantZ
	end

	local x, z = Spawning.findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x ~= nil and z ~= nil then
		return x, z
	end

	-- Pad fully crowded -- put it back where it started rather than losing it.
	return carry.entry.X, carry.entry.Z
end

--[[
	Handles Net.mergeDropRequest. A no-op if the sender isn't carrying
	anything, which covers a stale/duplicate/malicious send with zero work
	beyond the table lookup.
]]
function Carry.dropCarried(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but never strand the object mid-air --
		-- put it back exactly where it already persists and stop.
		Carry.cancelCarry(player)
		return
	end

	local x, z = computeDropSpot(live, carry, player.Character)
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100
	local newEntry: Types.MergeObjectEntry = {
		Tier = carry.entry.Tier,
		X = roundedX,
		Z = roundedZ,
		Health = carry.entry.Health,
		-- Dropping is not collecting: a partially drained squishy keeps whatever
		-- is left, so walking away mid-drain never destroys banked money.
		Pot = carry.entry.Pot,
		PotSince = carry.entry.PotSince,
	}

	-- Splice the fresh entry in place of the old one rather than mutating
	-- carry.entry's fields directly -- ARCHITECTURE.md's "never touch
	-- profile.Data directly" rule applies even though carry.entry IS a
	-- profile.Data table (see the header's IDENTITY note); only a
	-- DataService.set call may change what a client sees.
	local entryIndex = table.find(data.Merge.Squishies, carry.entry)
	if entryIndex == nil then
		log.warn(`carried squishy disappeared from {player.Name}'s profile -- drop cancelled`)
		Carry.cancelCarry(player)
		return
	end
	DataService.set(player, { "Merge", "Squishies", entryIndex }, newEntry)

	carries[player] = nil
	Types.clearCarryingAttributes(player)
	carry.weld:Destroy()

	live.parts[carry.part] = newEntry
	Spawning.reAnchorPart(live, carry.part, newEntry)
	-- Dropped at (or near) the player's own feet -- see
	-- MergeConfig.REARM_CLEARANCE's comment.
	Spawning.markDisarmed(live, carry.part)
end

function Carry.clearMushBoost(player: Player)
	local state = mushBoosts[player]
	if state == nil then
		return
	end

	mushBoosts[player] = nil
	player:SetAttribute("MushBoostActive", nil)
	player:SetAttribute("MushBoostEndsAt", nil)
	if state.humanoid.Parent ~= nil then
		state.humanoid.WalkSpeed = state.originalWalkSpeed
	end
end

--[[
	Ends the boost once its CURRENT end time passes, re-arming itself if a
	further mush pushed that end time out while this timer was running.

	The boost refreshes far faster than it expires now (MUSH_DRAIN_DEBOUNCE vs
	MUSH_BOOST_DURATION), so a plain task.delay per activation would either
	clear the boost early or need one timer per click. This keeps exactly one
	timer alive per boost, however many times it is refreshed.
]]
local function scheduleBoostExpiry(player: Player, state: Types.MushBoostState, delay: number)
	task.delay(delay, function()
		if mushBoosts[player] ~= state then
			return -- already cleared, or replaced by a newer boost
		end

		local endsAt = player:GetAttribute("MushBoostEndsAt")
		local remaining = if type(endsAt) == "number" then endsAt - Workspace:GetServerTimeNow() else 0
		if remaining > 0.05 then
			scheduleBoostExpiry(player, state, remaining)
			return
		end

		Carry.clearMushBoost(player)
	end)
end

--[[
	Pays one drain click of the carried squishy's pot, returning (payout, step,
	totalSteps) -- 0 when there is nothing worth paying.

	Writes NOTHING on a zero payout. Resetting PotSince on an empty pot would
	discard accrual the player was never paid for, which would make spamming
	mush on a fresh squishy a way to keep it permanently empty.
]]
local function drainCarriedPot(player: Player, carry: Types.CarryState): (number, number, number)
	local data = DataService.getData(player)
	if data == nil then
		return 0, 0, 0
	end

	local tier = Types.sanitizeTier(carry.entry.Tier)
	local nowSeconds = os.time()
	local pot = MergeConfig.potFor(carry.entry.Pot, carry.entry.PotSince, tier, nowSeconds)

	--[[
		Start a new drain when there is no plan, when the player picked up a
		different squishy, or when the previous plan ran to completion and the
		pot has refilled since. See DrainPlan on why the plan is fixed here
		rather than recomputed per click.
	]]
	local plan = drainProgress[player]
	if plan == nil or plan.carry ~= carry or plan.step >= plan.totalSteps then
		local totalSteps = MergeConfig.drainClicksForPot(pot, tier)
		if totalSteps <= 0 then
			return 0, 0, 0
		end
		plan = { carry = carry, step = 0, totalSteps = totalSteps, perClick = pot / totalSteps }
		drainProgress[player] = plan
	end

	--[[
		The last click takes everything left, which both closes out the plan
		exactly and sweeps up the sliver that accrued during the drain itself.

		Coins are integer-owned across the whole economy, so a share that rounds
		below 1 would pay nothing and leave the pot stuck forever. In that case
		take the remainder in one click rather than splitting it into unpayable
		slivers, and end the drain there.
	]]
	local isFinal = plan.step + 1 >= plan.totalSteps
	local payout = if isFinal then math.floor(pot) else math.floor(plan.perClick)
	if payout < 1 then
		payout = math.floor(pot)
		isFinal = true
	end
	if payout < 1 then
		return 0, 0, 0
	end

	-- The same identity guard dropCarried uses: a stale CarryState must never
	-- pay out against a squishy the profile no longer holds.
	local entryIndex = table.find(data.Merge.Squishies, carry.entry)
	if entryIndex == nil then
		return 0, 0, 0
	end

	--[[
		Pay BEFORE spending the pot. If CoinsService refuses (no profile, or the
		player is at the coin ceiling) the pot must stay exactly where it was --
		emptying it first would delete money the player never received.

		Safe to order this way because CoinsService.add does not yield: it
		re-enters QuestsService.award, which is itself yield-free, so nothing
		can observe or mutate this entry between the credit and the splice below.
	]]
	if not CoinsService.add(player, payout) then
		return 0, 0, 0
	end

	local newEntry: Types.MergeObjectEntry = {
		Tier = carry.entry.Tier,
		X = carry.entry.X,
		Z = carry.entry.Z,
		Health = carry.entry.Health,
		Pot = math.max(pot - payout, 0),
		PotSince = nowSeconds,
	}

	-- Splice rather than mutate, and move every live reference onto the new
	-- table together -- see dropCarried's note on the same rule.
	DataService.set(player, { "Merge", "Squishies", entryIndex }, newEntry)
	carry.entry = newEntry
	local live = liveBases[player]
	if live ~= nil then
		live.parts[carry.part] = newEntry
	end
	-- Republish so the squishy visibly deflates as it is drained.
	Spawning.publishPot(carry.part, newEntry)

	plan.step += 1
	local step, totalSteps = plan.step, plan.totalSteps
	if isFinal then
		-- Closed out. The next click re-plans against whatever has refilled,
		-- rather than continuing to divide an already-emptied pot.
		plan.step = plan.totalSteps
	end

	return payout, math.min(step, totalSteps), totalSteps
end

function Carry.activateMush(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end

	-- Mash debounce, not the boost, is the gate now -- see mushDebounce's note.
	local now = os.clock()
	local blockedUntil = mushDebounce[player]
	if blockedUntil ~= nil and now < blockedUntil then
		return
	end

	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	mushDebounce[player] = now + MergeConfig.MUSH_DRAIN_DEBOUNCE

	local existing = mushBoosts[player]
	if existing ~= nil then
		--[[
			Refresh, never re-apply. Re-reading humanoid.WalkSpeed here while the
			boost is already applied would bake the bonus into originalWalkSpeed
			and make it permanent -- a compounding speed exploit at one click per
			MUSH_DRAIN_DEBOUNCE.
		]]
		if existing.humanoid.Parent ~= nil then
			existing.humanoid.WalkSpeed = existing.originalWalkSpeed + MUSH_BOOST_AMOUNT
		end
		player:SetAttribute("MushBoostEndsAt", Workspace:GetServerTimeNow() + MUSH_BOOST_DURATION)
	else
		local state: Types.MushBoostState = {
			humanoid = humanoid,
			originalWalkSpeed = humanoid.WalkSpeed,
		}
		mushBoosts[player] = state
		player:SetAttribute("MushBoostEndsAt", Workspace:GetServerTimeNow() + MUSH_BOOST_DURATION)
		player:SetAttribute("MushBoostActive", true)
		humanoid.WalkSpeed = state.originalWalkSpeed + MUSH_BOOST_AMOUNT
		scheduleBoostExpiry(player, state, MUSH_BOOST_DURATION)
	end

	local payout, drainStep, drainTotal = drainCarriedPot(player, carry)

	local tier = Types.sanitizeTier(carry.entry.Tier)
	local soundId, soundVolume = MergeObjectVisuals.getMushSound(tier)
	local direction = MergeObjectVisuals.getMushDirection(tier)
	Net.mergeMushActivated.sendTo({
		tier = tier,
		soundId = soundId,
		soundVolume = soundVolume,
		direction = direction,
		payout = payout,
		drainStep = drainStep,
		drainTotal = drainTotal,
	}, player)
end

return Carry
