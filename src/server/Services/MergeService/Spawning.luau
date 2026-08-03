--!strict
--[[
	Phase 1 auto-spawn (each player's base pad materializing and restoring
	tiered objects) plus the single choke point every resting MergeObject
	Part is created through -- spawnRestingPart -- and the Touched-based
	pickup detection wired onto every one of them. See the MergeService
	init.luau header for the full PHASE 1/OWNERSHIP/ACTIVATION/IDENTITY
	design notes; this module is where that design is implemented.

	`liveBases`, `carries`, and `activeLaunches` are owned by init.luau and
	handed to this module once via Spawning.setup() -- see that function's
	own note. `activationTokens` is this module's own state (see the header's
	ACTIVATION IS ASYNC note in init.luau): nothing outside Spawning needs it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Assets = require(script.Parent.Assets)
local DataService = require(script.Parent.Parent.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local StatusUI = require(script.Parent.StatusUI)
local Types = require(script.Parent.Types)
local UINotificationService = require(script.Parent.Parent.UISystem.UINotificationService)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local log = Log.new("MergeService")

local random = Random.new()

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
	carries: { [Player]: Types.CarryState },
	activeLaunches: { [Player]: Types.LaunchState },
	-- Runs cancelCarry/cancelLaunch for `player` before deactivateBase tears
	-- the pad down. Injected from init rather than required directly so
	-- Spawning never has to require Carry/Launch -- see init.luau's own
	-- MergeService.Init() for why (a direct require would cycle back here).
	onDeactivate: (Player) -> (),
}

type SquishyDraft = {
	Tier: number,
	Health: number,
}

-- Set once by Spawning.setup(), called from init.Init(). See this file's own
-- header note on why these three are references to init-owned tables rather
-- than state this module holds itself.
local liveBases: { [Player]: Types.LiveBase } = nil :: any
local carries: { [Player]: Types.CarryState } = nil :: any
local activeLaunches: { [Player]: Types.LaunchState } = nil :: any
local onDeactivate: (Player) -> () = nil :: any

-- Phase 1. See the init.luau header's ACTIVATION IS ASYNC note.
local activationTokens: { [Player]: number } = {}

local Spawning = {}

function Spawning.setup(deps: Deps)
	liveBases = deps.liveBases
	carries = deps.carries
	activeLaunches = deps.activeLaunches
	onDeactivate = deps.onDeactivate
end

-- Called from onPlayerRemoving: forgets this player's activation token
-- entirely (deactivateBase only ever bumps it) so the table does not carry a
-- stale entry for a Player instance that will never rejoin.
function Spawning.clearPlayer(player: Player)
	activationTokens[player] = nil
end

--[[
	One authoritative MergeObject root Part for `entry`, NOT yet parented.
	Replaceable artwork is cloned under that root by MergeObjectVisuals, keeping
	all gameplay code keyed to one stable BasePart regardless of model shape.
	Factored out so Phase 2 (drag/merge) can call it again when a merge result
	needs a fresh object instead of duplicating this instancing code.

	Position is pad-local by construction: spawnArea.CFrame * CFrame.new(x,
	yOffset, z) is correct regardless of which of the 8 differently-rotated
	bases `spawnArea` belongs to -- the whole reason Squishies is stored in
	pad-local coordinates in the first place (DataService.luau's Merge
	comment).
]]
local function materializeObject(spawnArea: BasePart, entry: Types.MergeObjectEntry, healthMultiplier: number): BasePart
	local tierDef = Types.tierDefFor(entry.Tier)

	local part = Instance.new("Part")
	part.Name = "MergeObject"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(tierDef.Size, tierDef.Size, tierDef.Size)
	part.Color = tierDef.Color
	part:SetAttribute("Tier", entry.Tier)

	local yOffset = spawnArea.Size.Y / 2 + tierDef.Size / 2
	part.CFrame = spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)

	if MergeObjectVisuals.attach(part, Types.sanitizeTier(entry.Tier)) then
		part.Transparency = 1
		part.CastShadow = false
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "IncomeLabel"
	-- Scale in world-space studs, not fixed screen pixels. The entire readout
	-- now follows the same camera perspective as its squishy instead of looking
	-- proportionally huge at a distance and tiny up close.
	local statusWidth = math.clamp(tierDef.Size * 1.25, 3, 8)
	local statusHeight = statusWidth * (52 / 116)
	billboard.Size = UDim2.fromScale(statusWidth, statusHeight)
	billboard.StudsOffset = Vector3.new(0, tierDef.Size / 2 + 0.85, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = part

	-- The permanent label is the player-facing tier number
	-- (2 ^ (model level - 1)), not income. Floating "+$X" popups separately
	-- display the rebirth-adjusted money earned by this model.
	local incomeText = Instance.new("TextLabel")
	incomeText.Name = "IncomeText"
	incomeText.AnchorPoint = Vector2.new(0.5, 1)
	incomeText.Position = UDim2.fromScale(0.5, 1)
	incomeText.Size = UDim2.fromScale(80 / 116, 24 / 52)
	incomeText.BackgroundTransparency = 1
	incomeText.Font = Enum.Font.FredokaOne
	incomeText.TextScaled = true
	incomeText.TextColor3 = Color3.fromRGB(255, 248, 231)
	incomeText.TextStrokeColor3 = Color3.fromRGB(58, 38, 31)
	incomeText.TextStrokeTransparency = 0.15
	incomeText.Text = Format.FormatNumber(RebirthConfig.tierNumberForModelLevel(entry.Tier))
	incomeText.Parent = billboard

	StatusUI.createHealthBar(part, billboard, entry.Tier, entry.Health, healthMultiplier)
	StatusUI.createLaunchCooldownCounter(part, billboard)

	return part
end

--[[
	Rejection-sampling search for a free spot on `spawnArea`, inset by
	PAD_MARGIN + the new object's own half-size, rejecting any candidate
	closer than (both half-sizes + MIN_GAP) to an already-placed object.
	Returns nil, nil if MAX_PLACEMENT_ATTEMPTS all land on an occupied spot,
	or if `tierDef` is too large to fit the pad at all.
]]
function Spawning.findOpenSpot(
	spawnArea: BasePart,
	tierDef: MergeConfig.TierDef,
	existing: { [BasePart]: Types.MergeObjectEntry }
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
			local otherHalf = Types.tierDefFor(entry.Tier).Size / 2
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

local function sanitizePurchasedBalance(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, MergeConfig.MAX_PURCHASED_SQUISHIES_REMAINING)
end

-- Canonical merge counts for the board as it exists before paid units are
-- added. Every equal pair below maxModelLevel carries into the next level;
-- duplicates AT the cap intentionally remain separate because rebirth owns
-- that progression gate.
local function compactExistingCounts(existing: { Types.MergeObjectEntry }, maxModelLevel: number): { number }
	local counts = table.create(maxModelLevel, 0)
	for _, entry in existing do
		local level = math.min(Types.sanitizeTier(entry.Tier), maxModelLevel)
		counts[level] += 1
	end

	for level = 1, maxModelLevel - 1 do
		local merged = math.floor(counts[level] / 2)
		counts[level] %= 2
		counts[level + 1] += merged
	end
	return counts
end

local function countSetBits(value: number): number
	local remaining = math.floor(value)
	local count = 0
	while remaining > 0 do
		count += remaining % 2
		remaining = math.floor(remaining / 2)
	end
	return count
end

-- Largest integer <= value whose binary representation contains at most
-- maxBits ones. Keeping the highest allowed set bits is optimal: replacing
-- any one of them with lower bits can only make the represented value
-- smaller. These bits correspond one-for-one with merge results below the
-- rebirth cap.
local function largestWithAtMostSetBits(value: number, maxBits: number, highestBit: number): number
	if value <= 0 or maxBits <= 0 then
		return 0
	end
	if countSetBits(value) <= maxBits then
		return value
	end

	local result = 0
	local kept = 0
	for bit = highestBit, 0, -1 do
		local weight = 2 ^ bit
		if math.floor(value / weight) % 2 == 1 then
			if kept >= maxBits then
				break
			end
			result += weight
			kept += 1
		end
	end
	return result
end

-- Computes the maximum number of raw purchased units that can be consumed
-- without the canonical final board exceeding maxSpawns. A unit is worth one
-- object at spawnLevel. Above that level, binary place values exactly model
-- repeated pair-merges; maxModelLevel acts as the top place, where duplicate
-- objects stop carrying and each consumes its own slot.
local function buildFinalLevelCounts(
	existing: { Types.MergeObjectEntry },
	pending: number,
	spawnLevel: number,
	maxModelLevel: number,
	maxSpawns: number
): ({ number }?, number)
	local counts = compactExistingCounts(existing, maxModelLevel)
	local lowerObjectCount = 0
	for level = 1, spawnLevel - 1 do
		lowerObjectCount += counts[level]
	end

	local upperSlots = maxSpawns - lowerObjectCount
	if upperSlots < 0 then
		return nil, 0
	end

	local unitsPerCappedObject = 2 ^ (maxModelLevel - spawnLevel)
	local existingUpperUnits = 0
	for level = spawnLevel, maxModelLevel do
		existingUpperUnits += counts[level] * 2 ^ (level - spawnLevel)
	end

	local maximumUpperUnits = upperSlots * unitsPerCappedObject
	if existingUpperUnits > maximumUpperUnits then
		-- The existing capped board is already above the upgraded capacity
		-- (possible only for the deadlock escape valve or old/corrupt data).
		-- Never delete an owned object just to make a paid delivery fit.
		return nil, 0
	end

	local upperLimit = math.min(existingUpperUnits + pending, maximumUpperUnits)
	local cappedObjects = math.floor(upperLimit / unitsPerCappedObject)
	local remainder = upperLimit % unitsPerCappedObject
	local finalUpperUnits: number

	if cappedObjects >= upperSlots then
		-- Any remainder would need at least one additional object. Filling all
		-- available slots with capped objects is the largest legal value.
		finalUpperUnits = upperSlots * unitsPerCappedObject
	else
		local remainderSlots = upperSlots - cappedObjects
		local legalRemainder = largestWithAtMostSetBits(remainder, remainderSlots, maxModelLevel - spawnLevel - 1)
		finalUpperUnits = cappedObjects * unitsPerCappedObject + legalRemainder
	end

	local consumed = math.floor(finalUpperUnits - existingUpperUnits)
	if consumed <= 0 then
		return nil, 0
	end

	for level = spawnLevel, maxModelLevel do
		counts[level] = 0
	end
	counts[maxModelLevel] = math.floor(finalUpperUnits / unitsPerCappedObject)
	local finalRemainder = finalUpperUnits % unitsPerCappedObject
	for bit = 0, maxModelLevel - spawnLevel - 1 do
		if math.floor(finalRemainder / (2 ^ bit)) % 2 == 1 then
			counts[spawnLevel + bit] = 1
		end
	end

	return counts, math.min(consumed, pending)
end

local function preservedHealthByLevel(
	existing: { Types.MergeObjectEntry },
	maxModelLevel: number,
	healthMultiplier: number
): { [number]: { number } }
	local healthByLevel: { [number]: { number } } = {}
	for _, entry in existing do
		local level = math.min(Types.sanitizeTier(entry.Tier), maxModelLevel)
		local queue = healthByLevel[level]
		if queue == nil then
			queue = {}
			healthByLevel[level] = queue
		end
		table.insert(queue, Types.sanitizeHealth(entry.Health, level, healthMultiplier))
	end
	return healthByLevel
end

local function findOpenSpotAmongEntries(
	spawnArea: BasePart,
	tierDef: MergeConfig.TierDef,
	existing: { Types.MergeObjectEntry },
	attempts: number
): (number?, number?)
	local halfSize = tierDef.Size / 2
	local rangeX = spawnArea.Size.X / 2 - MergeConfig.PAD_MARGIN - halfSize
	local rangeZ = spawnArea.Size.Z / 2 - MergeConfig.PAD_MARGIN - halfSize
	if rangeX <= 0 or rangeZ <= 0 then
		return nil, nil
	end

	for _ = 1, attempts do
		local x = (random:NextNumber() * 2 - 1) * rangeX
		local z = (random:NextNumber() * 2 - 1) * rangeZ
		local fits = true
		for _, entry in existing do
			local otherHalf = Types.tierDefFor(entry.Tier).Size / 2
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

local function entriesFromRandomPlacement(spawnArea: BasePart, drafts: { SquishyDraft }): { Types.MergeObjectEntry }?
	local entries: { Types.MergeObjectEntry } = {}
	for _, draft in drafts do
		local x, z = findOpenSpotAmongEntries(spawnArea, Types.tierDefFor(draft.Tier), entries, 250)
		if x == nil or z == nil then
			return nil
		end
		table.insert(entries, {
			Tier = draft.Tier,
			X = math.round(x * 100) / 100,
			Z = math.round(z * 100) / 100,
			Health = draft.Health,
		})
	end
	return entries
end

-- Guaranteed fallback for the current 70x70 pads and 15-object ceiling. The
-- paid rebuild normally preserves the game's free-placement look through the
-- random planner above; this centered lattice exists solely so a legitimate
-- receipt can never be stranded because rejection sampling got unlucky.
local function entriesFromFallbackLattice(spawnArea: BasePart, drafts: { SquishyDraft }): { Types.MergeObjectEntry }?
	local count = #drafts
	if count == 0 then
		return {}
	end

	local columns = math.ceil(math.sqrt(count))
	local rows = math.ceil(count / columns)
	local maximumSize = 0
	for _, draft in drafts do
		maximumSize = math.max(maximumSize, Types.tierDefFor(draft.Tier).Size)
	end
	local step = maximumSize + MergeConfig.MIN_GAP
	local requiredWidth = maximumSize + (columns - 1) * step
	local requiredDepth = maximumSize + (rows - 1) * step
	local usableWidth = spawnArea.Size.X - 2 * MergeConfig.PAD_MARGIN
	local usableDepth = spawnArea.Size.Z - 2 * MergeConfig.PAD_MARGIN
	if requiredWidth > usableWidth or requiredDepth > usableDepth then
		return nil
	end

	local entries: { Types.MergeObjectEntry } = table.create(count)
	for index, draft in drafts do
		local row = math.floor((index - 1) / columns)
		local column = (index - 1) % columns
		local rowCount = math.min(columns, count - row * columns)
		local x = (column - (rowCount - 1) / 2) * step
		local z = (row - (rows - 1) / 2) * step
		table.insert(entries, {
			Tier = draft.Tier,
			X = math.round(x * 100) / 100,
			Z = math.round(z * 100) / 100,
			Health = draft.Health,
		})
	end
	return entries
end

local function planCompactedEntries(
	data: DataService.PlayerData,
	live: Types.LiveBase,
	pending: number
): ({ Types.MergeObjectEntry }?, number)
	local maxModelLevel = RebirthConfig.maxModelLevel(data.Rebirths)
	local spawnLevel = math.min(Types.sanitizeTier(data.Merge.SpawnLevel), maxModelLevel)
	local maxSpawns = math.min(UpgradeConfig.readValue(data, "MaxSpawns"), MergeConfig.MAX_OBJECTS)
	local finalCounts, consumed =
		buildFinalLevelCounts(data.Merge.Squishies, pending, spawnLevel, maxModelLevel, maxSpawns)
	if finalCounts == nil or consumed <= 0 then
		return nil, 0
	end

	local healthMultiplier = MergeConfig.sanitizeSquishyHealthMultiplier(data.Merge.SquishyHealthMultiplier)
	local healthQueues = preservedHealthByLevel(data.Merge.Squishies, maxModelLevel, healthMultiplier)
	local healthIndexes: { [number]: number } = {}
	local drafts: { SquishyDraft } = {}
	-- Largest first makes random packing substantially more reliable. It has
	-- no gameplay effect; all entries are committed in one transaction.
	for level = maxModelLevel, 1, -1 do
		for _ = 1, finalCounts[level] do
			local queue = healthQueues[level]
			local nextIndex = (healthIndexes[level] or 0) + 1
			healthIndexes[level] = nextIndex
			local preservedHealth = if queue ~= nil then queue[nextIndex] else nil
			table.insert(drafts, {
				Tier = level,
				Health = preservedHealth or MergeConfig.maxHealthForTier(level, healthMultiplier),
			})
		end
	end

	local entries = entriesFromRandomPlacement(live.spawnArea, drafts)
	if entries == nil then
		entries = entriesFromFallbackLattice(live.spawnArea, drafts)
	end
	return entries, consumed
end

-- Same polling wait as PlaytimeRewardsService/FriendRewardService/etc:
-- DataService.getData(player) returns nil until that player's ProfileStore
-- session finishes loading (async, started from DataService.Start()).
local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

--[[
	Puts `part` back to being a plain resting object at `entry`'s persisted
	pad-local spot -- the exact CFrame math materializeObject uses, so a
	re-anchored object sits identically to one that was never picked up.
	Used by every carry-cancel path (drop, character removing, pad
	deactivation); those paths never destroy and recreate the part, only
	this.
]]
function Spawning.reAnchorPart(live: Types.LiveBase, part: BasePart, entry: Types.MergeObjectEntry)
	if part.Parent == nil then
		return -- already destroyed (e.g. the pad's folder was torn down first)
	end

	local tierDef = Types.tierDefFor(entry.Tier)
	local yOffset = live.spawnArea.Size.Y / 2 + tierDef.Size / 2
	-- Split the object from its former carry assembly before restoring the
	-- resting transform. Setting CFrame while it is still unanchored can move
	-- it to the right position but let the physics assembly keep the player's
	-- carried rotation for the rest of that frame.
	part.Anchored = true
	part.CFrame = live.spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)
	part.Massless = false
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = true
end

--[[
	Marks `part` not-yet-pickup-eligible, with a fresh (zero) continuous-
	outside accumulator. Called by every path that places a resting part
	somewhere the owning player could otherwise instantly re-grab it
	(dropCarried, cancelCarry, commitMerge's result) -- see the
	LiveBase.disarmed field comment and MergeConfig.REARM_OUTSIDE_SECONDS for
	the re-arm rule that eventually clears it.
]]
function Spawning.markDisarmed(live: Types.LiveBase, part: BasePart)
	live.disarmed[part] = 0
end

local function publishCarryingAttributes(player: Player, tier: number, part: BasePart)
	player:SetAttribute("CarryingTier", tier)
	local readyAt = part:GetAttribute("LaunchReadyAt")
	player:SetAttribute("CarryingLaunchReadyAt", if typeof(readyAt) == "number" then readyAt else nil)
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
	local activeLaunch = activeLaunches[player]
	if activeLaunch ~= nil and activeLaunch.part == part then
		return -- only the projectile itself is unavailable while it is flying
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

	local tierDef = Types.tierDefFor(entry.Tier)
	local offset = tierDef.Size / 2 + MergeConfig.CARRY_GAP
	local carryRotation = MergeObjectVisuals.getCarryRotation(Types.sanitizeTier(entry.Tier))
	part.CFrame = attachPoint.CFrame * CFrame.new(0, 0, -offset) * carryRotation
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = attachPoint
	weld.Part1 = part
	weld.Parent = part

	carries[player] = { live = live, part = part, entry = entry, weld = weld }
	publishCarryingAttributes(player, entry.Tier, part)
end

--[[
	Server-side pickup detection: .Touched on the resting Part itself. See the
	init.luau header's PHASE 2 note for why Touched (not a heartbeat scan) is
	the right tool here -- a moving character walking into a stationary,
	anchored, non-collide Part is the textbook reliable case for it.
]]
local function wirePickupTouched(player: Player, live: Types.LiveBase, part: BasePart)
	part.Touched:Connect(function(hit: BasePart)
		if liveBases[player] ~= live then
			return -- pad no longer live for this player; part is on its way out
		end
		if part:GetAttribute("AutoMerging") == true then
			return -- reserved by the server-owned Auto Merge tween
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
	or produced by a merge (Carry.commitMerge). Centralising it here is what
	guarantees pickup detection is wired onto every one of them without each
	call site remembering to do it itself.
]]
function Spawning.spawnRestingPart(player: Player, live: Types.LiveBase, entry: Types.MergeObjectEntry): BasePart
	local data = DataService.getData(player)
	local healthMultiplier = if data ~= nil then data.Merge.SquishyHealthMultiplier else 1
	local part = materializeObject(live.spawnArea, entry, healthMultiplier)
	part.Parent = live.objectsFolder
	live.parts[part] = entry
	wirePickupTouched(player, live, part)
	return part
end

local function notifyWaitingBalance(player: Player, remaining: number)
	UINotificationService.SendNotification(
		player,
		"Info",
		`Your base is full! You still have {Format.FormatNumber(remaining)} purchased Squishies waiting to be delivered.`
	)
end

-- Rebuilds the complete board only when at least one raw paid unit can be
-- consumed. The persisted Squishies array and remaining balance change in a
-- single replica transaction; clients therefore never observe compacted
-- models without the matching balance deduction (or vice versa).
function Spawning.processPurchasedSquishies(player: Player, notifyProgress: boolean?): (number, number)
	if player.Parent ~= Players then
		return 0, 0
	end

	local data = DataService.getData(player)
	if data == nil then
		return 0, 0
	end
	local pending = sanitizePurchasedBalance(data.Merge.PurchasedSquishiesRemaining)
	if pending <= 0 then
		return 0, 0
	end

	local live = liveBases[player]
	if live == nil or live.objectsFolder.Parent == nil then
		return 0, pending
	end

	local plannedEntries, consumed = planCompactedEntries(data, live, pending)
	if plannedEntries == nil or consumed <= 0 then
		return 0, pending
	end

	-- The user explicitly chose this behavior for a purchase arriving during
	-- carry/launch. Returning the source first also means its persisted entry
	-- participates in the same authoritative compaction as every other model.
	onDeactivate(player)
	if liveBases[player] ~= live or live.objectsFolder.Parent == nil then
		return 0, pending
	end

	local remaining = pending - consumed
	DataService.setValues(player, { "Merge" }, {
		Squishies = plannedEntries,
		PurchasedSquishiesRemaining = remaining,
	})

	-- Clear transient Parts/VFX only after the data commit. All new Parts use
	-- the exact entry tables now stored in profile data, preserving the
	-- identity invariant used by carry, damage, and auto merge.
	live.objectsFolder:ClearAllChildren()
	table.clear(live.parts)
	table.clear(live.disarmed)
	live.deadlockStreak = 0
	for _, entry in data.Merge.Squishies do
		Spawning.spawnRestingPart(player, live, entry)
	end

	if notifyProgress == true then
		if remaining > 0 then
			UINotificationService.SendNotification(
				player,
				"Info",
				`Your purchase was partially delivered. You still have {Format.FormatNumber(remaining)} purchased Squishies waiting for space.`
			)
		else
			UINotificationService.SendNotification(
				player,
				"Success",
				"All your purchased Squishies have been delivered!"
			)
		end
	end

	return consumed, remaining
end

-- Receipt entry point. Crediting the durable balance is itself the reward:
-- lack of a live base or free slot never rejects an already-paid receipt.
-- The later processing pass can therefore safely happen now, on rejoin, or
-- after any future capacity change without losing the purchase.
function Spawning.addPurchasedSquishies(player: Player, amount: number): boolean
	if
		type(amount) ~= "number"
		or amount ~= amount
		or amount == math.huge
		or amount == -math.huge
		or amount <= 0
		or amount % 1 ~= 0
	then
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	-- First use any space that may already exist. This also avoids rejecting
	-- a legitimate purchase merely because an extremely large old balance is
	-- sitting near the defensive persistence ceiling.
	Spawning.processPurchasedSquishies(player, false)
	data = DataService.getData(player)
	if data == nil then
		return false
	end
	local current = sanitizePurchasedBalance(data.Merge.PurchasedSquishiesRemaining)
	if amount > MergeConfig.MAX_PURCHASED_SQUISHIES_REMAINING - current then
		log.warn(`paid Squishy balance overflow prevented for {player.Name}`)
		return false
	end

	-- A purchase arrival always releases a carried/launched object before the
	-- paid board rebuild. If no unit can fit, the source is simply restored to
	-- its saved location and the whole amount remains safely queued.
	if liveBases[player] ~= nil then
		onDeactivate(player)
	end
	DataService.set(player, { "Merge", "PurchasedSquishiesRemaining" }, current + amount)

	local _, remaining = Spawning.processPurchasedSquishies(player, false)
	if remaining > 0 then
		notifyWaitingBalance(player, remaining)
	end
	return true
end

function Spawning.processAllPurchasedSquishies()
	for player in liveBases do
		Spawning.processPurchasedSquishies(player, true)
	end
end

--[[
	Deadlock escape valve for a full pad. Called only from trySpawnObject's
	board-full branch below, exactly where auto-spawn would otherwise just
	wait forever: merging requires exact tier equality (Carry.tryMergeCarry)
	and is blocked outright at this player's rebirth cap
	(RebirthConfig.maxModelLevel), so a full board of pairwise-distinct,
	all-mergeable tiers has no legal pair, no free slot to auto-spawn into,
	and no rebirth available (RebirthConfig.bestModelLevel has not reached the
	cap -- checked explicitly below, since rebirth is the intended way out
	whenever it IS available) -- a hard softlock with no player-initiated way
	out.

	Fires as soon as the SAME stuck shape has been observed for
	MergeConfig.DEADLOCK_RESCUE_TICKS consecutive auto-spawn ticks
	(live.deadlockStreak). Threshold is 1 -- the predicate below is exact, not
	a heuristic (tallied fresh from live persisted data at fire time, and a
	legal pair reappearing anywhere on the board resets the streak before this
	fires), so there is nothing for a repeat observation to confirm; a
	genuine deadlock could never resolve itself, by definition nothing on
	this pad CAN merge while the conditions below all hold. The streak
	counter itself stays live (rather than collapsing to a plain boolean)
	because it still guards trySpawnObject's retry-without-reconfirm path
	when findOpenSpot fails below.

	`live.deadlockStreak` lives on the LiveBase itself, not a per-player
	module table -- deactivateBase (base change, player leaving) discards the
	whole `live` table, taking the counter with it for free. See
	trySpawnObject for where it gets reset to 0 on every non-full tick.
]]
local function tryDeadlockRescue(player: Player, live: Types.LiveBase, data: DataService.PlayerData)
	local maxModelLevel = RebirthConfig.maxModelLevel(data.Rebirths)

	-- Rebirth guard: this player's best on-board model level already reached
	-- the cap, so rebirth -- not a free rescue spawn -- is the intended way
	-- off this board. Deliberately checked against the BEST entry, not "are
	-- all entries capped": a mixed board (say {1..9} plus two duplicates
	-- already at the cap) has no mergeable pair either, but rebirth is just
	-- as available there, and must win the same way.
	if RebirthConfig.bestModelLevel(data.Merge.Squishies) >= maxModelLevel then
		live.deadlockStreak = 0
		return
	end

	-- Tally counts per tier among MERGEABLE entries only. A capped-tier
	-- duplicate can never merge (Carry.tryMergeCarry's own mergeLocked
	-- check), so it must not count as a legal pair here -- and rescuing INTO
	-- a capped tier would just recreate an equally unmergeable duplicate.
	local mergeableCounts: { [number]: number } = {}
	local lowestMergeableTier: number? = nil
	for _, entry in data.Merge.Squishies do
		if entry.Tier < maxModelLevel then
			mergeableCounts[entry.Tier] = (mergeableCounts[entry.Tier] or 0) + 1
			if lowestMergeableTier == nil or entry.Tier < lowestMergeableTier then
				lowestMergeableTier = entry.Tier
			end
		end
	end

	if lowestMergeableTier == nil then
		-- Every entry is already at/above this player's rebirth cap. This is
		-- NOT the softlock this exists for -- rebirth is the intended, and
		-- available, way forward, so do not short-circuit it with a free spawn.
		live.deadlockStreak = 0
		return
	end

	for _, count in mergeableCounts do
		if count >= 2 then
			-- A legal pair exists somewhere on the board. Carry's own
			-- Heartbeat merge check owns resolving it; this pad isn't stuck.
			live.deadlockStreak = 0
			return
		end
	end

	-- True deadlock on THIS tick: full board, no legal pair among mergeable
	-- tiers, at least one mergeable singleton. At threshold 1 this fires the
	-- rescue below immediately -- see this function's header for why no
	-- confirmation repeat is needed.
	live.deadlockStreak += 1
	if live.deadlockStreak < MergeConfig.DEADLOCK_RESCUE_TICKS then
		return
	end

	-- Same normal-spawn-path shape as trySpawnObject below (findOpenSpot ->
	-- entry -> tableInsert -> spawnRestingPart), deliberately skipping only
	-- the MaxSpawns gate that sent us here. Targets the LOWEST mergeable
	-- singleton so the player's cheapest stuck object clears the deadlock,
	-- not an arbitrary one. Sanitized lookup, same idiom as
	-- materializeObject/pickUp (Types.luau's own tierDefFor/sanitizeTier
	-- note): lowestMergeableTier came off a persisted entry, and a corrupted
	-- value must not reach a raw MergeConfig.Tiers index -- a nil tierDef
	-- would throw inside runAutoSpawnLoop, which is not pcall-wrapped,
	-- killing auto-spawn for the rest of the session.
	local sanitizedTier = Types.sanitizeTier(lowestMergeableTier)
	local tierDef = Types.tierDefFor(lowestMergeableTier)
	local x, z = Spawning.findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x == nil or z == nil then
		-- No room even for the rescue -- skip and retry next tick rather
		-- than forcing an overlapping placement. Streak is left at/above
		-- threshold on purpose: the deadlock has not resolved, so the very
		-- next tick should retry the spawn immediately, not wait for a fresh
		-- confirmation window.
		return
	end

	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100
	local entry: Types.MergeObjectEntry = {
		Tier = sanitizedTier,
		X = roundedX,
		Z = roundedZ,
		Health = MergeConfig.maxHealthForTier(sanitizedTier, data.Merge.SquishyHealthMultiplier),
	}

	if DataService.tableInsert(player, { "Merge", "Squishies" }, entry) == nil then
		return
	end
	Spawning.spawnRestingPart(player, live, entry)

	-- The board now holds a fresh legal pair at `lowestMergeableTier` (this
	-- rescue IS its second copy), so the very next tick's scan above would
	-- reset this to 0 on its own -- reset here too rather than leaving a
	-- rescue that just fired reading as "still stuck" for even one tick.
	live.deadlockStreak = 0
	UINotificationService.SendNotification(player, "Info", MergeConfig.DEADLOCK_RESCUE_MESSAGE)
end

function Spawning.trySpawnObject(player: Player, live: Types.LiveBase)
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	local maxSpawns = UpgradeConfig.readValue(data, "MaxSpawns")
	if #data.Merge.Squishies >= maxSpawns then
		-- Pad full: normally auto-spawn just waits, but a board of pairwise-
		-- distinct mergeable tiers can get permanently stuck here (no legal
		-- pair, no free slot, no rebirth reachable) -- see
		-- tryDeadlockRescue's header for the softlock this escapes.
		tryDeadlockRescue(player, live, data)
		return
	end
	-- Board has room again -- any prior deadlock streak no longer describes
	-- this board and must not carry over into a future, unrelated full-board
	-- tick.
	live.deadlockStreak = 0

	local tier = math.min(Types.sanitizeTier(data.Merge.SpawnLevel), RebirthConfig.maxModelLevel(data.Rebirths))
	local tierDef = MergeConfig.Tiers[tier]

	local x, z = Spawning.findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x == nil or z == nil then
		-- Crowded-but-under-cap: skip this tick, try again next one.
		return
	end

	-- Rounded to ~2 decimals at write time (spec) so saved coordinates don't
	-- accumulate float noise across sessions.
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100

	local entry: Types.MergeObjectEntry = {
		Tier = tier,
		X = roundedX,
		Z = roundedZ,
		Health = MergeConfig.maxHealthForTier(tier, data.Merge.SquishyHealthMultiplier),
	}

	-- Append incrementally: auto-spawn runs every few seconds, so replacing the
	-- entire growing array here would turn one small entry into O(n) replicated
	-- payload over the life of every pad.
	if DataService.tableInsert(player, { "Merge", "Squishies" }, entry) == nil then
		return
	end

	Spawning.spawnRestingPart(player, live, entry)
end

local function runAutoSpawnLoop(player: Player, live: Types.LiveBase)
	-- `liveBases[player] == live` (identity, not just non-nil) is what makes
	-- this loop exit both on the player leaving/releasing the base AND on a
	-- later re-activation replacing this LiveBase with a new one -- either
	-- way, this exact loop's job is done.
	local progress = 0
	local sampledAt = os.clock()
	while player.Parent == Players and liveBases[player] == live do
		task.wait(0.1)
		local now = os.clock()
		local elapsed = now - sampledAt
		sampledAt = now
		local spawnRateMultiplier = if player:GetAttribute("SpawnRateMultiplier") == 2 then 2 else 1
		progress += elapsed * spawnRateMultiplier
		if liveBases[player] ~= live then
			break
		end
		if progress < MergeConfig.SPAWN_INTERVAL then
			continue
		end
		progress = 0
		Spawning.trySpawnObject(player, live)
	end
end

function Spawning.deactivateBase(player: Player)
	-- Bumped unconditionally, even if no pad is live yet, so an
	-- activateBase() still waiting on waitForData/materializing for this
	-- player sees its token invalidated the instant release happens.
	activationTokens[player] = (activationTokens[player] or 0) + 1

	-- Before the objectsFolder (and therefore the carried Part) disappears --
	-- see Carry.cancelCarry's own header note on why this is safe either way.
	onDeactivate(player)

	local live = liveBases[player]
	if live == nil then
		return
	end
	liveBases[player] = nil
	-- Destroys every MergeObject Part and its BillboardGui child in one call.
	live.objectsFolder:Destroy()
end

function Spawning.activateBase(player: Player, baseName: string)
	local existing = liveBases[player]
	if existing ~= nil then
		if existing.baseName == baseName then
			return -- already live on this exact base -- nothing to do
		end
		-- Not expected given BaseService's claim/release contract (a base
		-- change always clears the attribute first), but never assume a
		-- second system's invariant from here -- release the stale pad first.
		Spawning.deactivateBase(player)
	end

	local record = Assets.getBase(baseName)
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
			-- see the init.luau header's ACTIVATION IS ASYNC note.
			return
		end

		local folder = Instance.new("Folder")
		folder.Name = "MergeObjects"
		folder.Parent = record.part

		local live: Types.LiveBase = {
			baseName = baseName,
			spawnArea = record.spawnArea,
			objectsFolder = folder,
			parts = {},
			disarmed = {},
			deadlockStreak = 0,
		}
		-- Set BEFORE the restore loop below: spawnRestingPart's Touched wiring
		-- closes over `live` and checks `liveBases[player] == live` on every
		-- fire, so it must already be published before any part exists to be
		-- touched.
		liveBases[player] = live

		-- Capped at MAX_OBJECTS + 1, not MAX_OBJECTS: a compliant writer can
		-- legitimately reach MAX_OBJECTS + 1 today, because tryDeadlockRescue
		-- deliberately bypasses the MaxSpawns gate to append its one escape-
		-- valve squishy onto an already-full (<= MAX_OBJECTS) board. Capping
		-- at MAX_OBJECTS here would silently leave that legitimate 16th entry
		-- out of `parts`/the objectsFolder while it stayed in
		-- data.Merge.Squishies -- a data-only entry with no Part, still
		-- counted by MaxSpawns (so spawning stays blocked) and still read as
		-- "a legal pair exists" by tryDeadlockRescue's own scan, but with
		-- nothing to actually merge: a worse softlock than the one that
		-- rescue exists to fix. The +1 is still a hard ceiling, not an
		-- invitation -- profile data remains attacker-influenced over a long
		-- enough time horizon (dev console, a future migration bug), and a
		-- planted oversized array must not materialize hundreds of Parts.
		local restoreCount = math.min(#data.Merge.Squishies, MergeConfig.MAX_OBJECTS + 1)
		for i = 1, restoreCount do
			Spawning.spawnRestingPart(player, live, data.Merge.Squishies[i])
		end

		-- Rejoining/reactivating a base is a delivery opportunity. The balance
		-- was restored with the profile above and is reinterpreted using the
		-- player's progression NOW, never the SpawnLevel at purchase time.
		local delivered, remaining = Spawning.processPurchasedSquishies(player, true)
		if delivered == 0 and remaining > 0 then
			notifyWaitingBalance(player, remaining)
		end

		runAutoSpawnLoop(player, live)
	end)
end

return Spawning
