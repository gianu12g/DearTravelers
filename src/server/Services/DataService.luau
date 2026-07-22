--!strict
--[[
	ProfileStore (persistence) + Replica (replication).

	The split, in one line each:
	  ProfileStore  = the disk. Survives rejoins. Nobody but the server sees it.
	  Replica       = the wire. Pushes profile.Data to the owning client only.

	The trick that makes this simple: Replica.New{ Data = profile.Data } does NOT
	copy the table -- the replica holds a reference to the SAME table. So one
	`replica:Set(...)` call mutates the profile AND replicates. There is no
	"write it twice and hope they stay in sync" problem, because there is only
	one table.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local EconomyConfig = require(ServerStorage.Modules.EconomyConfig)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local ProfileStore = require(ServerStorage.ServerPackages.ProfileStore)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Replica = require(ServerStorage.ReplicaServer)
local SquishyProgress = require(ServerStorage.Modules.SquishyProgress)

local log = Log.new("DataService")

--[[
	The template. Adding a field here is the entire workflow for new data --
	it persists, it replicates, and Reconcile() backfills it onto existing
	profiles automatically.

	Version drives migrations. Bump it on any breaking shape change.
	Reconcile() only ADDS missing keys -- it cannot rename, reshape or split.
	Without a Version already saved in every profile, you cannot tell "old
	shape" from "new shape with defaults", and you are left choosing between a
	data wipe and a permanent hack. It costs one integer. Do it now.

	WARNING (from Replica's own docs): no gaps in numeric tables, and no keys
	that aren't strings or numbers. Those cannot be replicated.
]]
local DATA_VERSION = 4
local MAX_PROCESSED_PURCHASE_IDS = 200

local TEMPLATE = {
	Version = DATA_VERSION,
	Coins = 0,
	Level = 1,
	Experience = 0,
	-- Nested tables are fine -- this is the whole reason Replica exists.
	Inventory = {} :: { [string]: number },
	Settings = {
		MusicEnabled = true,
	},

	--[[
		Merge-gameplay loop. Squishies is a COMPACT array -- no gaps,
		ever -- because Replica cannot replicate a sparse numeric table
		(this file's own WARNING above); a future removal must table.remove
		it, never write nil into the middle. X/Z are PAD-LOCAL coordinates
		(object space of the owning base's SpawnArea part, not world space),
		so they stay valid across server restarts and even a base being
		physically moved in Studio -- discovered bases can each sit at a different
		world rotation, and pad-local coordinates are the only representation
		that doesn't have to know which one a given player owns.

		The entry shape ({Tier, X, Z, Health}) is written out here rather than
		requiring Shared.MergeConfig for a type: DataService stays generic on
		purpose (see the Spins field below, same reasoning) and this shape is
		small enough not to need a shared type to stay in sync.
	]]
	Merge = {
		Squishies = {} :: { { Tier: number, X: number, Z: number, Health: number } },
		SpawnLevel = 1,
		-- Trusted server time used to calculate the next offline-income grant.
		LastActiveAt = 0,
		-- The latest grant receipt is persisted/replicated so the joining
		-- client can reliably show it even if data arrives late.
		OfflineEarnings = { Amount = 0, Seconds = 0, AwardedAt = 0 },
	},

	--[[
		Ported UISystem feature set (PORT-SPEC.md §2). Namespaced under one
		key so it never collides with existing fields. No `Cash` field here:
		the source's Cash maps onto the EXISTING top-level `Coins` above --
		CoinsService already owns currency, so UI reads Coins directly and
		formats it with Shared.UISystem.Format.FormatNumber. The source
		template also had three dead `Unlocked` fields (PlaytimeRewards,
		DailyRewards, FriendsReward) that nothing ever read; dropped.
	]]
	UISystem = {
		GiftedPasses = {},
		Packs = {},
		PlaytimeRewards = {
			StartTimestamp = 0,
			StartPlaytime = 0,
			ClaimedRewards = { false, false, false, false, false, false, false },
		},
		DailyRewards = {
			StartTimestamp = 0,
			ClaimedRewards = { false, false, false, false, false, false, false },
		},
		FriendsReward = { JoinedFriends = {}, Claimed = false },
		GroupReward = false,
		-- Config.WheelSpin.StartingSpins, hardcoded rather than required in:
		-- TEMPLATE is a static literal everywhere else in this file, and a
		-- cross-require into UISystem config from the generic DataService
		-- would be the only one here.
		Spins = 1,
		RedeemedCodes = {},
		LastSessionTime = 0,
		Playtime = 0,
		Settings = { Music = 0.1, SFX = 0.9, Keyboard = 1 },
		-- A bounded idempotency ledger for developer-product receipts. Entries
		-- are appended before a receipt is acknowledged and are only considered
		-- durable after Profile:Save() has completed successfully.
		ProcessedPurchaseIds = {} :: { string },
		-- Gift intent is persisted before opening Roblox's purchase prompt. A
		-- receipt may arrive after a teleport, reconnect, or server shutdown, so
		-- an in-memory cache is not sufficient to identify its recipient.
		PendingGift = { Kind = "", ItemName = "", TargetUserId = 0, ProductId = 0 },
	},
}

export type PlayerData = typeof(TEMPLATE)

-- Index N migrates version N -> N+1. Never delete or renumber one.
local MIGRATIONS: { (data: any) -> () } = {
	[0] = function(_data)
		-- Version was introduced before any breaking shape change. Explicitly
		-- retain the historical 0 -> 1 no-op so migration-chain validation can
		-- distinguish intent from a deployment that accidentally omits a step.
	end,
	[1] = function(data)
		-- Objects was the original internal name for the player's collected
		-- merge items. Preserve every existing entry while adopting the
		-- player-facing Squishies terminology.
		local merge = if type(data.Merge) == "table" then data.Merge else {}
		if merge.Squishies == nil then
			merge.Squishies = merge.Objects or {}
		end
		merge.Objects = nil
		data.Merge = merge
	end,
	[2] = function(data)
		-- ClaimedRewards used to be treated as a sparse numeric dictionary.
		-- Replica numeric tables must be compact, so normalize both reward tracks
		-- into dense boolean arrays while preserving every existing claim.
		local uiSystem = if type(data.UISystem) == "table" then data.UISystem else {}

		local function denseClaims(container: any, count: number): { boolean }
			local old = if type(container) == "table" and type(container.ClaimedRewards) == "table"
				then container.ClaimedRewards
				else {}
			local dense = table.create(count, false)
			for i = 1, count do
				dense[i] = old[i] == true or old[tostring(i)] == true
			end
			return dense
		end

		if type(uiSystem.DailyRewards) ~= "table" then
			uiSystem.DailyRewards = { StartTimestamp = 0, ClaimedRewards = {} }
		end
		if type(uiSystem.PlaytimeRewards) ~= "table" then
			uiSystem.PlaytimeRewards = { StartTimestamp = 0, StartPlaytime = 0, ClaimedRewards = {} }
		end
		uiSystem.DailyRewards.ClaimedRewards = denseClaims(uiSystem.DailyRewards, 7)
		uiSystem.PlaytimeRewards.ClaimedRewards = denseClaims(uiSystem.PlaytimeRewards, 7)
		uiSystem.ProcessedPurchaseIds = uiSystem.ProcessedPurchaseIds or {}
		uiSystem.PendingGift = uiSystem.PendingGift or { Kind = "", ItemName = "", TargetUserId = 0, ProductId = 0 }
		data.UISystem = uiSystem
	end,
	[3] = function(data)
		-- Reconcile cannot add keys inside entries of a numeric array. Existing
		-- squishies therefore need their initial full-health value written by an
		-- explicit migration; repairProfileData below clamps malformed values.
		local merge = if type(data.Merge) == "table" then data.Merge else {}
		local squishies = if type(merge.Squishies) == "table" then merge.Squishies else {}
		for _, entry in squishies do
			if type(entry) == "table" and entry.Health == nil then
				entry.Health = MergeConfig.healthForTier(entry.Tier)
			end
		end
		merge.Squishies = squishies
		data.Merge = merge
	end,
}

local LIVE_PROFILE_STORE_NAME = "PlayerData_v1.1"
-- Studio writes to a separate DataStore, so persistence can be tested across
-- Play sessions without ever touching production player profiles.
local STUDIO_PROFILE_STORE_NAME = "PlayerData_v1.1_Studio"
local PROFILE_STORE_NAME = if RunService:IsStudio() then STUDIO_PROFILE_STORE_NAME else LIVE_PROFILE_STORE_NAME

local DataService = {
	-- Loads before anything that reads player data.
	Priority = 100,
}

-- One token per replica kind. Replica.Token errors if you create the same
-- string twice, so it lives at module scope, not inside a function.
local PLAYER_DATA_TOKEN = Replica.Token("PlayerData")

-- ProfileStore automatically falls back to an in-memory mock when Studio API
-- access is unavailable. When access is enabled, the isolated Studio store
-- above persists normally across Play sessions.
local store = ProfileStore.New(PROFILE_STORE_NAME, TEMPLATE)

local profiles: { [Player]: any } = {}
local replicas: { [Player]: any } = {}
local readyConnections: { [Player]: any } = {}
local loading: { [Player]: true } = {}
local dataWaiters: { [Player]: { thread } } = {}

export type ProfileMessageHandler = (player: Player, message: { [string]: any }) -> boolean
local messageHandlers: { [string]: ProfileMessageHandler } = {}
local warnedUnknownMessageKinds: { [string]: true } = {}
local warnedMalformedMessage = false

local function resumeDataWaiters(player: Player, loaded: boolean)
	local waiters = dataWaiters[player]
	if waiters == nil then
		return
	end
	dataWaiters[player] = nil
	for _, waiter in waiters do
		task.spawn(waiter, loaded)
	end
end

local function disconnectReadyConnection(player: Player)
	local connection = readyConnections[player]
	if connection ~= nil then
		readyConnections[player] = nil
		connection:Disconnect()
	end
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end
	return copy
end

-- Reconcile handles missing string keys but intentionally preserves values of
-- the wrong type. Repair those container/scalar mismatches before any service
-- is allowed to consume the profile.
local function repairTypes(data: any, template: any)
	for key, templateValue in template do
		local value = data[key]
		if value == nil or type(value) ~= type(templateValue) then
			data[key] = deepCopy(templateValue)
		elseif type(templateValue) == "table" and next(templateValue) ~= nil then
			repairTypes(value, templateValue)
		end
	end
end

local function compactStringArray(value: any, maxEntries: number): { string }
	local compact: { string } = {}
	local seen: { [string]: true } = {}
	if type(value) ~= "table" then
		return compact
	end
	for _, item in value do
		if type(item) == "string" and #item > 0 and #item <= 128 and not seen[item] then
			seen[item] = true
			table.insert(compact, item)
		end
	end
	if #compact > maxEntries then
		local newest = table.create(maxEntries)
		for index = #compact - maxEntries + 1, #compact do
			table.insert(newest, compact[index])
		end
		return newest
	end
	return compact
end

local function denseBooleanArray(value: any, count: number): { boolean }
	local dense = table.create(count, false)
	if type(value) ~= "table" then
		return dense
	end
	for index = 1, count do
		dense[index] = value[index] == true or value[tostring(index)] == true
	end
	return dense
end

local function compactUserIds(value: any, maxEntries: number): { number }
	local compact: { number } = {}
	local seen: { [number]: true } = {}
	if type(value) ~= "table" then
		return compact
	end
	for _, userId in value do
		if
			type(userId) == "number"
			and userId == math.floor(userId)
			and userId > 0
			and userId < math.huge
			and not seen[userId]
		then
			seen[userId] = true
			table.insert(compact, userId)
			if #compact >= maxEntries then
				break
			end
		end
	end
	return compact
end

local function finiteInteger(value: any, minimum: number, maximum: number, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(math.floor(value), minimum, maximum)
end

local function finiteNumber(value: any, minimum: number, maximum: number, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(value, minimum, maximum)
end

local function repairProfileData(data: any)
	repairTypes(data, TEMPLATE)

	local uiSystem = data.UISystem
	uiSystem.ProcessedPurchaseIds = compactStringArray(uiSystem.ProcessedPurchaseIds, MAX_PROCESSED_PURCHASE_IDS)
	uiSystem.Packs = compactStringArray(uiSystem.Packs, 100)
	uiSystem.RedeemedCodes = compactStringArray(uiSystem.RedeemedCodes, 500)
	uiSystem.PlaytimeRewards.ClaimedRewards = denseBooleanArray(uiSystem.PlaytimeRewards.ClaimedRewards, 7)
	uiSystem.DailyRewards.ClaimedRewards = denseBooleanArray(uiSystem.DailyRewards.ClaimedRewards, 7)
	uiSystem.FriendsReward.JoinedFriends = compactUserIds(uiSystem.FriendsReward.JoinedFriends, 200)

	local giftedPasses = {}
	for passName, owned in uiSystem.GiftedPasses do
		if type(passName) == "string" and #passName > 0 and #passName <= 64 and owned == true then
			giftedPasses[passName] = true
		end
	end
	uiSystem.GiftedPasses = giftedPasses

	local pendingGift = uiSystem.PendingGift
	local emptyIntent = pendingGift.Kind == ""
		and pendingGift.ItemName == ""
		and pendingGift.TargetUserId == 0
		and pendingGift.ProductId == 0
	local validIntent = (pendingGift.Kind == "Pass" or pendingGift.Kind == "Product")
		and #pendingGift.ItemName > 0
		and #pendingGift.ItemName <= 64
		and pendingGift.TargetUserId > 0
		and pendingGift.TargetUserId < math.huge
		and pendingGift.TargetUserId == math.floor(pendingGift.TargetUserId)
		and pendingGift.ProductId > 0
		and pendingGift.ProductId < math.huge
		and pendingGift.ProductId == math.floor(pendingGift.ProductId)
	if not emptyIntent and not validIntent then
		uiSystem.PendingGift = { Kind = "", ItemName = "", TargetUserId = 0, ProductId = 0 }
	end

	data.Coins = finiteInteger(data.Coins, 0, EconomyConfig.MAX_COINS, 0)
	data.Level, data.Experience = Progression.resolve(data.Level, data.Experience, 0)
	data.Merge.SpawnLevel = finiteInteger(data.Merge.SpawnLevel, 1, MergeConfig.MAX_TIER, 1)
	data.Merge.LastActiveAt = finiteInteger(data.Merge.LastActiveAt, 0, 2 ^ 53 - 1, 0)
	data.Merge.OfflineEarnings.Amount = finiteInteger(data.Merge.OfflineEarnings.Amount, 0, EconomyConfig.MAX_GRANT, 0)
	data.Merge.OfflineEarnings.Seconds =
		finiteInteger(data.Merge.OfflineEarnings.Seconds, 0, MergeConfig.MAX_OFFLINE_SECONDS, 0)
	data.Merge.OfflineEarnings.AwardedAt = finiteInteger(data.Merge.OfflineEarnings.AwardedAt, 0, 2 ^ 53 - 1, 0)
	uiSystem.Spins = finiteInteger(uiSystem.Spins, 0, 1e9, 0)
	uiSystem.Playtime = finiteInteger(uiSystem.Playtime, 0, 2 ^ 53 - 1, 0)
	uiSystem.LastSessionTime = finiteInteger(uiSystem.LastSessionTime, 0, 2 ^ 53 - 1, 0)
	uiSystem.PlaytimeRewards.StartTimestamp = finiteInteger(uiSystem.PlaytimeRewards.StartTimestamp, 0, 2 ^ 53 - 1, 0)
	uiSystem.PlaytimeRewards.StartPlaytime = finiteInteger(uiSystem.PlaytimeRewards.StartPlaytime, 0, 2 ^ 53 - 1, 0)
	uiSystem.DailyRewards.StartTimestamp = finiteInteger(uiSystem.DailyRewards.StartTimestamp, 0, 2 ^ 53 - 1, 0)
	local settings = {}
	for settingName, fallback in TEMPLATE.UISystem.Settings do
		local settingValue = uiSystem.Settings[settingName]
		settings[settingName] = if type(settingValue) == "number"
				and settingValue == settingValue
				and settingValue ~= math.huge
				and settingValue ~= -math.huge
			then math.clamp(settingValue, 0, 1)
			else fallback
	end
	uiSystem.Settings = settings
	data.Settings = { MusicEnabled = data.Settings.MusicEnabled == true }

	local inventory = {}
	for key, count in data.Inventory do
		if
			type(key) == "string"
			and #key > 0
			and #key <= 64
			and type(count) == "number"
			and count == count
			and count > 0
			and count < math.huge
		then
			inventory[key] = math.min(math.floor(count), 1e12)
		end
	end
	data.Inventory = inventory

	local compactSquishies = {}
	for _, entry in data.Merge.Squishies do
		if #compactSquishies >= MergeConfig.MAX_OBJECTS then
			break
		end
		if type(entry) ~= "table" then
			continue
		end
		local tier, x, z, health = entry.Tier, entry.X, entry.Z, entry.Health
		if
			type(tier) ~= "number"
			or tier ~= tier
			or type(x) ~= "number"
			or x ~= x
			or type(z) ~= "number"
			or z ~= z
			or math.abs(x) == math.huge
			or math.abs(z) == math.huge
		then
			continue
		end
		local safeTier = math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
		local maxHealth = MergeConfig.healthForTier(safeTier)
		local safeHealth = finiteNumber(health, 0, maxHealth, maxHealth)
		-- A zero-health squishy was already dead when its prior server closed.
		-- Do not resurrect it on join; live deaths provide their pop effect in
		-- MergeService before being removed from this same persisted array.
		if safeHealth <= 0 then
			continue
		end
		table.insert(compactSquishies, {
			Tier = safeTier,
			X = math.clamp(x, -1000, 1000),
			Z = math.clamp(z, -1000, 1000),
			-- Fractional health is intentional: 25% of a 2-HP squishy is 0.5,
			-- and flooring that would make the test action deal 50% instead.
			Health = safeHealth,
		})
	end
	data.Merge.Squishies = compactSquishies
end

local function runMigrations(data: any)
	local from = if data.Version == nil then 0 else data.Version
	if type(from) ~= "number" or from ~= math.floor(from) or from < 0 then
		error(`invalid profile version {tostring(from)}`)
	end
	if from > DATA_VERSION then
		error(`profile version {from} is newer than this server's version {DATA_VERSION}`)
	end
	for version = from, DATA_VERSION - 1 do
		local migrate = MIGRATIONS[version]
		if migrate == nil then
			error(`missing profile migration {version} -> {version + 1}`)
		end
		migrate(data)
	end
	data.Version = DATA_VERSION
end

local function onPlayerAdded(player: Player)
	if profiles[player] ~= nil or loading[player] then
		return
	end
	loading[player] = true

	local profile = store:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		loading[player] = nil
		resumeDataWaiters(player, false)
		player:Kick("Data failed to load. Please rejoin.")
		return
	end

	local originalData = deepCopy(profile.Data)
	local prepared, prepareError = pcall(function()
		profile:AddUserId(player.UserId) -- GDPR compliance
		local candidate = deepCopy(profile.Data)
		runMigrations(candidate)
		profile.Data = candidate
		profile:Reconcile()
		repairProfileData(profile.Data)
	end)
	if not prepared then
		-- EndSession saves active profiles. Restore the last known-good data so
		-- a failed migration can never persist its own partial mutations.
		profile.Data = originalData
		loading[player] = nil
		resumeDataWaiters(player, false)
		log.error(`profile preparation failed for {player.Name}: {tostring(prepareError)}`)
		profile:EndSession()
		player:Kick("Your data could not be prepared safely. Please rejoin.")
		return
	end

	-- This runs before profiles[player] and Replica exist, making the offline
	-- payout part of the atomic initial state delivered to the client.
	local offlineEarnings, offlineSeconds = SquishyProgress.applySessionStart(profile.Data, os.time())
	if offlineEarnings > 0 then
		log.info(`{player.Name}'s squishies earned {offlineEarnings} coins over {offlineSeconds}s offline`)
	end

	profile.OnSessionEnd:Connect(function()
		loading[player] = nil
		disconnectReadyConnection(player)
		resumeDataWaiters(player, false)
		profiles[player] = nil
		if replicas[player] ~= nil then
			-- No LastSessionTime write here: this branch fires only on a stolen session, so this server no longer owns the profile to persist it -- onPlayerRemoving writes it; the stealing server writes its own.
			replicas[player]:Destroy()
			replicas[player] = nil
		end
		if player.Parent == Players then
			player:Kick("Data session ended. Please rejoin.")
		end
	end)

	if player.Parent ~= Players then
		loading[player] = nil
		resumeDataWaiters(player, false)
		profile:EndSession()
		return
	end

	profiles[player] = profile

	--[[
		Create the replica. Note `Data = profile.Data` -- same table, not a copy.
		Tags are immutable identifiers set once at creation; they ride along to
		the client so it can tell whose replica this is.
	]]
	local replica = Replica.New({
		-- Replica.Token() returns the correct object at runtime. ReplicaServer's
		-- bundled annotation mistakenly asks for its internal token class instead
		-- of the returned token instance, so keep this compatibility cast local.
		Token = PLAYER_DATA_TOKEN :: any,
		Tags = { UserId = player.UserId },
		Data = profile.Data,
	})
	replicas[player] = replica
	loading[player] = nil
	resumeDataWaiters(player, true)

	profile:MessageHandler(function(message: any, processed: () -> ())
		if type(message) ~= "table" or type(message.Kind) ~= "string" then
			if not warnedMalformedMessage then
				warnedMalformedMessage = true
				log.warn(`discarding malformed profile message for {player.Name}; further warnings suppressed`)
			end
			processed()
			return
		end
		local handler = messageHandlers[message.Kind]
		if handler == nil then
			-- Keep unknown messages queued so a temporarily missing feature can
			-- process them after the next deployment instead of losing them.
			if not warnedUnknownMessageKinds[message.Kind] then
				warnedUnknownMessageKinds[message.Kind] = true
				log.warn(`no profile-message handler registered for kind "{message.Kind}"; further warnings suppressed`)
			end
			return
		end
		local ok, handled = pcall(handler, player, message)
		if ok and handled then
			processed()
			-- Persist the reward and removal from the durable message queue
			-- promptly; otherwise both wait for the next five-minute autosave.
			profile:Save()
		elseif not ok then
			log.warn(`profile-message handler "{message.Kind}" errored for {player.Name}: {tostring(handled)}`)
		end
	end)

	--[[
		Subscribe = "send this replica to this one player". This is what makes
		the data PRIVATE -- no other client ever receives it. (Replicate() would
		send it to everyone; that's not what we want for player data.)

		GOTCHA: you cannot Subscribe a player who isn't "ready" yet -- ready
		means their client has called Replica.RequestData(). Subscribing early
		is a no-op plus a warning, and the player silently gets no data. So
		check ReadyPlayers first, and wait on NewReadyPlayer if they aren't.
	]]
	if Replica.ReadyPlayers[player] then
		replica:Subscribe(player)
	else
		local connection
		connection = Replica.NewReadyPlayer:Connect(function(readyPlayer: Player)
			if readyPlayer ~= player then
				return
			end
			connection:Disconnect()
			readyConnections[player] = nil
			if replicas[player] == replica and replica:IsActive() then
				replica:Subscribe(player)
			end
		end)
		readyConnections[player] = connection
	end

	log.info(`loaded profile for {player.Name}`)
end

local function onPlayerRemoving(player: Player)
	loading[player] = nil
	disconnectReadyConnection(player)
	resumeDataWaiters(player, false)
	local replica = replicas[player]
	if replica ~= nil then
		local now = os.time()
		-- Session-end timestamp (PORT-SPEC.md §2). Same call DataService.set
		-- makes internally -- done here directly, before Destroy(), since
		-- there is nothing left to write through afterwards.
		replica:Set({ "UISystem", "LastSessionTime" }, now)
		replica:Set({ "Merge", "LastActiveAt" }, now)
		replica:Destroy()
		replicas[player] = nil
	end

	local profile = profiles[player]
	if profile ~= nil then
		profile:EndSession()
		profiles[player] = nil
	end
end

function DataService.Start()
	if RunService:IsStudio() then
		task.spawn(function()
			while ProfileStore.DataStoreState == "NotReady" do
				task.wait()
			end

			if ProfileStore.DataStoreState == "Access" then
				log.info(`Studio persistence enabled in isolated store {STUDIO_PROFILE_STORE_NAME}`)
			else
				log.warn(
					"Studio persistence is using memory only. Publish the experience and enable Game Settings > Security > Enable Studio Access to API Services."
				)
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			-- onPlayerRemoving has a yield-free mutation/release prefix. Run it
			-- synchronously so our final timestamps are present before this close
			-- callback returns and ProfileStore finishes its own shutdown saves.
			onPlayerRemoving(player)
		end
	end)
end

-- One readiness primitive for every service. This replaces per-service polling
-- loops and returns false if the player leaves or the timeout expires.
function DataService.awaitData(player: Player, timeout: number?): boolean
	if profiles[player] ~= nil then
		return true
	end
	if player.Parent ~= Players then
		return false
	end

	local waiter = coroutine.running()
	local waiters = dataWaiters[player]
	if waiters == nil then
		waiters = {}
		dataWaiters[player] = waiters
	end
	table.insert(waiters, waiter)

	if timeout ~= nil then
		task.delay(timeout, function()
			local current = dataWaiters[player]
			if current == nil then
				return
			end
			local index = table.find(current, waiter)
			if index ~= nil then
				table.remove(current, index)
				if #current == 0 then
					dataWaiters[player] = nil
				end
				task.spawn(waiter, false)
			end
		end)
	end

	return coroutine.yield()
end

-- Requests an immediate ProfileStore save and waits until a successful saved
-- snapshot satisfies `verify`. Receipt processing uses this to ensure both the
-- reward and PurchaseId are durable before acknowledging Robux.
function DataService.saveAndAwait(player: Player, verify: (savedData: any) -> boolean, timeout: number?): boolean
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return false
	end
	if verify(profile.LastSavedData) then
		return true
	end

	local waiter = coroutine.running()
	local finished = false
	local connection
	connection = profile.OnAfterSave:Connect(function(savedData: any)
		if finished or not verify(savedData) then
			return
		end
		finished = true
		connection:Disconnect()
		if coroutine.status(waiter) == "suspended" then
			task.spawn(waiter, true)
		end
	end)

	profile:Save()
	-- ProfileStore normally saves asynchronously, but this check also makes
	-- the helper safe if a mock implementation fires OnAfterSave inline.
	if finished then
		return true
	end
	task.delay(timeout or 30, function()
		if finished then
			return
		end
		finished = true
		connection:Disconnect()
		if coroutine.status(waiter) == "suspended" then
			task.spawn(waiter, false)
		end
	end)

	return coroutine.yield()
end

function DataService.messagePlayer(userId: number, message: { [string]: any }): boolean
	local ok, sent = pcall(function()
		return store:MessageAsync(tostring(userId), message)
	end)
	if not ok then
		log.warn(`failed to enqueue profile message for userId {userId}: {tostring(sent)}`)
		return false
	end
	return sent == true
end

function DataService.registerMessageHandler(kind: string, handler: ProfileMessageHandler)
	if messageHandlers[kind] ~= nil then
		error(`profile-message handler "{kind}" already registered`, 2)
	end
	messageHandlers[kind] = handler
end

--[[
	THE WRITE PATH. Every mutation goes through a replica setter -- never touch
	profile.Data directly. A raw `profile.Data.Coins = 5` mutates the table but
	sends nothing, so the client silently drifts out of sync. The setters are
	the only thing that both mutate and replicate.

	`path` is a key branch into Data: {"Settings", "MusicEnabled"}.
]]
function DataService.set(player: Player, path: { string | number }, value: any)
	local replica = replicas[player]
	if replica == nil or not replica:IsActive() then
		log.warn(`set() on {player.Name} with no active replica -- dropped`)
		return
	end
	replica:Set(path, value)
end

-- Batch sibling keys under one path in a single replication packet.
function DataService.setValues(player: Player, path: { string | number }, values: { [string]: any })
	local replica = replicas[player]
	if replica == nil or not replica:IsActive() then
		log.warn(`setValues() on {player.Name} with no active replica -- dropped`)
		return
	end
	replica:SetValues(path, values)
end

-- Compact arrays can append without retransmitting every existing element.
-- Multi-element transactions (such as a merge replacing two entries with
-- one) should still use set() once so clients never observe a half-commit.
function DataService.tableInsert(player: Player, path: { string }, value: any): number?
	local replica = replicas[player]
	if replica == nil or not replica:IsActive() then
		log.warn(`tableInsert() on {player.Name} with no active replica -- dropped`)
		return nil
	end
	return replica:TableInsert(path, value)
end

function DataService.getData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

function DataService.getReplica(player: Player): any?
	return replicas[player]
end

return DataService
