--!strict
--[[
	Server-authoritative coin upgrade purchases.

	The client chooses only one whitelisted row. This service derives the
	current value, rebirth gate, next value and price from persisted data, then
	charges through CoinsService before committing the upgrade through
	DataService so persistence and Replica stay in sync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(script.Parent.CoinsService)
local DataService = require(script.Parent.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeService = require(script.Parent.MergeService)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local log = Log.new("UpgradesService")

local requestLimiter = RateLimiter.new(4, 6)

local UpgradesService = {}

local function sendResult(player: Player, ok: boolean, upgrade: string, message: string)
	Net.upgradeResult.sendTo({
		ok = ok,
		upgrade = upgrade,
		message = message,
	}, player)
end

local function valueDescription(key: UpgradeConfig.UpgradeKey, value: number): string
	if key == "SpawnTier" then
		return `spawn tier {RebirthConfig.tierNumberForModelLevel(value)}`
	elseif key == "MaxSpawns" then
		return `{value} max spawns`
	else
		return `{UpgradeConfig.lockDurationSeconds(value)} seconds of base lock duration`
	end
end

local function purchase(player: Player, requestedKey: string)
	if not UpgradeConfig.isUpgradeKey(requestedKey) then
		sendResult(player, false, requestedKey, "Unknown upgrade")
		return
	end
	local key = requestedKey :: UpgradeConfig.UpgradeKey

	local data = DataService.getData(player)
	if data == nil then
		sendResult(player, false, key, "Your data is still loading")
		return
	end

	local currentValue = UpgradeConfig.readValue(data, key)
	if key == "SpawnTier" then
		local unlockedMaximum = RebirthConfig.maxModelLevel(data.Rebirths)
		if currentValue >= unlockedMaximum and currentValue < UpgradeConfig.maximumValue(key) then
			sendResult(player, false, key, RebirthConfig.REQUIRES_REBIRTH_MESSAGE)
			return
		end
	end

	local nextValue = UpgradeConfig.nextValue(key, currentValue)
	local cost = UpgradeConfig.costForValue(key, currentValue)
	if nextValue == nil or cost == nil then
		sendResult(player, false, key, "Maximum upgrade reached")
		return
	end

	if not CoinsService.trySpend(player, cost) then
		sendResult(player, false, key, `You need {Format.FormatNumber(cost)} coins`)
		return
	end

	DataService.set(player, UpgradeConfig.pathFor(key), nextValue)
	if key == "MaxSpawns" then
		-- Capacity changed synchronously; do not make a paid balance wait for
		-- the periodic safety sweep before occupying the newly opened slot.
		MergeService.processPurchasedSquishies(player, true)
	end
	local description = valueDescription(key, nextValue)
	log.info(`{player.Name} bought {key} level {UpgradeConfig.levelForValue(key, nextValue)} for {cost} coins`)
	sendResult(player, true, key, `Upgraded to {description}`)
end

function UpgradesService.Init()
	Net.upgradeRequest.listen(function(data, player)
		if player == nil then
			return
		end
		if not requestLimiter:allow(player) then
			local replyKey = if UpgradeConfig.isUpgradeKey(data.upgrade) then data.upgrade else ""
			sendResult(player, false, replyKey, "Please wait before upgrading again")
			return
		end
		purchase(player, data.upgrade)
	end)
end

function UpgradesService.Start()
	log.info("ready")
end

return UpgradesService
