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

local Log = require(ReplicatedStorage.Shared.Log)
local ProfileStore = require(ServerStorage.ServerPackages.ProfileStore)
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
local DATA_VERSION = 2

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
		physically moved in Studio -- the 8 bases each sit at a different
		world rotation, and pad-local coordinates are the only representation
		that doesn't have to know which one a given player owns.

		The entry shape ({Tier, X, Z}) is written out here rather than
		requiring Shared.MergeConfig for a type: DataService stays generic on
		purpose (see the Spins field below, same reasoning) and this shape is
		small enough not to need a shared type to stay in sync.
	]]
	Merge = {
		Squishies = {} :: { { Tier: number, X: number, Z: number } },
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
		PlaytimeRewards = { StartTimestamp = 0, StartPlaytime = 0, ClaimedRewards = {} },
		DailyRewards = { StartTimestamp = 0, ClaimedRewards = {} },
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
	},
}

export type PlayerData = typeof(TEMPLATE)

-- Index N migrates version N -> N+1. Never delete or renumber one.
local MIGRATIONS: { (data: any) -> () } = {
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

local function runMigrations(data: any)
	local from = data.Version or 0
	for version = from, DATA_VERSION - 1 do
		local migrate = MIGRATIONS[version]
		if migrate ~= nil then
			migrate(data)
		end
	end
	data.Version = DATA_VERSION
end

local function onPlayerAdded(player: Player)
	local profile = store:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		player:Kick("Data failed to load. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId) -- GDPR compliance
	runMigrations(profile.Data)
	profile:Reconcile()

	-- This runs before profiles[player] and Replica exist, making the offline
	-- payout part of the atomic initial state delivered to the client.
	local offlineEarnings, offlineSeconds = SquishyProgress.applySessionStart(profile.Data, os.time())
	if offlineEarnings > 0 then
		log.info(`{player.Name}'s squishies earned {offlineEarnings} coins over {offlineSeconds}s offline`)
	end

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		if replicas[player] ~= nil then
			-- No LastSessionTime write here: this branch fires only on a stolen session, so this server no longer owns the profile to persist it -- onPlayerRemoving writes it; the stealing server writes its own.
			replicas[player]:Destroy()
			replicas[player] = nil
		end
		player:Kick("Data session ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
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
			if replicas[player] == replica and replica:IsActive() then
				replica:Subscribe(player)
			end
		end)
	end

	log.info(`loaded profile for {player.Name}`)
end

local function onPlayerRemoving(player: Player)
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
			task.spawn(onPlayerRemoving, player)
		end
	end)
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

function DataService.getData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

function DataService.getReplica(player: Player): any?
	return replicas[player]
end

return DataService
