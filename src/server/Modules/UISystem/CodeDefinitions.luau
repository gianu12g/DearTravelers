--!strict
--[[
	Redeem-code definitions (PORT-SPEC.md §1, from source
	ServerScriptService.Services.CodesService.Codes). Keys are lower-cased at
	module load, same as the source, so CodesService's redeem() can
	string.lower() an arbitrary client-typed code and look it up directly.

	Only "cash100" grants a real reward here, wired to the merged Coins
	balance via CoinsService (PORT-SPEC.md §2's Cash->Coins decision) instead
	of the source's DataService:Increment(player, "Cash", 100). The two test
	codes are ported verbatim in effect (debug-only, same as the source's
	print-only stubs, but through Shared.Log like every other stub module
	in this folder rather than a bare print) -- they were smoke tests for
	the redemption flow, never real rewards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("CodeDefinitions")

export type CodeInfo = {
	isValid: (Player) -> boolean,
	numberOfUses: number,
	reward: (Player) -> (),
}

local codes: { [string]: CodeInfo } = {
	["Cash100"] = {
		isValid = function(_player: Player)
			return true
		end,
		numberOfUses = 999,
		reward = function(player: Player)
			CoinsService.add(player, 100)
		end,
	},
	["TestCode1"] = {
		isValid = function(_player: Player)
			return true
		end,
		numberOfUses = 999,
		reward = function(player: Player)
			log.debug(`redeemed TestCode1: {player.Name} (no real reward -- source test code)`)
		end,
	},
	["TestCode2"] = {
		isValid = function(_player: Player)
			return true
		end,
		numberOfUses = -1,
		reward = function(player: Player)
			log.debug(`redeemed TestCode2: {player.Name} (no real reward -- source test code)`)
		end,
	},
	["Hey"] = {
		isValid = function(_player: Player)
			return true
		end,
		numberOfUses = -1,
		reward = function(_player: Player) end,
	},
}

local lowerCased: { [string]: CodeInfo } = {}
for name, info in codes do
	lowerCased[string.lower(name)] = info
end

return lowerCased
