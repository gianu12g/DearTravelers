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
}

return PassRewards
