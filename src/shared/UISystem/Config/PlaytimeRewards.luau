--!strict
--[[
	Playtime-reward tuning: reset cadence and the per-slot required-duration
	table. Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.PlaytimeRewards.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here.
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
			Icon = Images.PlaytimeReward, -- Icon ID for UI
		},
		[2] = {
			Duration = 15 * 60, -- Required time in order to unlock the reward (15 x 60 seconds = 15 minutes)
			Icon = Images.PlaytimeReward,
		},
		[3] = {
			Duration = 30 * 60, -- Required time in order to unlock the reward (30 x 60 seconds = 30 minutes)
			Icon = Images.PlaytimeReward,
		},
		[4] = {
			Duration = 60 * 60, -- Required time in order to unlock the reward (60 x 60 seconds = 1 hour)
			Icon = Images.PlaytimeReward,
		},
		[5] = {
			Duration = 1.5 * 60 * 60, -- Required time in order to unlock the reward (1.5 x 60 x 60 seconds = 1.5 hours)
			Icon = Images.PlaytimeReward,
		},
		[6] = {
			Duration = 2 * 60 * 60, -- Required time in order to unlock the reward (2 x 60 x 60 seconds = 2 hours)
			Icon = Images.PlaytimeReward,
		},
		[7] = {
			Duration = 3 * 60 * 60, -- Required time in order to unlock the reward (3 x 60 x 60 seconds = 3 hours)
			Icon = Images.PlaytimeReward,
		},
	},
}

export type PlaytimeRewards = typeof(PlaytimeRewards)

return PlaytimeRewards
