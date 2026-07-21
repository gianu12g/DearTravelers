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

	No remotes in this phase: every decision (what tier, where, how often) is
	made on the server, and Parts replicate to clients automatically.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
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
}

-- Populated once during Start(); read-only afterwards.
local bases: { [string]: BaseRecord } = {}

local liveBases: { [Player]: LiveBase } = {}
local attributeConnections: { [Player]: RBXScriptConnection } = {}
-- See the header's ACTIVATION IS ASYNC note.
local activationTokens: { [Player]: number } = {}

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

	local part = materializeObject(live.spawnArea, entry)
	part.Parent = live.objectsFolder
	live.parts[part] = entry
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

local function deactivateBase(player: Player)
	-- Bumped unconditionally, even if no pad is live yet, so an
	-- activateBase() still waiting on waitForData/materializing for this
	-- player sees its token invalidated the instant release happens.
	activationTokens[player] = (activationTokens[player] or 0) + 1

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

		-- Capped at MAX_OBJECTS even though a compliant writer never exceeds
		-- it: profile data is attacker-influenced over a long enough time
		-- horizon (dev console, a future migration bug), and a planted
		-- oversized array must not materialize hundreds of Parts.
		local restoreCount = math.min(#data.Merge.Objects, MergeConfig.MAX_OBJECTS)
		local parts: { [BasePart]: MergeObjectEntry } = {}
		for i = 1, restoreCount do
			local entry = data.Merge.Objects[i]
			local part = materializeObject(record.spawnArea, entry)
			part.Parent = folder
			parts[part] = entry
		end

		local live: LiveBase = {
			baseName = baseName,
			spawnArea = record.spawnArea,
			objectsFolder = folder,
			parts = parts,
		}
		liveBases[player] = live

		runAutoSpawnLoop(player, live)
	end)
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
end

local function onPlayerRemoving(player: Player)
	local connection = attributeConnections[player]
	if connection ~= nil then
		attributeConnections[player] = nil
		connection:Disconnect()
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

	log.info(`ready ({baseCount} bases)`)
end

return MergeService
