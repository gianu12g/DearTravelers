--!strict
--[[
	Developer-product "pack" reward stubs (PORT-SPEC.md §1, from source
	MarketplaceService.PacksRewards -- print()-only placeholders in the
	source). Keys match Shared/UISystem/Config/Packs.luau 1:1 -- unlike
	PassRewards.luau, the source's keys here were already correct.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("PackRewards")

local function stub(packName: string): (Player) -> boolean
	return function(player: Player)
		-- STUB: replace with the real reward for the "{packName}" pack.
		log.debug(`pack reward stub "{packName}" for {player.Name}`)
		return false
	end
end

local PackRewards: { [string]: (Player) -> boolean } = {
	["Starter Pack"] = stub("Starter Pack"),
	["Secret Pack"] = stub("Secret Pack"),
}

return PackRewards
