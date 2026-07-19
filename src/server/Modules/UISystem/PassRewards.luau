--!strict
--[[
	Gamepass reward stubs (PORT-SPEC.md §1, from source
	MarketplaceService.PassesRewards -- print()-only placeholders in the
	source).

	Bug fixed in passing: the source keyed this table ["Pass1"]..["Pass5"],
	which never matched any key in its own Configuration.Passes table (VIP,
	Teleporter, x2 Speed -- see Shared/UISystem/Config/Passes.luau). Every
	MonetizationService.GivePass lookup (`PassRewards[passName]`) would have
	missed, silently, forever -- the source's stubs were unreachable dead
	code. Keyed here by the REAL pass names instead, so unstubbing one of
	these actually fires.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("PassRewards")

local function stub(passName: string): (Player) -> ()
	return function(player: Player)
		-- STUB: replace with the real reward for the "{passName}" gamepass.
		log.debug(`pass reward stub "{passName}" for {player.Name}`)
	end
end

local PassRewards: { [string]: (Player) -> () } = {
	["VIP"] = stub("VIP"),
	["Teleporter"] = stub("Teleporter"),
	["x2 Speed"] = stub("x2 Speed"),
}

return PassRewards
