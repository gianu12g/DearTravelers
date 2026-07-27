--!strict
--[[
	Pure helpers for persisted squishies and offline income.

	applySessionStart is intentionally called by DataService after Reconcile()
	but before the profile is exposed through Replica. That is the only point
	in a session where mutating the freshly loaded profile table directly is
	safe: no client can have received it yet. The offline grant, receipt, and
	new activity timestamp therefore become one initial state instead of three
	replicated writes that a joining client could observe halfway through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(script.Parent.EconomyConfig)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local SquishyProgress = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The authoritative income pulse for a saved squishy collection. The count is
-- bounded exactly like materialization on the pad, so malformed oversized
-- profile data can never earn money for impossible extra squishies.
function SquishyProgress.incomePerPulse(squishies: any, rebirths: any?): number
	if type(squishies) ~= "table" then
		return 0
	end

	local total = 0
	local squishyCount = math.min(#squishies, MergeConfig.MAX_OBJECTS)
	for i = 1, squishyCount do
		local squishy = squishies[i]
		if type(squishy) == "table" then
			total += MergeConfig.incomeForTier(squishy.Tier)
		end
	end
	return total * RebirthConfig.incomeMultiplier(rebirths)
end

-- Applies one capped offline grant and returns (actualCoinsGranted,
-- eligibleOfflineSeconds). A first-time player has LastActiveAt == 0 and
-- receives no synthetic windfall.
function SquishyProgress.applySessionStart(data: any, now: number, maxOfflineSeconds: number?): (number, number)
	local merge = data.Merge
	if type(merge) ~= "table" then
		-- Reconcile adds missing fields but deliberately does not replace a
		-- field whose stored type is invalid. Repair that rare legacy/corrupt
		-- shape before Replica can see it.
		merge = {
			Squishies = {},
			SpawnLevel = UpgradeConfig.DEFAULT_SPAWN_LEVEL,
			MaxSpawns = UpgradeConfig.DEFAULT_MAX_SPAWNS,
			LockBase = UpgradeConfig.DEFAULT_LOCK_BASE_LEVEL,
			LastActiveAt = 0,
			OfflineEarnings = { Amount = 0, Seconds = 0, AwardedAt = 0 },
		}
		data.Merge = merge
	end
	if type(merge.Squishies) ~= "table" then
		merge.Squishies = {}
	end
	local lastActiveAt = merge.LastActiveAt
	local offlineSeconds = 0
	local offlineCap = if isFiniteNumber(maxOfflineSeconds) and maxOfflineSeconds > 0
		then math.floor(maxOfflineSeconds)
		else MergeConfig.MAX_OFFLINE_SECONDS

	if isFiniteNumber(lastActiveAt) and lastActiveAt > 0 and now > lastActiveAt then
		offlineSeconds = math.min(math.floor(now - lastActiveAt), offlineCap)
	end

	local pulseCount = math.floor(offlineSeconds / MergeConfig.INCOME_INTERVAL)
	local calculatedEarnings = SquishyProgress.incomePerPulse(merge.Squishies, data.Rebirths) * pulseCount
	-- Coins are integer-owned throughout the economy. Floor once after the
	-- whole offline duration, not once per second, so the 25% increments are
	-- preserved instead of disappearing on low-level models.
	calculatedEarnings = math.min(math.floor(calculatedEarnings), EconomyConfig.MAX_GRANT)

	local currentCoins = data.Coins
	if not isFiniteNumber(currentCoins) or currentCoins < 0 then
		currentCoins = 0
	else
		currentCoins = math.min(math.floor(currentCoins), EconomyConfig.MAX_COINS)
	end

	local newCoins = math.min(currentCoins + calculatedEarnings, EconomyConfig.MAX_COINS)
	local actualEarnings = newCoins - currentCoins

	data.Coins = newCoins
	merge.LastActiveAt = now
	merge.OfflineEarnings = {
		Amount = actualEarnings,
		Seconds = offlineSeconds,
		AwardedAt = now,
	}

	return actualEarnings, offlineSeconds
end

return SquishyProgress
