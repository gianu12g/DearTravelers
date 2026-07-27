--!strict
--[[
	Server-authoritative rebirth transaction.

	A client can only ask. Eligibility is derived from persisted squishies and
	the current rebirth count. A successful transaction removes every model,
	resets Coins and the base's spawn model level, and increments Rebirths
	without yielding between those mutations, so no income or merge callback
	can interleave halfway through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeService = require(script.Parent.MergeService)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local log = Log.new("RebirthService")

local requestLimiter = RateLimiter.new(1, 2)

local RebirthService = {}

local function requestRebirth(player: Player)
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	local rebirths = RebirthConfig.sanitizeRebirths(data.Rebirths)
	if rebirths >= RebirthConfig.MAX_REBIRTHS then
		UINotificationService.SendNotification(player, "Error", RebirthConfig.MAX_REBIRTHS_MESSAGE)
		return
	end

	local requiredModelLevel = RebirthConfig.maxModelLevel(rebirths)
	local bestModelLevel = RebirthConfig.bestModelLevel(data.Merge.Squishies)
	if bestModelLevel < requiredModelLevel then
		UINotificationService.SendNotification(player, "Error", RebirthConfig.INSUFFICIENT_TIER_MESSAGE)
		return
	end

	-- clearSquishies owns every live-state cleanup path: carried/in-flight
	-- objects, parts, health state, and the compact persisted array.
	local cleared = MergeService.clearSquishies(player)
	if cleared == nil then
		log.warn(`rebirth for {player.Name} could not clear squishies`)
		return
	end

	MergeService.resetIncomeRemainder(player)
	DataService.setValues(player, { "Merge" }, {
		SpawnLevel = UpgradeConfig.DEFAULT_SPAWN_LEVEL,
		MaxSpawns = UpgradeConfig.DEFAULT_MAX_SPAWNS,
		LockBase = UpgradeConfig.DEFAULT_LOCK_BASE_MINUTES,
	})
	DataService.setValues(player, {}, {
		Coins = 0,
		Rebirths = rebirths + 1,
	})
	UINotificationService.SendNotification(player, "Success", "Rebirth successful!")
	UINotificationService.EmitConfetti(player)
end

function RebirthService.Init()
	Net.rebirthRequest.listen(function(_data, player)
		if player ~= nil and requestLimiter:allow(player) then
			requestRebirth(player)
		end
	end)
end

function RebirthService.Start()
	log.info("ready")
end

return RebirthService
