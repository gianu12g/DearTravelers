--!strict
--[[
	Daily-reward payout stubs (PORT-SPEC.md §1, from source
	DailyRewardsService.RewardFunctions -- print()-only placeholders in the
	source, ported as clearly-marked stubs rather than invented grants
	(PORT-SPEC.md §5.6): this game's economy never specified what these 7
	slots should pay out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("DailyRewardFunctions")

local function stub(index: number): (Player) -> boolean
	return function(player: Player)
		-- STUB: replace with the real daily-reward payout for slot {index}.
		log.debug(`daily reward stub {index} for {player.Name}`)
		return false
	end
end

local DailyRewardFunctions: { [number]: (Player) -> boolean } = {
	[1] = stub(1),
	[2] = stub(2),
	[3] = stub(3),
	[4] = stub(4),
	[5] = stub(5),
	[6] = stub(6),
	[7] = stub(7),
}

return DailyRewardFunctions
