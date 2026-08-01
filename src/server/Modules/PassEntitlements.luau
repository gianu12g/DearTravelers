--!strict
--[[
	One server authority for permanent pass ownership. Native Roblox passes
	and custom gifted-pass entitlements are intentionally equivalent here, so
	gameplay systems never need to know how a player acquired the benefit.

	Marketplace ownership is cached for the current player session. A purchase
	or delivered gift calls markOwned(), which upgrades the cache immediately.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Passes = require(ReplicatedStorage.Shared.UISystem.Config.Passes)

type PassEntry = {
	Enabled: boolean,
	PassID: number,
	GiftID: number?,
}

local PassesByName = (Passes :: any) :: { [string]: PassEntry }
local log = Log.new("PassEntitlements")

local ownershipCache: { [number]: { [string]: boolean } } = {}

local PassEntitlements = {}

PassEntitlements.VIP = "VIP"
PassEntitlements.OFFLINE_EARNINGS = "Offline Earnings+"
PassEntitlements.DOUBLE_CASH = "2x Cash"
PassEntitlements.DOUBLE_SPEED = "2x Speed"
PassEntitlements.AUTO_MERGE = "Auto Merge"
PassEntitlements.DOUBLE_SPAWN = "x2 Spawn"
PassEntitlements.FASTER_LOCK = "x2 Faster Lock"
PassEntitlements.DOUBLE_SQUISHY_HEALTH = "x2 Squishy Health"
PassEntitlements.FASTER_LAUNCH = "x2 Faster Launch"

local function giftedPassOwned(data: any, passName: string): boolean
	return type(data) == "table"
		and type(data.UISystem) == "table"
		and type(data.UISystem.GiftedPasses) == "table"
		and data.UISystem.GiftedPasses[passName] == true
end

function PassEntitlements.markOwned(player: Player, passName: string)
	local userCache = ownershipCache[player.UserId]
	if userCache == nil then
		userCache = {}
		ownershipCache[player.UserId] = userCache
	end
	userCache[passName] = true
end

function PassEntitlements.owns(player: Player, passName: string, data: any?): boolean
	local pass = PassesByName[passName]
	if pass == nil or not pass.Enabled then
		return false
	end

	if giftedPassOwned(data, passName) then
		PassEntitlements.markOwned(player, passName)
		return true
	end

	local userCache = ownershipCache[player.UserId]
	if userCache ~= nil and userCache[passName] ~= nil then
		return userCache[passName]
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.PassID)
	end)
	if not ok then
		log.warn(`could not check "{passName}" ownership for {player.Name}: {tostring(owns)}`)
		return false
	end

	if userCache == nil then
		userCache = {}
		ownershipCache[player.UserId] = userCache
	end
	userCache[passName] = owns == true
	return owns == true
end

function PassEntitlements.clearPlayer(player: Player)
	ownershipCache[player.UserId] = nil
end

return PassEntitlements
