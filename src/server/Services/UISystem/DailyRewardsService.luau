--!strict
--[[
	Daily login-reward track (PORT-SPEC.md §1, source
	ServerScriptService.Services.DailyRewardsService). Progress resets if the
	player's previous session ended more than 2 days ago; each claim
	re-validates elapsed time against the track's StartTimestamp rather than
	trusting the client's claimed index.

	State lives at profile path {"UISystem", "DailyRewards"}; Replica
	replicates it to the owning client automatically via DataService.set, so
	the source's dedicated `_DailyRewards` Replication entity (server/
	INDEX.md §3) is not ported -- there is nothing left for it to do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DailyRewardFunctions = require(ServerStorage.Modules.UISystem.DailyRewardFunctions)
local DailyRewardsConfig = require(ReplicatedStorage.Shared.UISystem.Config.DailyRewards)
local DataService = require(ServerStorage.Services.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("DailyRewardsService")

local STALE_SESSION_SECONDS = 2 * 24 * 60 * 60
local CLAIM_INTERVAL_SECONDS = 24 * 60 * 60

local function newClaimedRewards(): { boolean }
	return table.create(#DailyRewardsConfig, false)
end

-- See PlaytimeRewardsService.luau's identical comment: ClaimedRewards
-- defaults to {} in TEMPLATE, which needs this cast to read as a map under
-- --!strict; StartTimestamp is a plain number either way.
type DailyRewardsData = {
	StartTimestamp: number,
	ClaimedRewards: { [number]: boolean },
}

local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

local function resetIfStale(player: Player, data: DataService.PlayerData)
	local now = os.time()
	if now - data.UISystem.LastSessionTime > STALE_SESSION_SECONDS then
		DataService.set(
			player,
			{ "UISystem", "DailyRewards" },
			{ StartTimestamp = now, ClaimedRewards = newClaimedRewards() }
		)
	end
end

local DailyRewardsService = {}
local claimLimiter = RateLimiter.new(1, 2)

function DailyRewardsService.Init()
	Net.dailyClaim.listen(function(data, player)
		if player == nil or not claimLimiter:allow(player) then
			return
		end

		local index = data.index
		if typeof(index) ~= "number" or index < 1 or index > #DailyRewardsConfig then
			return
		end

		local rewardFunction = DailyRewardFunctions[index]
		if rewardFunction == nil then
			return
		end

		local playerData = DataService.getData(player)
		if playerData == nil then
			return
		end

		local rewards = (playerData.UISystem.DailyRewards :: any) :: DailyRewardsData
		if rewards.ClaimedRewards[index] then
			return
		end

		local elapsed = os.time() - rewards.StartTimestamp
		if elapsed < (index - 1) * CLAIM_INTERVAL_SECONDS then
			return
		end

		local claimed = table.clone(rewards.ClaimedRewards)
		claimed[index] = true
		local ok, rewarded = pcall(rewardFunction, player)
		if not ok or not rewarded then
			log.warn(`reward function for daily index {index} rejected the claim for {player.Name}`)
			UINotificationService.SendNotification(player, "Error", "This reward is not available yet")
			return
		end

		DataService.set(player, { "UISystem", "DailyRewards", "ClaimedRewards" }, claimed)
		UINotificationService.SendNotification(player, "Success", "Successfully claimed")
	end)
end

function DailyRewardsService.Start()
	SafePlayerAdded(function(player: Player)
		local data = waitForData(player)
		if data == nil then
			return
		end
		resetIfStale(player, data)
	end)

	log.info("ready")
end

return DailyRewardsService
