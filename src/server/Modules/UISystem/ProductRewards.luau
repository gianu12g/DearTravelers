--!strict
--[[
	Real developer-product reward callbacks (PORT-SPEC.md §1, from source
	MarketplaceService.ProductsRewards -- one of only two source reward
	tables that did real work rather than print()). Cash grants map onto the
	merged Coins balance (PORT-SPEC.md §2) via CoinsService; spin packs call
	WheelSpinService.AddSpins directly, same as the source's
	WheelSpinService:AddSpins.
]]

local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local MergeService = require(ServerStorage.Services.MergeService)
local WheelSpinService = require(ServerStorage.Services.UISystem.WheelSpinService)

local ProductRewards: { [string]: (Player) -> boolean } = {
	["10K Cash"] = function(player: Player)
		return CoinsService.add(player, 10000)
	end,

	["100K Cash"] = function(player: Player)
		return CoinsService.add(player, 100000)
	end,

	["1M Cash"] = function(player: Player)
		return CoinsService.add(player, 1000000)
	end,

	["10M Cash"] = function(player: Player)
		return CoinsService.add(player, 10000000)
	end,

	["2 Spins"] = function(player: Player)
		return WheelSpinService.AddSpins(player, 2)
	end,

	["5 Spins"] = function(player: Player)
		return WheelSpinService.AddSpins(player, 5)
	end,

	["10 Spins"] = function(player: Player)
		return WheelSpinService.AddSpins(player, 10)
	end,

	["+10 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 10)
	end,

	["+50 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 50)
	end,

	["+100 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 100)
	end,

	["+500 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 500)
	end,

	["+1,000 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 1000)
	end,

	["+10,000 Squishies"] = function(player: Player)
		return MergeService.addPurchasedSquishies(player, 10000)
	end,
}

return ProductRewards
