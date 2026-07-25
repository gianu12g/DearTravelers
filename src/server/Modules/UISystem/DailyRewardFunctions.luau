--!strict
--[[
	Daily-reward payouts (PORT-SPEC.md §1, from source
	DailyRewardsService.RewardFunctions -- print()-only placeholders in the
	source). This game's economy never specified what these 7 slots should
	pay out, so the schedule below is a deliberate design choice, not a port:

	Day 1: 100 coins
	Day 2: KeycapThemes "Ultraviolet"        -- D1-retention driver
	Day 3: 250 coins
	Day 4: 500 coins
	Day 5: 500 coins
	Day 6: 500 coins
	Day 7: KeycapThemes "ObsidianGold"        -- weekly capper, most premium

	The daily track repeats every 7 days (DailyRewardsService's
	STALE_SESSION_SECONDS reset), so the two theme days route through
	CosmeticRewardHelper.grantOrFallback: a repeat cycle grants fallback
	coins instead of silently no-op'ing on an already-owned id. Fallback
	amount is roughly the theme's value in coins (~1000), calibrated against
	WheelSpinRewardFunctions' ~100/slot cash rewards and comfortably under
	EconomyConfig.MAX_GRANT.

	Days 4 and 6 (2026-07-24: SquishyBeams ships exactly one beam, so there
	is no longer a second/third cosmetic id in that slot to grant here) now
	pay a flat 500 coins unconditionally -- the same amount a repeat-cycle
	claim already paid via CosmeticRewardHelper.grantOrFallback's fallback,
	so payout parity with the prior schedule is preserved exactly.
]]

local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local CosmeticRewardHelper = require(ServerStorage.Modules.UISystem.CosmeticRewardHelper)

local THEME_FALLBACK_COINS = 1000

local DailyRewardFunctions: { [number]: (Player) -> boolean } = {
	[1] = function(player: Player)
		return CoinsService.add(player, 100)
	end,
	[2] = function(player: Player)
		return CosmeticRewardHelper.grantOrFallback(player, "KeycapThemes", "Ultraviolet", THEME_FALLBACK_COINS)
	end,
	[3] = function(player: Player)
		return CoinsService.add(player, 250)
	end,
	[4] = function(player: Player)
		return CoinsService.add(player, 500)
	end,
	[5] = function(player: Player)
		return CoinsService.add(player, 500)
	end,
	[6] = function(player: Player)
		return CoinsService.add(player, 500)
	end,
	[7] = function(player: Player)
		return CosmeticRewardHelper.grantOrFallback(player, "KeycapThemes", "ObsidianGold", THEME_FALLBACK_COINS)
	end,
}

return DailyRewardFunctions
