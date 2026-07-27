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

	The Base<number> parts, their NameLabel ownership UI, and their KeyCaps
	folder already exist in Studio -- Rojo does not mount Workspace
	(ARCHITECTURE.md's map), so this service only ever READS them, and it
	resolves the map hierarchy in Start() rather than Init(): Init() must never
	yield. Once the Bases folder is present, its children are discovered in one
	snapshot and malformed bases are logged and left out of rotation.

	ATTRIBUTES: base assignment is public info (every player can already see
	whose name is on a base's NameLabel), so it is fine to publish it as a
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

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local log = Log.new("BaseService")

-- Generous but bounded: a base whose pieces never arrive must not hang
-- Start() (and therefore every player join) forever. Reused as the
-- HumanoidRootPart streaming timeout below for the same reason.
local WAIT_TIMEOUT = 10

-- Studs above the base part's top face a respawned character lands at, so
-- PivotTo drops them onto the base instead of inside it.
local SPAWN_HEIGHT_OFFSET = 5
local DEFAULT_FORCEFIELD_TRANSPARENCY = 0.58
-- Recharge used to be a fixed two minutes. The upgrade launch lowers the
-- baseline to one minute; LockBase itself increases the active duration.
local FORCEFIELD_COOLDOWN_SECONDS = 60
local lockInputLimiter = RateLimiter.new(2, 3)

type BaseRecord = {
	part: BasePart,
	nameLabel: BillboardGui,
	nameText: TextLabel,
	ownerAvatar: ImageLabel?,
	-- Captured from Studio at Start() time and restored on release, rather
	-- than hardcoding a reset string here -- whatever placeholder was
	-- authored on the ownership UI is what "unclaimed" means for this base.
	defaultText: string,
	defaultTextVisible: boolean,
	defaultAvatarImage: string?,
	defaultAvatarVisible: boolean?,
	-- Studio-authored sphere under MapLayout.BaseForcefields. Missing artwork
	-- disables locking for only this base; assignment/spawning still work.
	forcefield: BasePart?,
	activeForcefieldTransparency: number,
}

local bases: { [string]: BaseRecord } = {}
-- Base<number> in numeric claim order, populated once during Start() setup.
local baseOrder: { string } = {}

local assignments: { [string]: Player } = {}
local playerBases: { [Player]: string } = {}
local lockedBases: { [string]: true } = {}
local lockCooldownEnds: { [string]: number } = {}
local lockGenerations: { [string]: number } = {}
-- The CharacterAdded connection driving respawn-to-base for whichever player
-- currently owns a base. Reverse-indexed by Player for the same reason
-- playerBases is: PlayerRemoving only hands us a Player.
local characterConnections: { [Player]: RBXScriptConnection } = {}
local waitingPlayers: { Player } = {}
local queuedPlayers: { [Player]: true } = {}

local BaseService = {}
local onPlayerAdded: (Player) -> ()

local function setForcefieldState(player: Player, baseName: string, locked: boolean): (boolean, string)
	local record = bases[baseName]
	if record == nil then
		return false, "Your base is not ready"
	end

	local forcefield = record.forcefield
	if locked and (forcefield == nil or forcefield.Parent == nil) then
		return false, "This base has no forcefield"
	end

	if locked then
		lockedBases[baseName] = true
	else
		lockedBases[baseName] = nil
	end
	player:SetAttribute("BaseLocked", locked)
	record.part:SetAttribute("ForcefieldActive", locked)
	if forcefield ~= nil and forcefield.Parent ~= nil then
		forcefield:SetAttribute("Active", locked)
		forcefield.Transparency = if locked then record.activeForcefieldTransparency else 1
	end

	return true, if locked then "Base locked" else "Base unlocked"
end

local function invalidateForcefieldCycle(player: Player, baseName: string)
	lockGenerations[baseName] = (lockGenerations[baseName] or 0) + 1
	lockCooldownEnds[baseName] = nil
	player:SetAttribute("BaseLockExpiresAt", nil)
	player:SetAttribute("BaseLockCooldownEndsAt", nil)
end

local function activateForcefield(player: Player, baseName: string): (boolean, string)
	local data = DataService.getData(player)
	if data == nil then
		return false, "Your data is still loading"
	end

	local now = Workspace:GetServerTimeNow()
	local cooldownEndsAt = lockCooldownEnds[baseName] or 0
	if cooldownEndsAt > now then
		local remaining = math.ceil(cooldownEndsAt - now)
		return false, `Forcefield recharging ({remaining}s)`
	end

	local ok, message = setForcefieldState(player, baseName, true)
	if not ok then
		return false, message
	end

	local durationSeconds = UpgradeConfig.lockDurationSeconds(data.Merge.LockBase)
	local generation = (lockGenerations[baseName] or 0) + 1
	local expiresAt = now + durationSeconds
	cooldownEndsAt = expiresAt + FORCEFIELD_COOLDOWN_SECONDS
	lockGenerations[baseName] = generation
	lockCooldownEnds[baseName] = cooldownEndsAt
	player:SetAttribute("BaseLockExpiresAt", expiresAt)
	player:SetAttribute("BaseLockCooldownEndsAt", cooldownEndsAt)

	task.delay(durationSeconds, function()
		if
			lockGenerations[baseName] ~= generation
			or assignments[baseName] ~= player
			or playerBases[player] ~= baseName
		then
			return
		end

		setForcefieldState(player, baseName, false)
		player:SetAttribute("BaseLockExpiresAt", nil)
	end)

	task.delay(durationSeconds + FORCEFIELD_COOLDOWN_SECONDS, function()
		if
			lockGenerations[baseName] ~= generation
			or assignments[baseName] ~= player
			or playerBases[player] ~= baseName
		then
			return
		end

		lockCooldownEnds[baseName] = nil
		player:SetAttribute("BaseLockCooldownEndsAt", nil)
	end)

	local minutes = durationSeconds / 60
	return true, if minutes == 1 then "Forcefield active for 1 minute" else `Forcefield active for {minutes} minutes`
end

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
	invalidateForcefieldCycle(player, baseName)
	setForcefieldState(player, baseName, false)
	playerBases[player] = nil
	assignments[baseName] = nil
	player:SetAttribute("AssignedBase", nil)
	player:SetAttribute("BaseLocked", nil)

	local record = bases[baseName]
	if record ~= nil then
		record.nameLabel.Enabled = false
		record.nameText.Text = record.defaultText
		record.nameText.Visible = record.defaultTextVisible
		local ownerAvatar = record.ownerAvatar
		if ownerAvatar ~= nil then
			ownerAvatar.Image = record.defaultAvatarImage or ""
			ownerAvatar.Visible = record.defaultAvatarVisible == true
		end
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
		record.nameLabel.Enabled = true
		record.nameText.Text = player.DisplayName
		record.nameText.Visible = true
		local ownerAvatar = record.ownerAvatar
		if ownerAvatar ~= nil then
			ownerAvatar.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
			ownerAvatar.Visible = true
		end
		record.part:SetAttribute("OwnerUserId", player.UserId)
		invalidateForcefieldCycle(player, baseName)
		local forcefieldReady = setForcefieldState(player, baseName, false)
		if not forcefieldReady then
			player:SetAttribute("BaseLocked", false)
		end

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

-- The owner whose authored base footprint contains this X/Z point.
-- Transforming through each base CFrame preserves correctness if a base is
-- rotated or moved in Studio later.
function BaseService.getOwnerAtPosition(worldX: number, worldZ: number): Player?
	for baseName, owner in assignments do
		local record = bases[baseName]
		if record == nil then
			continue
		end
		local basePart = record.part
		local localPosition = basePart.CFrame:PointToObjectSpace(Vector3.new(worldX, basePart.Position.Y, worldZ))
		if math.abs(localPosition.X) <= basePart.Size.X / 2 and math.abs(localPosition.Z) <= basePart.Size.Z / 2 then
			return owner
		end
	end
	return nil
end

function BaseService.isForcefieldActive(player: Player): boolean
	local baseName = playerBases[player]
	return baseName ~= nil and lockedBases[baseName] == true
end

-- Resolves the center position where a vertically falling projectile first
-- touches an active upper hemisphere. The forcefields stay CanQuery=false so
-- ordinary map raycasts and character movement ignore them; launch combat
-- performs this authoritative analytic collision instead.
function BaseService.resolveForcefieldImpact(
	worldX: number,
	worldZ: number,
	projectileHalfHeight: number
): (Vector3?, Player?)
	for baseName in lockedBases do
		local owner = assignments[baseName]
		local record = bases[baseName]
		local forcefield = if record ~= nil then record.forcefield else nil
		if owner == nil or forcefield == nil or forcefield.Parent == nil then
			continue
		end

		local radius = math.min(forcefield.Size.X, forcefield.Size.Z) / 2
		local dx = worldX - forcefield.Position.X
		local dz = worldZ - forcefield.Position.Z
		local horizontalDistanceSquared = dx * dx + dz * dz
		if horizontalDistanceSquared <= radius * radius then
			local surfaceOffset = math.sqrt(math.max(0, radius * radius - horizontalDistanceSquared))
			local surfaceY = forcefield.Position.Y + surfaceOffset
			return Vector3.new(worldX, surfaceY + projectileHalfHeight, worldZ), owner
		end
	end
	return nil, nil
end

function BaseService.Init()
	Net.baseLockRequest.listen(function(_data, player)
		if player == nil then
			return
		end

		local baseName = playerBases[player]
		local currentlyLocked = baseName ~= nil and lockedBases[baseName] == true
		if not lockInputLimiter:allow(player) then
			Net.baseLockResult.sendTo(
				{ ok = false, locked = currentlyLocked, message = "Please wait before activating your forcefield" },
				player
			)
			return
		end
		if baseName == nil then
			Net.baseLockResult.sendTo({ ok = false, locked = false, message = "You do not have a base yet" }, player)
			return
		end

		if currentlyLocked then
			Net.baseLockResult.sendTo(
				{ ok = false, locked = true, message = "Your forcefield is already active" },
				player
			)
			return
		end

		local ok, message = activateForcefield(player, baseName)
		Net.baseLockResult.sendTo({ ok = ok, locked = ok, message = message }, player)
	end)
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
	local forcefieldsFolder = mapLayout:FindFirstChild("BaseForcefields")
	if forcefieldsFolder == nil or not forcefieldsFolder:IsA("Folder") then
		log.warn("Workspace.MapLayout.BaseForcefields is missing -- base locking will be unavailable")
		forcefieldsFolder = nil
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
		-- Unclaimed bases never show placeholder ownership UI. SafePlayerAdded
		-- enables the billboard again as part of the synchronous claim state.
		nameLabel.Enabled = false

		local nameTextInstance = nameLabel:FindFirstChild("NameText") or nameLabel:FindFirstChild("BaseOwnerName")
		if nameTextInstance == nil or not nameTextInstance:IsA("TextLabel") then
			log.error(
				`{baseName}.NameLabel needs a NameText or BaseOwnerName TextLabel -- that base will never be assigned`
			)
			continue
		end
		local nameText: TextLabel = nameTextInstance
		local ownerAvatarInstance = nameLabel:FindFirstChild("BaseOwnerAvatar")
		local ownerAvatar: ImageLabel? = nil
		if ownerAvatarInstance ~= nil then
			if ownerAvatarInstance:IsA("ImageLabel") then
				ownerAvatar = ownerAvatarInstance
			else
				log.warn(`{baseName}.NameLabel.BaseOwnerAvatar is not an ImageLabel -- avatar updates disabled`)
			end
		end

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

		local forcefield: BasePart? = nil
		local activeForcefieldTransparency = DEFAULT_FORCEFIELD_TRANSPARENCY
		if forcefieldsFolder ~= nil then
			local forcefieldInstance = forcefieldsFolder:FindFirstChild(baseName .. "Forcefield")
			if forcefieldInstance ~= nil and forcefieldInstance:IsA("BasePart") then
				forcefield = forcefieldInstance
				local configuredTransparency = forcefieldInstance:GetAttribute("ActiveTransparency")
				if typeof(configuredTransparency) == "number" then
					activeForcefieldTransparency = math.clamp(configuredTransparency, 0, 1)
				end
				forcefieldInstance.Anchored = true
				forcefieldInstance.CanCollide = false
				forcefieldInstance.CanTouch = false
				forcefieldInstance.CanQuery = false
				forcefieldInstance:SetAttribute("Active", false)
				forcefieldInstance.Transparency = 1
				basePart:SetAttribute("ForcefieldActive", false)
			else
				log.warn(`BaseForcefields.{baseName}Forcefield is missing or not a BasePart`)
			end
		end

		bases[baseName] = {
			part = basePart,
			nameLabel = nameLabel,
			nameText = nameText,
			ownerAvatar = ownerAvatar,
			defaultText = nameText.Text,
			defaultTextVisible = nameText.Visible,
			defaultAvatarImage = if ownerAvatar ~= nil then ownerAvatar.Image else nil,
			defaultAvatarVisible = if ownerAvatar ~= nil then ownerAvatar.Visible else nil,
			forcefield = forcefield,
			activeForcefieldTransparency = activeForcefieldTransparency,
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
