--!strict
--[[
	Group-membership reward (PORT-SPEC.md §1, source
	ServerScriptService.Services.GroupRewardService). One-time claim gated on
	IsInGroupAsync against Config.General.GroupID.

	The source's RemoteFunction-style invoke (Packets.GroupReward.ClaimReward)
	becomes the groupClaimRequest -> groupClaimResult request/response pair
	(PORT-SPEC.md §3); the boolean the client used to get back from
	InvokeServer is now the `ok` field on the result packet.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local General = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("GroupRewardService")

local REWARD_RETRIES = 3

-- STUB: replace with the real group-membership reward.
local function grantReward(player: Player)
	log.debug(`granting group reward to {player.Name} (stub)`)
end

-- Anti-double-claim lock. Released on EVERY path below, including errors --
-- a lock that only clears on success would strand a player who hit a
-- transient IsInGroupAsync failure, permanently unable to retry
-- (quality-gate.md: pcall + explicit release, no `finally` in Luau).
local claiming: { [Player]: true } = {}

local function onPlayerRemoving(player: Player)
	claiming[player] = nil
end

local function handleClaim(player: Player)
	local data = DataService.getData(player)
	if data == nil then
		Net.groupClaimResult.sendTo({ ok = false }, player)
		return
	end

	if data.UISystem.GroupReward then
		UINotificationService.SendNotification(player, "Error", "Already Claimed")
		Net.groupClaimResult.sendTo({ ok = true }, player)
		return
	end

	local ok, isInGroup = pcall(function()
		return player:IsInGroupAsync(General.GroupID)
	end)

	if not ok then
		UINotificationService.SendNotification(player, "Error", "Something went wrong, try again later")
		Net.groupClaimResult.sendTo({ ok = false }, player)
		return
	end

	if not isInGroup then
		UINotificationService.SendNotification(player, "Error", "You must join the group first")
		Net.groupClaimResult.sendTo({ ok = false }, player)
		return
	end

	local rewarded = false
	for _ = 1, REWARD_RETRIES do
		if pcall(grantReward, player) then
			rewarded = true
			break
		end
	end

	if not rewarded then
		UINotificationService.SendNotification(player, "Error", "Something went wrong, try again later")
		Net.groupClaimResult.sendTo({ ok = false }, player)
		return
	end

	DataService.set(player, { "UISystem", "GroupReward" }, true)
	UINotificationService.SendNotification(player, "Success", "Claimed Successfully")
	Net.groupClaimResult.sendTo({ ok = true }, player)
end

local GroupRewardService = {}

function GroupRewardService.Init()
	Net.groupClaimRequest.listen(function(_, player)
		if player == nil then
			return
		end

		if claiming[player] then
			Net.groupClaimResult.sendTo({ ok = false }, player)
			return
		end
		claiming[player] = true

		local ok, err = pcall(handleClaim, player)
		claiming[player] = nil

		if not ok then
			log.warn(`handleClaim errored for {player.Name}: {tostring(err)}`)
			Net.groupClaimResult.sendTo({ ok = false }, player)
		end
	end)
end

function GroupRewardService.Start()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	log.info("ready")
end

return GroupRewardService
