--!strict
--[[
	Wheel-spin reward payouts (PORT-SPEC.md §1, from source
	WheelSpinService.RewardFunctions -- the other source reward table that
	did real work, not just print()). Indices match
	Shared/UISystem/Config/WheelSpin.luau's Rewards table 1:1. Cash grants
	map onto the merged Coins balance (PORT-SPEC.md §2) via CoinsService.
]]

local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)

local WheelSpinRewardFunctions: { [number]: (Player) -> boolean } = {
	[1] = function(player: Player)
		return CoinsService.add(player, 100)
	end,
	[2] = function(player: Player)
		return CoinsService.add(player, 1000)
	end,
	[3] = function(player: Player)
		return CoinsService.add(player, 10000)
	end,
	[4] = function(player: Player)
		return CoinsService.add(player, 100000)
	end,
	[5] = function(player: Player)
		return CoinsService.add(player, 150000)
	end,
}

return WheelSpinRewardFunctions
