--!strict
--[[
	Server-owned currency limits shared by every system that can grant coins.
	Keeping these values in one plain module prevents offline income and the
	live CoinsService from silently disagreeing about the balance ceiling.
]]

local EconomyConfig = {}

-- Deliberately below float64's exact-integer ceiling (~9.007e15).
EconomyConfig.MAX_COINS = 1e15
-- Every single grant must fit under this bound. The maximum configured
-- offline payout is comfortably below it.
EconomyConfig.MAX_GRANT = 1e12

return EconomyConfig
