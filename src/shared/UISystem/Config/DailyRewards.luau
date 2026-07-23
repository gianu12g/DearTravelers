--!strict
--[[
	Daily-reward slot display data (icon + label per day). Ported 1:1 from
	the UISystem dump's ReplicatedStorage.Configuration.DailyRewards.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)

local DailyRewards = {
	[1] = {
		Icon = Images.DailyRewardDay1, -- Icon ID for UI
		Text = "One", -- Text for Ui
	},
	[2] = {
		Icon = Images.SecretPack, -- Icon ID for UI
		Text = "Two", -- Text for Ui
	},
	[3] = {
		Icon = Images.DailyRewardDay3, -- Icon ID for UI
		Text = "Three", -- Text for Ui
	},
	[4] = {
		Icon = Images.StarterPack, -- Icon ID for UI
		Text = "Four", -- Text for Ui
	},
	[5] = {
		Icon = Images.Cash, -- Icon ID for UI
		Text = "Five", -- Text for Ui
	},
	[6] = {
		Icon = Images.DailyRewardDay6, -- Icon ID for UI
		Text = "Six", -- Text for Ui
	},
	[7] = {
		Icon = Images.DailyRewardDay7, -- Icon ID for UI
		Text = "Seven", -- Text for Ui
	},
}

export type DailyRewards = typeof(DailyRewards)

return DailyRewards
