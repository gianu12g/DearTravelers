--!strict
--[[
	General UISystem settings: the rewards group, admin overrides, and the
	ambient-music playlist. Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.General.

	A plain module -- the name ends in neither Service nor Controller, so the
	Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.
]]

local General = {
	GroupID = 584245985, -- ID of the group for group rewards
	Admins = { 11068316955 }, -- List of Admin IDs for admin commands

	AmbientMusic = { -- List of Music IDs which will run in the background in order
		1841647093,
		1848354536,
		5409360995,
	},

	--[[
		Source bug (PORT-SPEC.md §5.1): FriendRewardService reads
		General.InviteRewardRequiredFriends, but the dumped source table never
		defined it -- comparing against a missing field would error. Added
		here with the value the port spec calls for.
	]]
	InviteRewardRequiredFriends = 3,
}

export type General = typeof(General)

return General
