--!strict
--[[
	Shared rebirth progression.

	There are two intentionally different numbers in the merge loop:
	  * model level: the persisted, sequential index (1, 2, 3, ...)
	  * displayed tier: 2 ^ (modelLevel - 1) (1, 2, 4, 8, ...)

	Existing merge data calls the model-level field `Tier`. Renaming persisted
	data would add migration risk without changing its meaning, so all new UI
	and progression code routes the conversion through this module instead.
]]

local RebirthConfig = {}

RebirthConfig.BASE_MAX_MODEL_LEVEL = 10
RebirthConfig.MODEL_LEVELS_PER_REBIRTH = 5
RebirthConfig.MAX_REBIRTHS = 4
RebirthConfig.MAX_MODEL_LEVEL = RebirthConfig.BASE_MAX_MODEL_LEVEL
	+ RebirthConfig.MODEL_LEVELS_PER_REBIRTH * RebirthConfig.MAX_REBIRTHS

RebirthConfig.INCOME_BONUS_PER_REBIRTH = 0.25

RebirthConfig.REQUIRES_REBIRTH_MESSAGE = "Rebirth to unlock higher tiers"
RebirthConfig.INSUFFICIENT_TIER_MESSAGE = "Insufficient tier"
RebirthConfig.MAX_REBIRTHS_MESSAGE = "Maximum rebirths reached"
RebirthConfig.MAX_TIER_MESSAGE = "Maximum tier reached"

function RebirthConfig.sanitizeRebirths(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, RebirthConfig.MAX_REBIRTHS)
end

function RebirthConfig.maxModelLevel(rebirths: any): number
	return RebirthConfig.BASE_MAX_MODEL_LEVEL
		+ RebirthConfig.MODEL_LEVELS_PER_REBIRTH * RebirthConfig.sanitizeRebirths(rebirths)
end

function RebirthConfig.tierNumberForModelLevel(modelLevel: any): number
	if
		type(modelLevel) ~= "number"
		or modelLevel ~= modelLevel
		or modelLevel == math.huge
		or modelLevel == -math.huge
		or modelLevel <= 0
	then
		return 0
	end

	local safeLevel = math.clamp(math.floor(modelLevel), 1, RebirthConfig.MAX_MODEL_LEVEL)
	return 2 ^ (safeLevel - 1)
end

function RebirthConfig.incomeMultiplier(rebirths: any): number
	return 1 + RebirthConfig.sanitizeRebirths(rebirths) * RebirthConfig.INCOME_BONUS_PER_REBIRTH
end

function RebirthConfig.bestModelLevel(squishies: any): number
	if type(squishies) ~= "table" then
		return 0
	end

	local best = 0
	for _, squishy in squishies do
		if type(squishy) ~= "table" then
			continue
		end
		local modelLevel = squishy.Tier
		if
			type(modelLevel) == "number"
			and modelLevel == modelLevel
			and modelLevel ~= math.huge
			and modelLevel ~= -math.huge
		then
			best = math.max(best, math.clamp(math.floor(modelLevel), 1, RebirthConfig.MAX_MODEL_LEVEL))
		end
	end
	return best
end

return RebirthConfig
