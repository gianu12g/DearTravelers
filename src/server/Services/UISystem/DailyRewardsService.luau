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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DailyRewardFunctions = require(ServerStorage.Modules.UISystem.DailyRewardFunctions)
local DailyRewardsConfig = require(ReplicatedStorage.Shared.UISystem.Config.DailyRewards)
local DataService = require(ServerStorage.Services.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("DailyRewardsService")

local STALE_SESSION_SECONDS = 2 * 24 * 60 * 60
local CLAIM_INTERVAL_SECONDS = 24 * 60 * 60

-- See PlaytimeRewardsService.luau's identical comment: ClaimedRewards
-- defaults to {} in TEMPLATE, which needs this cast to read as a map under
-- --!strict; StartTimestamp is a plain number either way.
type DailyRewardsData = {
	StartTimestamp: number,
	ClaimedRewards: { [number]: boolean },
}

local function waitForData(player: Player): DataService.PlayerData?
	local data = DataService.getData(player)
	while data == nil and player.Parent == Players do
		task.wait(0.25)
		data = DataService.getData(player)
	end
	return data
end

local function resetIfStale(player: Player, data: DataService.PlayerData)
	local now = os.time()
	if now - data.UISystem.LastSessionTime > STALE_SESSION_SECONDS then
		DataService.set(player, { "UISystem", "DailyRewards" }, { StartTimestamp = now, ClaimedRewards = {} })
	end
end

local DailyRewardsService = {}

function DailyRewardsService.Init()
	Net.dailyClaim.listen(function(data, player)
		if player == nil then
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
		-- Persisted before the reward runs -- fine while rewardFunction is a
		-- stub, but a real payout that errors would be forfeited. Decide
		-- grant-then-mark vs gating this write on reward success when
		-- DailyRewardFunctions.luau stops being stubs.
		DataService.set(player, { "UISystem", "DailyRewards", "ClaimedRewards" }, claimed)

		local ok = pcall(rewardFunction, player)
		if not ok then
			log.warn(`reward function for daily index {index} errored for {player.Name}`)
		end

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
