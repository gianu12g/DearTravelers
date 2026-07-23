--!strict
--[[
	Shared payout helper for DailyRewardFunctions / PlaytimeRewardFunctions
	cosmetic slots. Both tracks repeat their cycle (7-day daily loop, 24h
	playtime reset -- PlaytimeRewardsService.luau's ResetDuration), and
	CosmeticsService.grant is idempotent: it returns true for an
	already-owned id without granting anything new. A fixed cosmetic reward
	would therefore silently no-op on cycle 2+.

	grantOrFallback pre-checks ownership the same way
	DevService.onGrantAllCosmetics does (data.Cosmetics.Owned[slot] +
	table.find) and grants `fallbackCoins` instead when the player already
	owns `id`, so a repeat cycle always pays out something.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local CosmeticsService = require(ServerStorage.Services.CosmeticsService)
local DataService = require(ServerStorage.Services.DataService)

local CosmeticRewardHelper = {}

--[[
	Grants `id` in `slot` to `player` if not already owned; otherwise grants
	`fallbackCoins` coins so a repeat cycle never no-ops. Returns false only
	if the player's data isn't loaded (both the ownership check and the
	fallback grant need it) -- matches the (Player) -> boolean payout
	contract every RewardFunctions caller expects.
]]
function CosmeticRewardHelper.grantOrFallback(
	player: Player,
	slot: CosmeticsCatalog.Slot,
	id: string,
	fallbackCoins: number
): boolean
	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local owned = data.Cosmetics.Owned[slot]
	if table.find(owned, id) ~= nil then
		return CoinsService.add(player, fallbackCoins)
	end

	return CosmeticsService.grant(player, slot, id)
end

return CosmeticRewardHelper
