--!strict
--[[
	Playtime-reward tuning: reset cadence and the per-slot required-duration
	table. Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.PlaytimeRewards, then annotated with the
	real payouts in Server/Modules/UISystem/PlaytimeRewardFunctions.luau --
	keep the two in sync if the schedule ever changes.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here. PlaytimeRewardsController reads Icon during its static per-slot
	setup in Start() (Decor.Icon.Image), same as DailyRewardsController does
	for the Daily panel. PlaytimeRewardsController's updateUi still only
	reads Duration and the replicated ClaimedRewards. It also has no
	reward-text label to drive, so the reward description below is a
	comment, not a new field.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)

local PlaytimeRewards = {
	Config = {
		ResetDuration = 24 * 60 * 60, -- The time when the rewards will reset from the first time
	},
	Rewards = {
		[1] = {
			Duration = 5 * 60, -- Required time in order to unlock the reward (5 x 60 seconds = 5 minutes)
			Icon = Images.Cash, -- 50 coins
		},
		[2] = {
			Duration = 15 * 60, -- Required time in order to unlock the reward (15 x 60 seconds = 15 minutes)
			Icon = Images.Cash, -- 150 coins
		},
		[3] = {
			Duration = 30 * 60, -- Required time in order to unlock the reward (30 x 60 seconds = 30 minutes)
			Icon = Images.StarterPack, -- 300 coins + Slime Trail
		},
		[4] = {
			Duration = 60 * 60, -- Required time in order to unlock the reward (60 x 60 seconds = 1 hour)
			Icon = Images.SecretPack, -- 400 coins + X Trail
		},
		[5] = {
			Duration = 1.5 * 60 * 60, -- Required time in order to unlock the reward (1.5 x 60 x 60 seconds = 1.5 hours)
			Icon = Images.Cash, -- 750 coins
		},
		[6] = {
			Duration = 2 * 60 * 60, -- Required time in order to unlock the reward (2 x 60 x 60 seconds = 2 hours)
			Icon = Images.ThemeIcons.RoyalVelvet, -- Royal Velvet Theme
		},
		[7] = {
			Duration = 3 * 60 * 60, -- Required time in order to unlock the reward (3 x 60 x 60 seconds = 3 hours)
			Icon = Images.ThemeIcons.Frostfire, -- Frostfire Theme
		},
	},
}

export type PlaytimeRewards = typeof(PlaytimeRewards)

return PlaytimeRewards
