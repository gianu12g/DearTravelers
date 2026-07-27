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

local DataService = require(script.Parent.Parent.DataService)
local Launch = require(script.Parent.Launch)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local Net = require(ReplicatedStorage.Shared.Net)
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

local MUSH_BOOST_AMOUNT = 5
local MUSH_BOOST_DURATION = 5

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

	local newEntry: Types.MergeObjectEntry = {
		Tier = carry.entry.Tier + 1,
		X = targetEntry.X,
		Z = targetEntry.Z,
		Health = MergeConfig.healthForTier(carry.entry.Tier + 1),
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

function Carry.activateMush(player: Player)
	local carry = carries[player]
	if carry == nil or mushBoosts[player] ~= nil then
		return
	end

	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end

	local state: Types.MushBoostState = {
		humanoid = humanoid,
		originalWalkSpeed = humanoid.WalkSpeed,
	}
	mushBoosts[player] = state
	player:SetAttribute("MushBoostEndsAt", Workspace:GetServerTimeNow() + MUSH_BOOST_DURATION)
	player:SetAttribute("MushBoostActive", true)
	humanoid.WalkSpeed = state.originalWalkSpeed + MUSH_BOOST_AMOUNT

	local tier = Types.sanitizeTier(carry.entry.Tier)
	local soundId, soundVolume = MergeObjectVisuals.getMushSound(tier)
	local direction = MergeObjectVisuals.getMushDirection(tier)
	Net.mergeMushActivated.sendTo(
		{ tier = tier, soundId = soundId, soundVolume = soundVolume, direction = direction },
		player
	)

	task.delay(MUSH_BOOST_DURATION, function()
		if mushBoosts[player] == state then
			Carry.clearMushBoost(player)
		end
	end)
end

return Carry
