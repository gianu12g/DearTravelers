--!strict
--[[
	Server-authoritative spawning for the merge-gameplay loop (Phase 1): each
	player's base pad auto-spawns tiered objects at a free rate, persisted and
	restored across sessions. Free placement -- no grid, no slots.

	OWNERSHIP: BaseService (not modified here) publishes base ownership as the
	`AssignedBase` attribute on the Player -- see its header for why an
	attribute rather than Replica. This service treats that attribute as the
	single source of truth for "does this player have a live pad right now":
	it watches GetAttributeChangedSignal AND reads the attribute's current
	value once right after connecting, because BaseService may have already
	assigned a base before this service's Start() got around to hooking the
	player (join order between two services' Start()s is unspecified -- both
	just need every Init() to have finished, per ARCHITECTURE.md).

	ACTIVATION IS ASYNC, OWNERSHIP CAN CHANGE MID-FLIGHT: going live on a base
	means waiting for that player's profile data (waitForData, same polling
	pattern as PlaytimeRewardsService/FriendRewardService) and then creating
	Parts -- both of which yield or at least take real time. If the player
	releases (or is reassigned) their base while that is in flight, the
	in-progress activation must not win the race and materialize a pad the
	player no longer owns. `activationTokens` exists solely for this: every
	activate/deactivate bumps the player's token, and the async body checks
	its captured token still matches before each side effect. This is the
	same "can this stale work still commit" problem BaseService's header
	explains for claimBase, just solved with a token instead of a yield-free
	prefix, because unlike claimBase this genuinely has to yield.

	IDENTITY, NOT INDEX: each live pad's `parts` map is BasePart -> the exact
	entry table stored in that player's Merge.Squishies array (the SAME table,
	not a copy -- profile.Data flows through untouched, same as everywhere
	else in this codebase). table.clone(Squishies) when appending copies the
	array wrapper but not the entry tables inside it, so this identity survives
	every future write. Phase 2's drag/merge/remove must key off these table
	identities (e.g. table.find(currentObjects, entry)) and never off a
	remembered numeric index -- table.remove shifts every later index, but a
	table reference does not move.

	CAPACITY: auto-spawn simply stops writing once a pad reaches that player's
	persisted MaxSpawns upgrade. MergeConfig.MAX_OBJECTS remains the absolute
	safety ceiling for profile repair/restoration. No error, no queue -- the pad
	just waits until Phase 2 frees a slot. The one deliberate exception is
	Spawning.tryDeadlockRescue, which bypasses the MaxSpawns gate (never
	MAX_OBJECTS) to append a single escape-valve squishy onto a
	confirmed-deadlocked full board.

	PHASE 2 -- CARRY/MERGE/DROP:

	Pickup is server-side .Touched on each resting MergeObject part, wired
	once by spawnRestingPart (the single choke point every resting part is
	created through -- auto-spawned, restored on activation, or produced by a
	merge). Touched was chosen over a heartbeat proximity scan for pickup
	specifically because the classic case -- a MOVING character walking into
	a stationary anchored, non-collide part -- is exactly the case Touched
	fires reliably for (this is the standard Roblox "walk over the coin"
	idiom). It is NOT used for merge detection below, where both parts are
	effectively kinematic relative to each other (see that note for why).

	Carry state (`carries`) is deliberately NOT part of LiveBase or persisted
	data: the entry stays in Merge.Squishies at its ORIGINAL X/Z the entire time
	it is carried (see the IDENTITY note above -- `carries[player].entry` is
	the same table as the one inside data.Merge.Squishies), so a crash or a
	pad reassignment mid-carry needs no special-case restore -- the object is
	already exactly where the next activateBase will put it. Only a
	successful drop or merge ever writes a new X/Z.

	Merge detection is a single Heartbeat loop over `carries`, not Touched:
	the carried part is welded (kinematic relative to the character) and the
	target part is anchored (kinematic, full stop), so two kinematic bodies
	overlapping never generates the velocity-driven contact Touched relies
	on -- Touched between two parts that never truly collide is unreliable in
	practice. Distance polling has no such dependency. It stays cheap because
	`carries` only ever holds players actively carrying something (usually
	zero or one at a time per server), and the inner scan is bounded by
	MAX_OBJECTS on that one player's own pad.

	CarryingTier is published as a Player Attribute, not through
	DataService/Replica: it is public info (Phase 1's OWNERSHIP note makes the
	same call for AssignedBase) -- anyone standing nearby can already see what
	a player is carrying, so there is nothing to keep private, and an
	Attribute is the cheap, no-persistence-needed way to tell the client
	CarryController when to show its DROP button.

	Every carry-ending path (drop, merge, character removing, pad deactivation)
	clears `carries[player]` and the attribute before doing anything else, so a
	second signal arriving for the same player
	(e.g. CharacterRemoving firing while a merge is also mid-Heartbeat) finds
	nothing left to act on rather than double-processing.

	Launch deliberately is not a carry-ending path: the owned part remains
	welded to the character while a temporary clone performs the projectile
	sequence. CarryingLaunchActive gates another launch until that clone is
	cleaned up; the regular per-part cooldown begins afterwards.

	No remotes in Phase 1: every decision was made on the server with Parts
	replicating automatically. Phase 2 adds a no-payload "drop request"
	because "which spot" is a server decision
	(see Net.luau's mergeDropRequest comment) but "the player wants to drop
	now" genuinely is client-originated input. Launching adds a bounded map
	X/Z target request; the server still owns its source, surface height,
	damage, radius, drop, and return state.

	DISARM/RE-ARM (walk-off-to-re-arm, no grab cooldowns): a part placed by
	dropCarried, cancelCarry, or commitMerge's result lands at or right next
	to the owning player, so without this it would be instantly re-Touched
	and re-picked-up -- the player could never actually put anything down.
	markDisarmed adds the part to `live.disarmed`; the pickup Touched handler
	refuses a disarmed part outright; reArmSweep (same Heartbeat as merge
	detection) clears it once re-armed.

	Re-arming requires the owner's character to have stood CONTINUOUSLY
	outside MergeConfig.REARM_CLEARANCE (+ the part's own half-size) for
	MergeConfig.REARM_OUTSIDE_SECONDS, not merely instantly-outside-right-now
	-- `live.disarmed[part]` holds the accumulated continuous-outside
	seconds, reset to 0 the instant the owner is back inside the radius or
	has no character at all. An instant check is NOT enough, and this
	distinction exists specifically because of a real failure mode: at the
	moment commitMerge runs, the ramming player's root is already past
	halfSize + CARRY_GAP (the carry offset) plus 2*halfSize + MERGE_EPSILON
	(the merge threshold) from the result's position -- comfortably outside
	REARM_CLEARANCE on the very first Heartbeat -- and the player's own
	ramming momentum then carries them straight back over the part their own
	merge just re-armed. Do not "simplify" this back to a boolean disarmed
	flag; that regresses exactly this bug.

	Freshly auto-spawned/restored parts are never disarmed in the first
	place -- spawning under your feet giving a free pickup was never the
	complaint. Every path that destroys a possibly-disarmed part (currently
	just commitMerge, consuming the target) clears its `live.disarmed` entry
	too, so no key ever outlives the Part it points at.

	PHASE 3 -- PASSIVE INCOME: see runIncomeTick's own header note for the
	full reasoning. In one line: one aggregated CoinsService.add() per player
	per second, summed over data.Merge.Squishies (not live.parts and not a
	per-object write), riding the same Heartbeat connection as Phase 2 rather
	than spawning a loop per player. After a successful grant, one transient
	mergeIncomePulse event tells that owning client to display every resting
	model's "+$X" popup in the same frame. Coins remains Replica-owned; the
	event carries no balance state.

	--------------------------------------------------------------------------

	SPLIT MODULE MAP: this init.luau is the thin lifecycle/orchestration
	layer -- it owns the three cross-cutting state tables (`liveBases`,
	`carries`, `activeLaunches`) that nearly every sibling needs, hands them
	out once via each sibling's own setup() call, and wires the Net listeners,
	Player join/leave hooks, and the shared Heartbeat loop. The actual Phase
	1/2/3 logic above lives in:

	  Types         -- shared type aliases + pure sanitize/clamp helpers
	  StatusUI      -- the floating health bar / launch-cooldown Gui
	  LaunchEffects -- pure LaunchState scale/beam helpers (Launch + Damage)
	  Assets        -- boot-time map/base/cosmetic-template discovery
	  Vfx           -- merge/launch visual + audio effects
	  Spawning      -- Phase 1 auto-spawn, pad activation, pickup wiring
	  Damage        -- the public damage/inventory API (dev console + combat)
	  Launch        -- Phase 2 launch: pickup -> projectile -> impact
	  Carry         -- Phase 2 carry/merge/drop, re-arm sweep, Mush boost
	  Income        -- Phase 3 passive income + activity checkpoint
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)

-- Every child is required from this top-level chain -- Carry alone
-- transitively requires Launch, Damage, Spawning, Vfx, Assets, LaunchEffects,
-- StatusUI, and Types before its own require() call returns -- so every
-- child's module-scope side effects run at the same boot timing they had as
-- part of the monolith, per the Rojo init-split convention.
local Assets = require(script.Assets)
local Carry = require(script.Carry)
local Damage = require(script.Damage)
local Income = require(script.Income)
local Launch = require(script.Launch)
local Spawning = require(script.Spawning)
local Types = require(script.Types)

local log = Log.new("MergeService")

local mergeInputLimiter = RateLimiter.new(8, 12)
local launchInputLimiter = RateLimiter.new(2, 3)

-- Owned here and handed to every sibling that needs one via its own setup()
-- call (see Spawning.luau's header note on the pattern) -- these three are
-- read and/or written across nearly every phase, so they stay in the one
-- place every sibling can get a reference to the SAME table from.
local liveBases: { [Player]: Types.LiveBase } = {}
local carries: { [Player]: Types.CarryState } = {}
local activeLaunches: { [Player]: Types.LaunchState } = {}

local attributeConnections: { [Player]: RBXScriptConnection } = {}
-- Drives cancelCarry on death/respawn/leaving -- reverse-indexed by Player
-- for the same reason attributeConnections is (PlayerRemoving only hands us
-- a Player).
local characterRemovingConnections: { [Player]: RBXScriptConnection } = {}

-- Phase 3. Accumulated Heartbeat dt, driving one aggregated income tick per
-- INCOME_INTERVAL -- see Income.runTick's own header note for why this rides
-- the existing Heartbeat connection instead of a loop per player.
local incomeAccumulator = 0
local activityCheckpointAccumulator = 0

local MergeService = {}

MergeService.getSquishies = Damage.getSquishies
MergeService.damageSquishies = Damage.damageSquishies
MergeService.damageSquishiesNear = Damage.damageSquishiesNear
MergeService.spawnSquishies = Damage.spawnSquishies
MergeService.clearSquishies = Damage.clearSquishies
MergeService.resetIncomeRemainder = Income.resetRemainder

local function onAssignedBaseChanged(player: Player)
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) == "string" then
		Spawning.activateBase(player, baseName)
	else
		Spawning.deactivateBase(player)
	end
end

local function onPlayerAdded(player: Player)
	if attributeConnections[player] ~= nil then
		-- Already hooked -- nothing to do. Same guard BaseService.onPlayerAdded
		-- uses for the analogous case: a second call here would leak the old
		-- connection and double-drive onAssignedBaseChanged for one player.
		return
	end

	local changedSignal = player:GetAttributeChangedSignal("AssignedBase")
	attributeConnections[player] = changedSignal:Connect(function()
		onAssignedBaseChanged(player)
	end)
	-- BaseService may have already assigned a base before this connection
	-- existed -- read the attribute's current value once, right after
	-- connecting, so that case isn't silently missed (see header).
	onAssignedBaseChanged(player)

	-- Phase 2: cancel a carry on death/respawn/leaving. CharacterRemoving
	-- fires for the player's whole session regardless of how many characters
	-- they go through, so one connection per player (not per character) is
	-- enough -- same shape as attributeConnections above.
	local removingSignal = player.CharacterRemoving
	characterRemovingConnections[player] = removingSignal:Connect(function()
		Carry.cancelCarry(player)
		Carry.clearMushBoost(player)
	end)
end

local function onPlayerRemoving(player: Player)
	local connection = attributeConnections[player]
	if connection ~= nil then
		attributeConnections[player] = nil
		connection:Disconnect()
	end

	local characterRemovingConnection = characterRemovingConnections[player]
	if characterRemovingConnection ~= nil then
		characterRemovingConnections[player] = nil
		characterRemovingConnection:Disconnect()
	end

	Spawning.deactivateBase(player)
	Carry.clearMushBoost(player)
	Spawning.clearPlayer(player)
	Income.clearPlayer(player)
	Carry.clearPlayer(player)
end

--[[
	Registered here, not Start(): NETWORKING-AND-DATA.md's rule for packet
	listeners applies on the server the same as the client -- a listener that
	doesn't exist yet cannot lose a packet that a fast Start() elsewhere
	provokes. Requiring Shared.Net above is also what publishes this
	namespace's packet IDs server-side in the first place (Net.luau's own
	header note).
]]
function MergeService.Init()
	Spawning.setup({
		liveBases = liveBases,
		carries = carries,
		activeLaunches = activeLaunches,
		-- Runs the carry/launch cleanup for `player` before deactivateBase
		-- tears the pad's objectsFolder down. Injected rather than required
		-- directly so Spawning never has to require Carry/Launch -- both of
		-- those already depend on Spawning, and a direct require back would
		-- cycle.
		onDeactivate = function(player: Player)
			Carry.cancelCarry(player)
			Launch.cancelLaunch(player)
		end,
	})
	local sharedState = { liveBases = liveBases, carries = carries, activeLaunches = activeLaunches }
	Carry.setup(sharedState)
	Launch.setup(sharedState)
	Damage.setup(sharedState)
	Income.setup({ liveBases = liveBases })

	Net.mergeDropRequest.listen(function(_data, player)
		if player ~= nil and mergeInputLimiter:allow(player) then
			Carry.dropCarried(player)
		end
	end)

	Net.mergeLaunchRequest.listen(function(data, player)
		if player == nil then
			return
		end
		if not launchInputLimiter:allow(player) then
			Net.mergeLaunchResult.sendTo({ ok = false, message = "Please wait before launching again" }, player)
			return
		end

		local ok, message = Launch.launchCarried(player, data.worldX, data.worldZ)
		Net.mergeLaunchResult.sendTo({ ok = ok, message = message }, player)
	end)

	Net.mergeMushRequest.listen(function(_data, player)
		if player ~= nil and mergeInputLimiter:allow(player) then
			Carry.activateMush(player)
		end
	end)
end

function MergeService.Start()
	local baseCount = Assets.load()
	if baseCount == nil then
		return
	end

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	SafePlayerAdded(onPlayerAdded)

	-- Phase 2 merge detection + re-arm sweep, and Phase 3's income tick, all
	-- share this one Heartbeat connection rather than each getting its own
	-- loop: liveBases/carries are already bounded and cheap to sweep every
	-- frame (see Carry.reArmSweep's own note), and an accumulator is all a
	-- 1-second cadence needs -- there is no reason for the income tick in
	-- particular to be its own task.spawn loop (let alone one per player)
	-- when it is exactly as bursty-free sitting here.
	RunService.Heartbeat:Connect(function(dt: number)
		Carry.checkAllCarriesForMerge()
		Carry.reArmSweep(dt)

		incomeAccumulator += dt
		while incomeAccumulator >= MergeConfig.INCOME_INTERVAL do
			incomeAccumulator -= MergeConfig.INCOME_INTERVAL
			Income.runTick()
		end

		activityCheckpointAccumulator += dt
		if activityCheckpointAccumulator >= MergeConfig.ACTIVITY_CHECKPOINT_INTERVAL then
			activityCheckpointAccumulator %= MergeConfig.ACTIVITY_CHECKPOINT_INTERVAL
			Income.checkpointLastActive()
		end
	end)

	log.info(`ready ({baseCount} bases)`)
end

return MergeService
