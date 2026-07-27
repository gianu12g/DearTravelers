--!strict
--[[
	Shared progression for the three coin upgrades shown in
	PlayerGui.Main.Frames.Upgrades.

	The client reads this module only to render values/prices. The server reads
	the same definitions again before charging Coins, and is the only side that
	can mutate the persisted values.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)

export type UpgradeKey = "SpawnTier" | "MaxSpawns" | "LockBase"
export type CostCurve = {
	BaseCost: number,
	Multiplier: number,
}

local UpgradeConfig = {}

UpgradeConfig.ORDER = { "SpawnTier", "MaxSpawns", "LockBase" } :: { UpgradeKey }

UpgradeConfig.DEFAULT_SPAWN_LEVEL = 1
UpgradeConfig.DEFAULT_MAX_SPAWNS = 6
UpgradeConfig.MAX_MAX_SPAWNS = MergeConfig.MAX_OBJECTS
UpgradeConfig.DEFAULT_LOCK_BASE_LEVEL = 1
UpgradeConfig.MAX_LOCK_BASE_LEVEL = 5
UpgradeConfig.LOCK_DURATION_SECONDS = 20
UpgradeConfig.DEFAULT_LOCK_COOLDOWN_SECONDS = 60
UpgradeConfig.LOCK_COOLDOWN_REDUCTION_PER_LEVEL = 2

-- Each upgrade buys a different kind of power, so one shared curve makes the
-- cheap rows trivial long before the stronger rows feel earned.
--
-- SpawnTier stays the gentlest because rebirth resets it and higher spawn
-- tiers are what let a run get moving. MaxSpawns compounds production and is
-- deliberately the steepest economic purchase. LockBase grants no income,
-- but reducing how often a base is vulnerable should still require meaningful
-- progress.
UpgradeConfig.COST_CURVES = {
	SpawnTier = {
		BaseCost = 50_000,
		Multiplier = 2.25,
	},
	MaxSpawns = {
		BaseCost = 250_000,
		Multiplier = 3,
	},
	LockBase = {
		BaseCost = 500_000,
		Multiplier = 4,
	},
} :: { [UpgradeKey]: CostCurve }

-- CoinsService deliberately rejects individual transactions above 1e12.
UpgradeConfig.MAX_COST = 1e12

local VALID_KEYS: { [string]: true } = {
	SpawnTier = true,
	MaxSpawns = true,
	LockBase = true,
}

local function finiteInteger(value: any, minimum: number, maximum: number, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(math.floor(value), minimum, maximum)
end

function UpgradeConfig.isUpgradeKey(value: any): boolean
	return type(value) == "string" and VALID_KEYS[value] == true
end

function UpgradeConfig.minimumValue(key: UpgradeKey): number
	if key == "SpawnTier" then
		return UpgradeConfig.DEFAULT_SPAWN_LEVEL
	elseif key == "MaxSpawns" then
		return UpgradeConfig.DEFAULT_MAX_SPAWNS
	else
		return UpgradeConfig.DEFAULT_LOCK_BASE_LEVEL
	end
end

function UpgradeConfig.maximumValue(key: UpgradeKey): number
	if key == "SpawnTier" then
		return RebirthConfig.MAX_MODEL_LEVEL
	elseif key == "MaxSpawns" then
		return UpgradeConfig.MAX_MAX_SPAWNS
	else
		return UpgradeConfig.MAX_LOCK_BASE_LEVEL
	end
end

function UpgradeConfig.sanitizeValue(key: UpgradeKey, value: any): number
	return finiteInteger(
		value,
		UpgradeConfig.minimumValue(key),
		UpgradeConfig.maximumValue(key),
		UpgradeConfig.minimumValue(key)
	)
end

function UpgradeConfig.readValue(data: any, key: UpgradeKey): number
	local merge = if type(data) == "table" and type(data.Merge) == "table" then data.Merge else {}
	if key == "SpawnTier" then
		return UpgradeConfig.sanitizeValue(key, merge.SpawnLevel)
	elseif key == "MaxSpawns" then
		return UpgradeConfig.sanitizeValue(key, merge.MaxSpawns)
	else
		return UpgradeConfig.sanitizeValue(key, merge.LockBase)
	end
end

function UpgradeConfig.pathFor(key: UpgradeKey): { string | number }
	if key == "SpawnTier" then
		return { "Merge", "SpawnLevel" }
	elseif key == "MaxSpawns" then
		return { "Merge", "MaxSpawns" }
	else
		return { "Merge", "LockBase" }
	end
end

-- All three rows start at upgrade level 1 even though MaxSpawns' gameplay
-- value starts at 6.
function UpgradeConfig.levelForValue(key: UpgradeKey, value: any): number
	local safeValue = UpgradeConfig.sanitizeValue(key, value)
	return safeValue - UpgradeConfig.minimumValue(key) + 1
end

function UpgradeConfig.costForValue(key: UpgradeKey, value: any): number?
	local safeValue = UpgradeConfig.sanitizeValue(key, value)
	if safeValue >= UpgradeConfig.maximumValue(key) then
		return nil
	end

	local level = UpgradeConfig.levelForValue(key, safeValue)
	local curve = UpgradeConfig.COST_CURVES[key]
	local rawCost = curve.BaseCost * curve.Multiplier ^ (level - 1)
	return math.min(math.round(rawCost), UpgradeConfig.MAX_COST)
end

function UpgradeConfig.nextValue(key: UpgradeKey, value: any): number?
	local safeValue = UpgradeConfig.sanitizeValue(key, value)
	if safeValue >= UpgradeConfig.maximumValue(key) then
		return nil
	end
	return safeValue + 1
end

function UpgradeConfig.lockCooldownSeconds(lockBaseLevel: any): number
	local level = UpgradeConfig.sanitizeValue("LockBase", lockBaseLevel)
	local purchasedLevels = level - UpgradeConfig.DEFAULT_LOCK_BASE_LEVEL
	return math.max(
		0,
		UpgradeConfig.DEFAULT_LOCK_COOLDOWN_SECONDS - purchasedLevels * UpgradeConfig.LOCK_COOLDOWN_REDUCTION_PER_LEVEL
	)
end

return UpgradeConfig
