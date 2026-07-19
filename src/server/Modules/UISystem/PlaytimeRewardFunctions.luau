--!strict
--[[
	Playtime-reward payout stubs (PORT-SPEC.md §1, from source
	PlaytimeRewardsService.RewardFunctions -- print()-only placeholders in
	the source, ported as clearly-marked stubs). The source table went up to
	index 15 even though Shared/UISystem/Config/PlaytimeRewards.luau's
	Rewards track only defines 7 slots -- PlaytimeRewardsService's bounds
	check against that config means indices 8-15 are unreachable today, but
	all 15 are ported 1:1 in case the config track grows to match.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("PlaytimeRewardFunctions")

local function stub(index: number): (Player) -> ()
	return function(player: Player)
		-- STUB: replace with the real playtime-reward payout for slot {index}.
		log.debug(`playtime reward stub {index} for {player.Name}`)
	end
end

local PlaytimeRewardFunctions: { [number]: (Player) -> () } = {
	[1] = stub(1),
	[2] = stub(2),
	[3] = stub(3),
	[4] = stub(4),
	[5] = stub(5),
	[6] = stub(6),
	[7] = stub(7),
	[8] = stub(8),
	[9] = stub(9),
	[10] = stub(10),
	[11] = stub(11),
	[12] = stub(12),
	[13] = stub(13),
	[14] = stub(14),
	[15] = stub(15),
}

return PlaytimeRewardFunctions
