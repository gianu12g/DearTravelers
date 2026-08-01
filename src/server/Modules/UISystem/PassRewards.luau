--!strict
--[[
	Permanent gamepass callbacks. The service applies the same benefit for a
	native pass purchase and a developer-product gift delivery.
]]

local ServerStorage = game:GetService("ServerStorage")

local PassEntitlementService = require(ServerStorage.Services.PassEntitlementService)

local function grant(passName: string): (Player) -> boolean
	return function(player: Player)
		return PassEntitlementService.grant(player, passName)
	end
end

local PassRewards: { [string]: (Player) -> boolean } = {
	["VIP"] = grant("VIP"),
	["Offline Earnings+"] = grant("Offline Earnings+"),
	["2x Cash"] = grant("2x Cash"),
	["2x Speed"] = grant("2x Speed"),
	["Auto Merge"] = grant("Auto Merge"),
	["x2 Spawn"] = grant("x2 Spawn"),
	["x2 Faster Lock"] = grant("x2 Faster Lock"),
	["x2 Squishy Health"] = grant("x2 Squishy Health"),
	["x2 Faster Launch"] = grant("x2 Faster Launch"),
}

return PassRewards
