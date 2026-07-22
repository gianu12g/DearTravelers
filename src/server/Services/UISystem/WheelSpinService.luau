--!strict
--[[
	Weighted spin-wheel gacha (PORT-SPEC.md §1, source
	ServerScriptService.Services.WheelSpinService). Free spins accrue on a
	playtime interval (read from PlaytimeRewardsService.getPlaytime -- the
	live in-memory counter, not the profile's possibly-stale Playtime field,
	see PlaytimeRewardsService.luau's ticking-tradeoff comment); a per-player
	lock blocks a second spin while the first is still "animating"
	server-side (WheelSpinConfig.FullSpinDuration).

	WheelSpinService.AddSpins is a public API other UISystem services call
	directly (ProductRewards, this file's own free-spin loop) --
	ARCHITECTURE.md's "require it directly" over any server bus.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PlaytimeRewardsService = require(ServerStorage.Services.UISystem.PlaytimeRewardsService)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)
local WheelSpinConfig = require(ReplicatedStorage.Shared.UISystem.Config.WheelSpin)
local WheelSpinRewardFunctions = require(ServerStorage.Modules.UISystem.WheelSpinRewardFunctions)

local log = Log.new("WheelSpinService")

local REWARD_RETRIES = 3
local FREE_SPIN_POLL_SECONDS = 5

local random = Random.new()
local spinLimiter = RateLimiter.new(2, 3)

local function rollRewardIndex(): number
	local totalChance = 0
	for _, reward in WheelSpinConfig.Rewards do
		totalChance += reward.Chance
	end

	local roll = random:NextNumber(0, totalChance)
	local current = 0
	for index, reward in WheelSpinConfig.Rewards do
		current += reward.Chance
		if roll <= current then
			return index
		end
	end
	return 1
end

-- Anti-double-spin lock. Released when the delayed payout resolves, not at
-- request time -- the point is to block a SECOND spin while the first is
-- still animating, so releasing early would defeat it. PlayerRemoving still
-- clears it so a leaving player can't hold a permanent phantom lock across
-- profile reloads (moot in-session, but consistent with every other
-- per-player table in this port).
local spinning: { [Player]: true } = {}

local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

local WheelSpinService = {}

--[[
	Grant `amount` extra spins. Public: MonetizationService's ProductRewards
	and this file's own free-spin loop both call in here.
]]
function WheelSpinService.AddSpins(player: Player, amount: number): boolean
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 or amount ~= math.floor(amount) then
		log.warn(`AddSpins() on {player.Name} with an invalid amount -- rejected`)
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	DataService.set(player, { "UISystem", "Spins" }, data.UISystem.Spins + amount)
	return true
end

function WheelSpinService.Init()
	Net.spinRequest.listen(function(_, player)
		if player == nil or not spinLimiter:allow(player) then
			return
		end

		if spinning[player] then
			return
		end

		local data = DataService.getData(player)
		if data == nil then
			return
		end

		if data.UISystem.Spins <= 0 then
			UINotificationService.SendNotification(player, "Error", "You don't have spins")
			return
		end

		spinning[player] = true
		DataService.set(player, { "UISystem", "Spins" }, data.UISystem.Spins - 1)

		local rewardIndex = rollRewardIndex()
		local rewardFunction = WheelSpinRewardFunctions[rewardIndex]
		local rewarded, rewardError = Format.Retry(function()
			if rewardFunction == nil or not rewardFunction(player) then
				error("reward rejected the grant")
			end
			return true
		end, REWARD_RETRIES)
		if not rewarded then
			spinning[player] = nil
			WheelSpinService.AddSpins(player, 1)
			log.warn(`spin reward {rewardIndex} failed for {player.Name}: {tostring(rewardError)}`)
			UINotificationService.SendNotification(player, "Error", "The spin failed; your spin was refunded")
			return
		end

		-- Grant before animating. A player who disconnects during the wheel
		-- animation keeps the result instead of losing both the spin and reward.
		Net.spinResult.sendTo({ rewardIndex = rewardIndex }, player)
		task.delay(WheelSpinConfig.FullSpinDuration, function()
			spinning[player] = nil

			if player.Parent ~= Players then
				return
			end

			local rewardText = WheelSpinConfig.Rewards[rewardIndex].Text
			UINotificationService.SendNotification(player, "Success", `You won {rewardText}`)
		end)
	end)
end

function WheelSpinService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		spinning[player] = nil
	end)

	SafePlayerAdded(function(player: Player)
		local data = waitForData(player)
		if data == nil then
			return
		end

		local interval = WheelSpinConfig.FreeSpinInterval
		local initialPlaytime = PlaytimeRewardsService.getPlaytime(player) or data.UISystem.Playtime
		local lastInterval = math.floor(initialPlaytime / interval)

		while player.Parent == Players do
			task.wait(FREE_SPIN_POLL_SECONDS)

			local playtime = PlaytimeRewardsService.getPlaytime(player)
			if playtime == nil then
				continue
			end

			local currentInterval = math.floor(playtime / interval)
			if currentInterval > lastInterval then
				local spinsToGive = currentInterval - lastInterval
				lastInterval = currentInterval
				WheelSpinService.AddSpins(player, spinsToGive)
				UINotificationService.SendNotification(player, "Success", `You received {spinsToGive} free spin!`)
			end
		end
	end)

	log.info("ready")
end

return WheelSpinService
