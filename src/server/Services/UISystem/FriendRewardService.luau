--!strict
--[[
	Friend-invite reward (PORT-SPEC.md §1, source
	ServerScriptService.Services.FriendService, renamed FriendRewardService
	so its domain matches every other file in this folder).

	Source bugs fixed during the port (PORT-SPEC.md §5):
	  1. General.InviteRewardRequiredFriends did not exist in the dumped
	     config and would have errored on first comparison -- added to
	     Shared/UISystem/Config/General.luau (Worker A).
	  2. `Packets.Notification.Prompt:Fire("Success", ...)` fired with no
	     player argument -- every other call site in the source used
	     :FireClient(player, ...); this one was a bug. Now sent to the
	     claiming player only via UINotificationService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local General = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("FriendRewardService")

-- STUB: replace with the real friend-invite reward.
local function grantReward(player: Player): boolean
	log.debug(`granting friend-invite reward to {player.Name} (stub)`)
	return false
end

-- DataService.getData(player) returns nil until this player's ProfileStore
-- session finishes loading (async, started from DataService.Start()). This
-- service needs a loaded profile before it can read/write FriendsReward, so
-- it uses DataService's shared readiness signal rather than creating another
-- per-service polling loop.
local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

-- `data`'s JoinedFriends array is the SAME table DataService.set mutates
-- through (ARCHITECTURE.md: "Data = profile.Data does NOT copy the table"),
-- so re-reading off `data` after a set() call already sees the new value --
-- no need to re-fetch via DataService.getData.
local function registerFriends(a: Player, aData: DataService.PlayerData, b: Player, bData: DataService.PlayerData)
	local aJoined = (aData.UISystem.FriendsReward.JoinedFriends :: any) :: { number }
	if table.find(aJoined, b.UserId) == nil then
		local updated = table.clone(aJoined)
		table.insert(updated, b.UserId)
		DataService.set(a, { "UISystem", "FriendsReward", "JoinedFriends" }, updated)
	end

	local bJoined = (bData.UISystem.FriendsReward.JoinedFriends :: any) :: { number }
	if table.find(bJoined, a.UserId) == nil then
		local updated = table.clone(bJoined)
		table.insert(updated, a.UserId)
		DataService.set(b, { "UISystem", "FriendsReward", "JoinedFriends" }, updated)
	end
end

local FriendRewardService = {}
local claimLimiter = RateLimiter.new(1, 2)

function FriendRewardService.Init()
	Net.friendClaim.listen(function(_, player)
		if player == nil or not claimLimiter:allow(player) then
			return
		end

		local data = DataService.getData(player)
		if data == nil then
			return
		end

		if data.UISystem.FriendsReward.Claimed then
			return
		end

		local joined = (data.UISystem.FriendsReward.JoinedFriends :: any) :: { number }
		if #joined < General.InviteRewardRequiredFriends then
			return
		end

		local ok, rewarded = pcall(grantReward, player)
		if not ok or not rewarded then
			UINotificationService.SendNotification(player, "Error", "This reward is not available yet")
			return
		end
		DataService.set(player, { "UISystem", "FriendsReward", "Claimed" }, true)
		UINotificationService.SendNotification(player, "Success", "Claimed Reward")
	end)
end

function FriendRewardService.Start()
	SafePlayerAdded(function(player: Player)
		local data = waitForData(player)
		if data == nil then
			return
		end

		-- GetFriendsWhoPlayedAsync: ported verbatim from the source dump
		-- (server/INDEX.md, FriendService.luau:34). Not present in the
		-- vendored Roblox type definitions available here, so the cast
		-- below is the only way to compile under --!strict. UNVERIFIED
		-- against a live Studio session (Studio MCP is intentionally not
		-- used for this server-layer pass) -- if this API does not exist,
		-- the pcall fails soft and the friend-invite reward silently never
		-- triggers for anyone. Confirm in Studio before relying on it.
		local friends: { number }? = nil
		local ok = pcall(function()
			friends = (player :: any):GetFriendsWhoPlayedAsync()
		end)
		if not ok or friends == nil then
			return
		end

		for _, other in Players:GetPlayers() do
			if other == player then
				continue
			end
			if table.find(friends :: { number }, other.UserId) == nil then
				continue
			end

			local joined = (data.UISystem.FriendsReward.JoinedFriends :: any) :: { number }
			if table.find(joined, other.UserId) ~= nil then
				continue
			end

			local otherData = DataService.getData(other)
			if otherData == nil then
				continue
			end

			registerFriends(player, data, other, otherData)
		end
	end)

	log.info("ready")
end

return FriendRewardService
