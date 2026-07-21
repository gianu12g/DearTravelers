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
	entry table stored in that player's Merge.Objects array (the SAME table,
	not a copy -- profile.Data flows through untouched, same as everywhere
	else in this codebase). table.clone(Objects) when appending copies the
	array wrapper but not the entry tables inside it, so this identity survives
	every future write. Phase 2's drag/merge/remove must key off these table
	identities (e.g. table.find(currentObjects, entry)) and never off a
	remembered numeric index -- table.remove shifts every later index, but a
	table reference does not move.

	CAPACITY: auto-spawn simply stops writing once a pad holds MAX_OBJECTS.
	No error, no queue -- the pad just waits until Phase 2 frees a slot.

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
	data: the entry stays in Merge.Objects at its ORIGINAL X/Z the entire time
	it is carried (see the IDENTITY note above -- `carries[player].entry` is
	the same table as the one inside data.Merge.Objects), so a crash or a
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

	Every carry-ending path (drop, merge, character removing, pad
	deactivation) funnels through either dropCarried, commitMerge, or
	cancelCarry -- all three clear `carries[player]` and the attribute before
	doing anything else, so a second signal arriving for the same player
	(e.g. CharacterRemoving firing while a merge is also mid-Heartbeat) finds
	nothing left to act on rather than double-processing.

	No remotes in Phase 1: every decision was made on the server with Parts
	replicating automatically. Phase 2 adds exactly one remote -- a
	no-payload "drop request" -- because "which spot" is a server decision
	(see Net.luau's mergeDropRequest comment) but "the player wants to drop
	now" genuinely is client-originated input.

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
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)

local log = Log.new("MergeService")

local BASE_COUNT = 8
-- Same tolerance and bound as BaseService: a base whose pieces never stream
-- in must not hang Start() (and therefore every player join) forever.
local WAIT_TIMEOUT = 10

local random = Random.new()

-- Mirrors the shape written into DataService's TEMPLATE.Merge.Objects
-- exactly (DataService.luau, Merge field) -- kept local rather than shared
-- for the same "DataService stays generic" reason documented there.
type MergeObjectEntry = {
	Tier: number,
	X: number,
	Z: number,
}

type BaseRecord = {
	part: BasePart,
	spawnArea: BasePart,
}

type LiveBase = {
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

-- Phase 2. `entry` is the SAME table referenced from data.Merge.Objects and
-- from `live.parts[part]` (see the header's IDENTITY note) -- it is never
-- replaced while carried, only while dropped or consumed by a merge.
type CarryState = {
	live: LiveBase,
	part: BasePart,
	entry: MergeObjectEntry,
	weld: WeldConstraint,
}

-- Populated once during Start(); read-only afterwards.
local bases: { [string]: BaseRecord } = {}

local liveBases: { [Player]: LiveBase } = {}
local attributeConnections: { [Player]: RBXScriptConnection } = {}
-- See the header's ACTIVATION IS ASYNC note.
local activationTokens: { [Player]: number } = {}

-- Phase 2. At most one entry per player (capacity is exactly one).
local carries: { [Player]: CarryState } = {}
-- Drives cancelCarry on death/respawn/leaving -- reverse-indexed by Player
-- for the same reason attributeConnections is (PlayerRemoving only hands us
-- a Player).
local characterRemovingConnections: { [Player]: RBXScriptConnection } = {}

local MergeService = {}

--[[
	Clamps `tier` into [1, MAX_TIER] and floors it, defaulting to 1 for
	anything that isn't a real number (NaN included -- every comparison
	against NaN is false, so it must be caught before the clamp, same trap
	Progression.sanitizeLevel guards against). Profile data for this field is
	only ever written by trySpawnObject below today, but the dev console can
	still plant a bad value directly, and a corrupted Tier must not propagate
	into an out-of-bounds MergeConfig.Tiers lookup.
]]
local function sanitizeTier(tier: number): number
	if type(tier) ~= "number" or tier ~= tier then
		return 1
	end
	return math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
end

local function tierDefFor(tier: number): MergeConfig.TierDef
	return MergeConfig.Tiers[sanitizeTier(tier)]
end

--[[
	One MergeObject Part for `entry`, NOT yet parented. Factored out so
	Phase 2 (drag/merge) can call it again when a merge result needs a fresh
	Part instead of duplicating this instancing code.

	Position is pad-local by construction: spawnArea.CFrame * CFrame.new(x,
	yOffset, z) is correct regardless of which of the 8 differently-rotated
	bases `spawnArea` belongs to -- the whole reason Objects is stored in
	pad-local coordinates in the first place (DataService.luau's Merge
	comment).
]]
local function materializeObject(spawnArea: BasePart, entry: MergeObjectEntry): BasePart
	local tierDef = tierDefFor(entry.Tier)

	local part = Instance.new("Part")
	part.Name = "MergeObject"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(tierDef.Size, tierDef.Size, tierDef.Size)
	part.Color = tierDef.Color
	part:SetAttribute("Tier", entry.Tier)

	local yOffset = spawnArea.Size.Y / 2 + tierDef.Size / 2
	part.CFrame = spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TierLabel"
	billboard.Size = UDim2.fromOffset(80, 24)
	billboard.StudsOffset = Vector3.new(0, tierDef.Size / 2 + 0.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local tierText = Instance.new("TextLabel")
	tierText.Name = "TierText"
	tierText.Size = UDim2.fromScale(1, 1)
	tierText.BackgroundTransparency = 1
	tierText.Font = Enum.Font.GothamBold
	tierText.TextScaled = true
	tierText.TextColor3 = Color3.new(1, 1, 1)
	tierText.TextStrokeTransparency = 0.5
	tierText.Text = `Lv.{entry.Tier}`
	tierText.Parent = billboard

	return part
end

--[[
	Rejection-sampling search for a free spot on `spawnArea`, inset by
	PAD_MARGIN + the new object's own half-size, rejecting any candidate
	closer than (both half-sizes + MIN_GAP) to an already-placed object.
	Returns nil, nil if MAX_PLACEMENT_ATTEMPTS all land on an occupied spot,
	or if `tierDef` is too large to fit the pad at all.
]]
local function findOpenSpot(
	spawnArea: BasePart,
	tierDef: MergeConfig.TierDef,
	existing: { [BasePart]: MergeObjectEntry }
): (number?, number?)
	local halfSize = tierDef.Size / 2
	local rangeX = spawnArea.Size.X / 2 - MergeConfig.PAD_MARGIN - halfSize
	local rangeZ = spawnArea.Size.Z / 2 - MergeConfig.PAD_MARGIN - halfSize
	if rangeX <= 0 or rangeZ <= 0 then
		return nil, nil
	end

	for _ = 1, MergeConfig.MAX_PLACEMENT_ATTEMPTS do
		local x = (random:NextNumber() * 2 - 1) * rangeX
		local z = (random:NextNumber() * 2 - 1) * rangeZ

		local fits = true
		for _, entry in existing do
			local otherHalf = tierDefFor(entry.Tier).Size / 2
			local minDistance = halfSize + otherHalf + MergeConfig.MIN_GAP
			local dx = x - entry.X
			local dz = z - entry.Z
			if dx * dx + dz * dz < minDistance * minDistance then
				fits = false
				break
			end
		end

		if fits then
			return x, z
		end
	end

	return nil, nil
end

-- Same polling wait as PlaytimeRewardsService/FriendRewardService/etc:
-- DataService.getData(player) returns nil until that player's ProfileStore
-- session finishes loading (async, started from DataService.Start()).
local function waitForData(player: Player): DataService.PlayerData?
	local data = DataService.getData(player)
	while data == nil and player.Parent == Players do
		task.wait(0.25)
		data = DataService.getData(player)
	end
	return data
end

--[[
	Puts `part` back to being a plain resting object at `entry`'s persisted
	pad-local spot -- the exact CFrame math materializeObject uses, so a
	re-anchored object sits identically to one that was never picked up.
	Used by every carry-cancel path (drop, character removing, pad
	deactivation); those paths never destroy and recreate the part, only
	this.
]]
local function reAnchorPart(live: LiveBase, part: BasePart, entry: MergeObjectEntry)
	if part.Parent == nil then
		return -- already destroyed (e.g. the pad's folder was torn down first)
	end

	local tierDef = tierDefFor(entry.Tier)
	local yOffset = live.spawnArea.Size.Y / 2 + tierDef.Size / 2
	part.CFrame = live.spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)
	part.Anchored = true
	part.Massless = false
	part.CanCollide = false
end

--[[
	Marks `part` not-yet-pickup-eligible, with a fresh (zero) continuous-
	outside accumulator. Called by every path that places a resting part
	somewhere the owning player could otherwise instantly re-grab it
	(dropCarried, cancelCarry, commitMerge's result) -- see the
	LiveBase.disarmed field comment and MergeConfig.REARM_OUTSIDE_SECONDS for
	the re-arm rule that eventually clears it.
]]
local function markDisarmed(live: LiveBase, part: BasePart)
	live.disarmed[part] = 0
end

local EXPLOSION_LIFETIME = 1.5
local EXPLOSION_PARTICLE_COUNT = 40

--[[
	Placeholder-quality mini explosion at a merge's target (mergee) position --
	ParticleEmitter burst only, no Sound (spec calls it optional and there is
	no existing SFX asset id in this codebase to reuse without guessing one).
	Parented under the pad's own MergeObjects folder per the naming rules
	(model-naming-style.md), so it is destroyed along with everything else if
	the pad deactivates mid-burst instead of leaking into Workspace.
]]
local function spawnMergeVfx(objectsFolder: Folder, position: Vector3)
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

--[[
	Attaches `part` (a resting object on `live`'s pad) to `player`'s torso,
	floating in front of it, offset by the object's own half-size so bigger
	tiers don't clip into the character.

	WeldConstraint locks the CURRENT relative transform at creation time (it
	has no offset of its own), which is why the CFrame is set FIRST, then the
	weld is created -- reversing the order would weld it wherever it
	physically happened to be instead of the carry pose.

	Network ownership is not set explicitly: an unanchored part rigidly
	welded into a character's assembly automatically follows that
	character's network owner (this is the same mechanism that makes a held
	Tool move smoothly for its holder), which is exactly "network ownership
	follows the character automatically" from the spec.
]]
local function pickUp(player: Player, part: BasePart)
	if carries[player] ~= nil then
		return -- capacity is exactly one; a second Touched this tick is a no-op
	end

	local live = liveBases[player]
	local entry = if live ~= nil then live.parts[part] else nil
	if live == nil or entry == nil then
		return -- pad went stale between the Touched firing and this running
	end

	local character = player.Character
	local attachPoint = if character ~= nil
		then (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso"))
		else nil
	if attachPoint == nil or not attachPoint:IsA("BasePart") then
		return -- no rig to carry it in front of (character streaming in/out)
	end

	local tierDef = tierDefFor(entry.Tier)
	local offset = tierDef.Size / 2 + MergeConfig.CARRY_GAP
	part.CFrame = attachPoint.CFrame * CFrame.new(0, 0, -offset)
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = attachPoint
	weld.Part1 = part
	weld.Parent = part

	carries[player] = { live = live, part = part, entry = entry, weld = weld }
	player:SetAttribute("CarryingTier", entry.Tier)
end

--[[
	Server-side pickup detection: .Touched on the resting Part itself. See the
	header's PHASE 2 note for why Touched (not a heartbeat scan) is the right
	tool here -- a moving character walking into a stationary, anchored,
	non-collide Part is the textbook reliable case for it.
]]
local function wirePickupTouched(player: Player, live: LiveBase, part: BasePart)
	part.Touched:Connect(function(hit: BasePart)
		if liveBases[player] ~= live then
			return -- pad no longer live for this player; part is on its way out
		end
		if carries[player] ~= nil then
			return -- already carrying -- walking over other objects does nothing
		end
		if live.disarmed[part] ~= nil then
			return -- not yet re-armed -- see LiveBase.disarmed's comment
		end

		-- Ancestry, not .Parent: a hat/tool/accessory part touching this Part
		-- has the character somewhere ABOVE it, not as its direct parent, and
		-- .Parent alone would silently miss the pickup for those cases.
		local character = hit:FindFirstAncestorOfClass("Model")
		if character == nil or not character:IsA("Model") then
			return
		end
		if character:FindFirstChildOfClass("Humanoid") == nil then
			return -- not a character limb (a dropped tool, a projectile, ...)
		end

		-- Own pad only: a touch from anyone but the pad's owner is ignored.
		local touchingPlayer = Players:GetPlayerFromCharacter(character)
		if touchingPlayer ~= player then
			return
		end

		pickUp(player, part)
	end)
end

--[[
	The single choke point every resting MergeObject Part is created through
	-- auto-spawned (trySpawnObject), restored on activation (activateBase),
	or produced by a merge (commitMerge). Centralising it here is what
	guarantees pickup detection is wired onto every one of them without each
	call site remembering to do it itself.
]]
local function spawnRestingPart(player: Player, live: LiveBase, entry: MergeObjectEntry): BasePart
	local part = materializeObject(live.spawnArea, entry)
	part.Parent = live.objectsFolder
	live.parts[part] = entry
	wirePickupTouched(player, live, part)
	return part
end

local function trySpawnObject(player: Player, live: LiveBase)
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	if #data.Merge.Objects >= MergeConfig.MAX_OBJECTS then
		return -- pad full; auto-spawn just waits
	end

	local tier = sanitizeTier(data.Merge.SpawnLevel)
	local tierDef = MergeConfig.Tiers[tier]

	local x, z = findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x == nil or z == nil then
		-- Crowded-but-under-cap: skip this tick, try again next one.
		return
	end

	-- Rounded to ~2 decimals at write time (spec) so saved coordinates don't
	-- accumulate float noise across sessions.
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100

	local entry: MergeObjectEntry = { Tier = tier, X = roundedX, Z = roundedZ }

	--[[
		NEVER mutate profile data directly (ARCHITECTURE.md). table.clone
		copies the array wrapper only -- existing entry tables inside it (and
		therefore every key already in live.parts) keep their identity, which
		is what the header's IDENTITY note depends on.
	]]
	local updated = table.clone(data.Merge.Objects)
	table.insert(updated, entry)
	DataService.set(player, { "Merge", "Objects" }, updated)

	spawnRestingPart(player, live, entry)
end

local function runAutoSpawnLoop(player: Player, live: LiveBase)
	-- `liveBases[player] == live` (identity, not just non-nil) is what makes
	-- this loop exit both on the player leaving/releasing the base AND on a
	-- later re-activation replacing this LiveBase with a new one -- either
	-- way, this exact loop's job is done.
	while player.Parent == Players and liveBases[player] == live do
		task.wait(MergeConfig.SPAWN_INTERVAL)
		if liveBases[player] ~= live then
			break
		end
		trySpawnObject(player, live)
	end
end

--[[
	Ends a carry without a merge or a deliberate drop: character removing
	(death/respawn/leaving) or the pad going away underneath the player. The
	entry's X/Z never changed while carried (see the header's PHASE 2 note),
	so this needs no DataService write -- putting the SAME part back where it
	already persists is enough.

	Safe to call when nothing is being carried (every caller does, rather
	than checking first) and safe to call right before the pad's whole
	objectsFolder gets destroyed a moment later -- reAnchorPart's own
	Parent-nil guard covers that.
]]
local function cancelCarry(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	carries[player] = nil
	player:SetAttribute("CarryingTier", nil)

	carry.weld:Destroy()
	reAnchorPart(carry.live, carry.part, carry.entry)
	-- The respawned player can land right on top of this spot (base center)
	-- -- see MergeConfig.REARM_CLEARANCE's comment.
	markDisarmed(carry.live, carry.part)
end

local function deactivateBase(player: Player)
	-- Bumped unconditionally, even if no pad is live yet, so an
	-- activateBase() still waiting on waitForData/materializing for this
	-- player sees its token invalidated the instant release happens.
	activationTokens[player] = (activationTokens[player] or 0) + 1

	-- Before the objectsFolder (and therefore the carried Part) disappears --
	-- see cancelCarry's own header note on why this is safe either way.
	cancelCarry(player)

	local live = liveBases[player]
	if live == nil then
		return
	end
	liveBases[player] = nil
	-- Destroys every MergeObject Part and its BillboardGui child in one call.
	live.objectsFolder:Destroy()
end

local function activateBase(player: Player, baseName: string)
	local existing = liveBases[player]
	if existing ~= nil then
		if existing.baseName == baseName then
			return -- already live on this exact base -- nothing to do
		end
		-- Not expected given BaseService's claim/release contract (a base
		-- change always clears the attribute first), but never assume a
		-- second system's invariant from here -- release the stale pad first.
		deactivateBase(player)
	end

	local record = bases[baseName]
	if record == nil then
		log.warn(`{player.Name} was assigned {baseName}, which has no usable SpawnArea -- merge pad will not go live`)
		return
	end

	local token = (activationTokens[player] or 0) + 1
	activationTokens[player] = token

	task.spawn(function()
		local data = waitForData(player)
		if data == nil or activationTokens[player] ~= token then
			-- Player left before data loaded, or superseded while waiting --
			-- see the header's ACTIVATION IS ASYNC note.
			return
		end

		local folder = Instance.new("Folder")
		folder.Name = "MergeObjects"
		folder.Parent = record.part

		local live: LiveBase = {
			baseName = baseName,
			spawnArea = record.spawnArea,
			objectsFolder = folder,
			parts = {},
			disarmed = {},
		}
		-- Set BEFORE the restore loop below: spawnRestingPart's Touched wiring
		-- closes over `live` and checks `liveBases[player] == live` on every
		-- fire, so it must already be published before any part exists to be
		-- touched.
		liveBases[player] = live

		-- Capped at MAX_OBJECTS even though a compliant writer never exceeds
		-- it: profile data is attacker-influenced over a long enough time
		-- horizon (dev console, a future migration bug), and a planted
		-- oversized array must not materialize hundreds of Parts.
		local restoreCount = math.min(#data.Merge.Objects, MergeConfig.MAX_OBJECTS)
		for i = 1, restoreCount do
			spawnRestingPart(player, live, data.Merge.Objects[i])
		end

		runAutoSpawnLoop(player, live)
	end)
end

--[[
	Commits a ram-to-merge: `carry` (tier t, still attached to the player)
	touched `targetPart`/`targetEntry` (also tier t, resting on the same
	pad). Rebuilds Objects removing BOTH entries and appending one {t+1,
	targetEntry.X, targetEntry.Z} in a single DataService.set -- no yields
	between the read and the write (quality-gate.md trap #5), so this cannot
	race a second commit for the same player (there is only ever one
	Heartbeat loop, and carries[player] is cleared before this returns).
]]
local function commitMerge(player: Player, carry: CarryState, targetPart: BasePart, targetEntry: MergeObjectEntry)
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but a merge must not vanish the carried
		-- object into thin air if it somehow happens -- leave everything as
		-- it is and let the next Heartbeat tick try again.
		return
	end

	local newEntry: MergeObjectEntry = { Tier = carry.entry.Tier + 1, X = targetEntry.X, Z = targetEntry.Z }

	local updated = table.create(#data.Merge.Objects)
	for _, existingEntry in data.Merge.Objects do
		if existingEntry ~= carry.entry and existingEntry ~= targetEntry then
			table.insert(updated, existingEntry)
		end
	end
	table.insert(updated, newEntry)
	DataService.set(player, { "Merge", "Objects" }, updated)

	-- Captured before Destroy: the VFX plays at the mergee's position, and
	-- reading .Position after Destroy is not something to rely on.
	local vfxPosition = targetPart.Position

	carries[player] = nil
	player:SetAttribute("CarryingTier", nil)
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

	spawnMergeVfx(live.objectsFolder, vfxPosition)
	-- The result appears wherever the target sat -- which the carrying
	-- player was, by definition, standing right next to. Same instant-
	-- re-grab problem as a drop, same fix.
	local newPart = spawnRestingPart(player, live, newEntry)
	markDisarmed(live, newPart)
end

--[[
	One carrying player's merge check for this Heartbeat tick. See the
	header's PHASE 2 note for why this is distance polling and not Touched.
]]
local function tryMergeCarry(player: Player, carry: CarryState)
	local entry = carry.entry
	if entry.Tier >= MergeConfig.MAX_TIER then
		return -- tier+1 wouldn't exist -- two max-tier objects never merge (spec)
	end

	local halfSize = tierDefFor(entry.Tier).Size / 2
	local threshold = halfSize + halfSize + MergeConfig.MERGE_EPSILON -- same tier -> same size
	local carryPosition = carry.part.Position

	-- Horizontal-only, matching findOpenSpot/computeDropSpot's 2D model of
	-- the pad: the carried part floats at torso height, well above a resting
	-- object's center, so 3D distance would let that vertical gap eat most
	-- of the threshold -- worst for small tiers, whose whole size is close
	-- to the gap itself.
	local target: BasePart? = nil
	local targetEntry: MergeObjectEntry? = nil
	for otherPart, otherEntry in carry.live.parts do
		if otherPart == carry.part or otherEntry.Tier ~= entry.Tier then
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
		commitMerge(player, carry, target, targetEntry)
	end
end

local function checkAllCarriesForMerge()
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

	`dt` is threaded through from the shared Heartbeat connection in Start()
	rather than read from RunService here, keeping this a pure function of
	its arguments like the rest of this module's Heartbeat-driven code.

	`liveBases` is bounded by BASE_COUNT (8), so iterating all of it every
	Heartbeat is cheap on its own; the `next(live.disarmed) == nil` check
	skips the character lookup and inner scan entirely for the (usual) case
	of a pad with nothing disarmed on it right now.
]]
local function reArmSweep(dt: number)
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
			local halfSize = if entry ~= nil then tierDefFor(entry.Tier).Size / 2 else 0
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
local function computeDropSpot(live: LiveBase, carry: CarryState, character: Model?): (number, number)
	local tierDef = tierDefFor(carry.entry.Tier)
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
		local otherHalf = tierDefFor(otherEntry.Tier).Size / 2
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

	local x, z = findOpenSpot(live.spawnArea, tierDef, live.parts)
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
local function dropCarried(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but never strand the object mid-air --
		-- put it back exactly where it already persists and stop.
		cancelCarry(player)
		return
	end

	local x, z = computeDropSpot(live, carry, player.Character)
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100
	local newEntry: MergeObjectEntry = { Tier = carry.entry.Tier, X = roundedX, Z = roundedZ }

	-- Splice the fresh entry in place of the old one rather than mutating
	-- carry.entry's fields directly -- ARCHITECTURE.md's "never touch
	-- profile.Data directly" rule applies even though carry.entry IS a
	-- profile.Data table (see the header's IDENTITY note); only a
	-- DataService.set call may change what a client sees.
	local updated = table.create(#data.Merge.Objects)
	for _, existingEntry in data.Merge.Objects do
		table.insert(updated, if existingEntry == carry.entry then newEntry else existingEntry)
	end
	DataService.set(player, { "Merge", "Objects" }, updated)

	carries[player] = nil
	player:SetAttribute("CarryingTier", nil)
	carry.weld:Destroy()

	live.parts[carry.part] = newEntry
	reAnchorPart(live, carry.part, newEntry)
	-- Dropped at (or near) the player's own feet -- see
	-- MergeConfig.REARM_CLEARANCE's comment.
	markDisarmed(live, carry.part)
end

local function onAssignedBaseChanged(player: Player)
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) == "string" then
		activateBase(player, baseName)
	else
		deactivateBase(player)
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
		cancelCarry(player)
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

	deactivateBase(player)
	activationTokens[player] = nil
end

--[[
	Read-only copy of `player`'s merge objects, or nil if their data isn't
	loaded. Deep-copies each entry (not just the array) so a caller cannot
	reach back into profile.Data through the returned tables -- returning the
	live entry tables directly would let external code mutate saved data
	without going through DataService.set, silently desyncing the replica.
]]
function MergeService.getObjects(player: Player): { MergeObjectEntry }?
	local data = DataService.getData(player)
	if data == nil then
		return nil
	end

	local copy: { MergeObjectEntry } = {}
	for _, entry in data.Merge.Objects do
		table.insert(copy, { Tier = entry.Tier, X = entry.X, Z = entry.Z })
	end
	return copy
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
	Net.mergeDropRequest.listen(function(_data, player)
		if player ~= nil then
			dropCarried(player)
		end
	end)
end

function MergeService.Start()
	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- MergeService disabled")
		return
	end

	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- MergeService disabled")
		return
	end

	local baseCount = 0
	for i = 1, BASE_COUNT do
		local baseName = `Base{i}`

		local part = basesFolder:WaitForChild(baseName, WAIT_TIMEOUT)
		if part == nil or not part:IsA("BasePart") then
			log.warn(`Bases.{baseName} is missing or not a BasePart -- excluded from merge spawning`)
			continue
		end
		local basePart: BasePart = part

		local spawnAreaInstance = basePart:WaitForChild("SpawnArea", WAIT_TIMEOUT)
		if spawnAreaInstance == nil or not spawnAreaInstance:IsA("BasePart") then
			log.warn(`{baseName}.SpawnArea is missing or not a BasePart -- excluded from merge spawning`)
			continue
		end
		local spawnArea: BasePart = spawnAreaInstance

		bases[baseName] = { part = basePart, spawnArea = spawnArea }
		baseCount += 1
	end

	if baseCount == 0 then
		log.error("no base has a usable SpawnArea -- MergeService disabled")
		return
	end

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	SafePlayerAdded(onPlayerAdded)

	-- Phase 2 merge detection + re-arm sweep -- see the header's PHASE 2 note
	-- for why merge detection is distance polling rather than Touched, and
	-- LiveBase.disarmed for what the sweep is re-arming.
	RunService.Heartbeat:Connect(function(dt: number)
		checkAllCarriesForMerge()
		reArmSweep(dt)
	end)

	log.info(`ready ({baseCount} bases)`)
end

return MergeService
