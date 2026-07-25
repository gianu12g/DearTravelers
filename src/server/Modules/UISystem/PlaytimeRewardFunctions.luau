--!strict
--[[
	Playtime-reward payouts (PORT-SPEC.md §1, from source
	PlaytimeRewardsService.RewardFunctions -- print()-only placeholders in
	the source). The source table went up to index 15, but
	PlaytimeRewardsService.Init bounds-checks claims against
	Shared/UISystem/Config/PlaytimeRewards.luau's Rewards track
	(`index > #PlaytimeRewardsConfig.Rewards`), which defines only 7 slots --
	indices 8-15 are unreachable, so only 1-7 are ported here.

	Schedule (durations from PlaytimeRewards.luau: 5m/15m/30m/1h/1.5h/2h/3h),
	weighted so the longest session milestones pay the best rewards
	(session-length is a retention driver the same way daily D1/D7 is):

	1 (5m):   50 coins
	2 (15m):  150 coins
	3 (30m):  800 coins
	4 (1h):   900 coins
	5 (1.5h): 750 coins
	6 (2h):   KeycapThemes "RoyalVelvet"
	7 (3h):   KeycapThemes "Frostfire"  -- longest milestone, most premium

	The playtime track resets every ResetDuration (24h,
	PlaytimeRewardsService.luau), so the theme slots route through
	CosmeticRewardHelper.grantOrFallback the same way DailyRewardFunctions
	does: a repeat cycle grants fallback coins instead of silently no-op'ing
	on an already-owned id.

	Tiers 3 and 4 (2026-07-24: SquishyBeams ships exactly one beam, so there
	is no longer a second/fourth cosmetic id in that slot to grant here) now
	pay a flat coin amount unconditionally, at the same total a repeat-cycle
	claim already paid via CosmeticRewardHelper.grantOrFallback's 500-coin
	fallback plus that tier's own base coins: 300 + 500 = 800 for tier 3,
	400 + 500 = 900 for tier 4. Payout parity with the prior schedule is
	preserved exactly.
]]

local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local CosmeticRewardHelper = require(ServerStorage.Modules.UISystem.CosmeticRewardHelper)

local THEME_FALLBACK_COINS = 1000

local PlaytimeRewardFunctions: { [number]: (Player) -> boolean } = {
	[1] = function(player: Player)
		return CoinsService.add(player, 50)
	end,
	[2] = function(player: Player)
		return CoinsService.add(player, 150)
	end,
	[3] = function(player: Player)
		return CoinsService.add(player, 800)
	end,
	[4] = function(player: Player)
		return CoinsService.add(player, 900)
	end,
	[5] = function(player: Player)
		return CoinsService.add(player, 750)
	end,
	[6] = function(player: Player)
		return CosmeticRewardHelper.grantOrFallback(player, "KeycapThemes", "RoyalVelvet", THEME_FALLBACK_COINS)
	end,
	[7] = function(player: Player)
		return CosmeticRewardHelper.grantOrFallback(player, "KeycapThemes", "Frostfire", THEME_FALLBACK_COINS)
	end,
}

return PlaytimeRewardFunctions
