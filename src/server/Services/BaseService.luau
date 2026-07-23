--!strict
--[[
	Assigns each connecting player a private base out of
	Workspace.MapLayout.Bases (any Base<number> children),
	server-authoritative and race-safe.

	The whole claim happens inside claimBase(): scan `baseOrder` for the
	first entry absent from `assignments`, then write the owner into that
	same table -- no yield sits between "found the free slot" and "wrote the
	owner". Luau has no preemption: a function that never yields cannot be
	interrupted mid-body by anything, including a second PlayerAdded firing
	for a different player in the same frame. That is the entire
	race-safety guarantee; there is no lock to take or release, because
	nothing here ever gives up the thread while the table is inconsistent.

	`assignments` (baseName -> Player) is the source of truth. `playerBases`
	(Player -> baseName) is a reverse index that exists only so
	PlayerRemoving -- which hands us a Player and nothing else -- can find
	and release that player's base in O(1) instead of scanning every base.

	The Base<number> parts, their NameLabel.NameText, and their KeyCaps
	folder already exist in Studio -- Rojo does not mount Workspace
	(ARCHITECTURE.md's map), so this service only ever READS them, and it
	resolves the map hierarchy in Start() rather than Init(): Init() must never
	yield. Once the Bases folder is present, its children are discovered in one
	snapshot and malformed bases are logged and left out of rotation.

	ATTRIBUTES: base assignment is public info (every player can already see
	whose name is on a base's NameText), so it is fine to publish it as a
	plain Attribute instead of routing it through Replica/DataService, which
	exist for a player's own private profile. `player:SetAttribute
	("AssignedBase", ...)` and `basePart:SetAttribute("OwnerUserId", ...)`
	are set together on claim and cleared together on release, same as the
	other half of a claim/release pair below.

	RESPAWN-TO-BASE: once a player owns a base, every character they spawn
	(including one that already exists at claim time) gets PivotTo'd above
	that base's part. The CharacterAdded connection is per-player state
	exactly like playerBases, stored in `characterConnections` and torn down
	in releaseBase alongside the attributes -- so a player who leaves mid-
	spawn (character streaming in, connection still live) cannot leak a
	connection that outlives them. The teleport itself yields (it waits for
	HumanoidRootPart to stream in), which is why it never happens inside
	claimBase/onPlayerAdded's synchronous prefix -- see the race-safety
	paragraph above. It runs strictly after the claim is already committed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)

local log = Log.new("BaseService")

-- Generous but bounded: a base whose pieces never arrive must not hang
-- Start() (and therefore every player join) forever. Reused as the
-- HumanoidRootPart streaming timeout below for the same reason.
local WAIT_TIMEOUT = 10

-- Studs above the base part's top face a respawned character lands at, so
-- PivotTo drops them onto the base instead of inside it.
local SPAWN_HEIGHT_OFFSET = 5

type BaseRecord = {
	part: BasePart,
	nameText: TextLabel,
	-- Captured from Studio at Start() time and restored on release, rather
	-- than hardcoding a reset string here -- whatever placeholder was
	-- authored on NameText is what "unclaimed" means for this base.
	defaultText: string,
}

local bases: { [string]: BaseRecord } = {}
-- Base<number> in numeric claim order, populated once during Start() setup.
local baseOrder: { string } = {}

local assignments: { [string]: Player } = {}
local playerBases: { [Player]: string } = {}
-- The CharacterAdded connection driving respawn-to-base for whichever player
-- currently owns a base. Reverse-indexed by Player for the same reason
-- playerBases is: PlayerRemoving only hands us a Player.
local characterConnections: { [Player]: RBXScriptConnection } = {}
local waitingPlayers: { Player } = {}
local queuedPlayers: { [Player]: true } = {}

local BaseService = {}
local onPlayerAdded: (Player) -> ()

local function updateQueuePositions()
	for position, player in waitingPlayers do
		if player.Parent == Players then
			player:SetAttribute("BaseQueuePosition", position)
		end
	end
end

local function removeFromQueue(player: Player)
	if queuedPlayers[player] == nil then
		return
	end
	queuedPlayers[player] = nil
	player:SetAttribute("BaseQueuePosition", nil)
	local index = table.find(waitingPlayers, player)
	if index ~= nil then
		table.remove(waitingPlayers, index)
		updateQueuePositions()
	end
end

local function queuePlayer(player: Player)
	if queuedPlayers[player] or player.Parent ~= Players then
		return
	end
	queuedPlayers[player] = true
	table.insert(waitingPlayers, player)
	updateQueuePositions()
	log.warn(`queued {player.Name} for a base (position {#waitingPlayers})`)
end

local function popWaitingPlayer(): Player?
	while #waitingPlayers > 0 do
		local player = table.remove(waitingPlayers, 1)
		queuedPlayers[player] = nil
		player:SetAttribute("BaseQueuePosition", nil)
		if player.Parent == Players then
			updateQueuePositions()
			return player
		end
	end
	return nil
end

local function claimBase(player: Player): string?
	for _, baseName in baseOrder do
		if assignments[baseName] == nil then
			assignments[baseName] = player
			playerBases[player] = baseName
			return baseName
		end
	end
	return nil
end

--[[
	Yields: waits for HumanoidRootPart to stream in before PivotTo-ing the
	character. Never call this from claimBase's or onPlayerAdded's
	synchronous prefix -- only after the claim itself is already committed
	(see the header comment's race-safety paragraph).
]]
local function teleportCharacterToBase(character: Model, basePart: BasePart)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil then
		root = character:WaitForChild("HumanoidRootPart", WAIT_TIMEOUT)
	end
	if root == nil or not root:IsA("BasePart") then
		log.warn(`{character:GetFullName()} has no HumanoidRootPart within {WAIT_TIMEOUT}s -- respawn teleport skipped`)
		return
	end

	local halfHeight = basePart.Size.Y / 2
	local targetPosition = basePart.Position + Vector3.new(0, halfHeight + SPAWN_HEIGHT_OFFSET, 0)
	character:PivotTo(CFrame.new(targetPosition))
end

local function releaseBase(player: Player)
	local connection: RBXScriptConnection? = characterConnections[player]
	if connection ~= nil then
		characterConnections[player] = nil
		connection:Disconnect()
	end

	local baseName = playerBases[player]
	if baseName == nil then
		return
	end
	playerBases[player] = nil
	assignments[baseName] = nil
	player:SetAttribute("AssignedBase", nil)

	local record = bases[baseName]
	if record ~= nil then
		record.nameText.Text = record.defaultText
		record.part:SetAttribute("OwnerUserId", nil)
	end

	local waitingPlayer = popWaitingPlayer()
	if waitingPlayer ~= nil then
		onPlayerAdded(waitingPlayer)
	end
end

onPlayerAdded = function(player: Player)
	if player.Parent ~= Players then
		return
	end
	if playerBases[player] ~= nil then
		-- Already holds a base -- nothing to do.
		return
	end

	local baseName = claimBase(player)
	if baseName == nil then
		queuePlayer(player)
		return
	end
	removeFromQueue(player)

	-- Claim is committed above (yield-free). Everything from here on may
	-- yield freely.
	player:SetAttribute("AssignedBase", baseName)

	local record = bases[baseName]
	if record ~= nil then
		record.nameText.Text = player.DisplayName
		record.part:SetAttribute("OwnerUserId", player.UserId)

		characterConnections[player] = player.CharacterAdded:Connect(function(character: Model)
			teleportCharacterToBase(character, record.part)
		end)

		-- A late-joining player (or one whose character streamed in before
		-- this handler ran) already has a Character by now -- teleport it
		-- immediately instead of waiting for their next death.
		local character = player.Character
		if character ~= nil then
			teleportCharacterToBase(character, record.part)
		end
	end

	log.info(`assigned {baseName} to {player.Name}`)
end

local function onPlayerRemoving(player: Player)
	removeFromQueue(player)
	releaseBase(player)
end

--[[
	The base name (e.g. "Base3") the player currently owns, or nil if they
	hold none -- either their data hasn't been assigned yet, or every base
	was taken when they joined.
]]
function BaseService.getBase(player: Player): string?
	return playerBases[player]
end

--[[
	The BasePart the player's base occupies, or nil if they hold none (same
	condition as getBase -- this just hands back the instance instead of its
	name, for callers that need to resolve base-relative children like
	KeyCaps).
]]
function BaseService.getBasePart(player: Player): BasePart?
	local baseName = playerBases[player]
	if baseName == nil then
		return nil
	end
	local record = bases[baseName]
	return if record ~= nil then record.part else nil
end

--[[ The player currently occupying `baseName`, or nil if it is unclaimed. ]]
function BaseService.getOwner(baseName: string): Player?
	return assignments[baseName]
end

function BaseService.Start()
	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- BaseService disabled")
		return
	end

	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- BaseService disabled")
		return
	end

	local discovered: { { index: number, instance: Instance } } = {}
	for _, child in basesFolder:GetChildren() do
		local indexText = string.match(child.Name, "^Base(%d+)$")
		local index = if indexText ~= nil then tonumber(indexText) else nil
		if index ~= nil then
			table.insert(discovered, { index = index, instance = child })
		end
	end
	table.sort(discovered, function(a, b)
		if a.index == b.index then
			return a.instance.Name < b.instance.Name
		end
		return a.index < b.index
	end)

	for _, candidate in discovered do
		local part = candidate.instance
		local baseName = part.Name
		if not part:IsA("BasePart") then
			log.error(`Bases.{baseName} is not a BasePart -- that base will never be assigned`)
			continue
		end
		local basePart: BasePart = part

		local nameLabelInstance = basePart:FindFirstChild("NameLabel")
		if nameLabelInstance == nil or not nameLabelInstance:IsA("BillboardGui") then
			log.error(`{baseName}.NameLabel is missing or not a BillboardGui -- that base will never be assigned`)
			continue
		end
		local nameLabel: BillboardGui = nameLabelInstance

		local nameTextInstance = nameLabel:FindFirstChild("NameText")
		if nameTextInstance == nil or not nameTextInstance:IsA("TextLabel") then
			log.error(`{baseName}.NameLabel.NameText is missing or not a TextLabel -- that base will never be assigned`)
			continue
		end
		local nameText: TextLabel = nameTextInstance

		-- Owned by whatever system populates it, not this one -- existence
		-- is only worth a warning, never a reason to drop the base.
		if basePart:FindFirstChild("KeyCaps") == nil then
			log.warn(`{baseName}.KeyCaps folder is missing`)
		end
		local spawnArea = basePart:FindFirstChild("SpawnArea")
		if spawnArea == nil or not spawnArea:IsA("BasePart") then
			log.error(`{baseName}.SpawnArea is missing or not a BasePart -- that base will never be assigned`)
			continue
		end

		bases[baseName] = {
			part = basePart,
			nameText = nameText,
			defaultText = nameText.Text,
		}
		table.insert(baseOrder, baseName)
	end

	if #baseOrder == 0 then
		log.error("no usable bases found under Workspace.MapLayout.Bases -- BaseService disabled")
		return
	end
	if Players.MaxPlayers > #baseOrder then
		log.warn(
			`server capacity is {Players.MaxPlayers}, but only {#baseOrder} usable bases exist; extra players will queue`
		)
	end

	-- Connected before SafePlayerAdded runs its snapshot loop so that a
	-- present player leaving mid-loop is still handled correctly (a no-op,
	-- since claimBase for them hasn't run yet either).
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	SafePlayerAdded(onPlayerAdded)

	log.info(`ready ({#baseOrder} bases)`)
end

return BaseService
