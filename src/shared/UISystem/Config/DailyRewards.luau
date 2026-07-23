--!strict
--[[
	Daily-reward slot display data (icon + label per day). Ported 1:1 from
	the UISystem dump's ReplicatedStorage.Configuration.DailyRewards, then
	updated to describe the real payouts in
	Server/Modules/UISystem/DailyRewardFunctions.luau -- keep the two in
	sync if the schedule ever changes.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here. Theme days use the exact per-theme card icon
	(Images.ThemeIcons[id], same asset CosmeticsController shows on the
	cosmetics menu); trail days have no dedicated trail icon yet
	(COSMETICS_PLAN.md), so they reuse the existing pack-style placeholders.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)

local DailyRewards = {
	[1] = {
		Icon = Images.Cash, -- Icon ID for UI
		Text = "100 Coins", -- Text for Ui
	},
	[2] = {
		Icon = Images.ThemeIcons.Ultraviolet, -- Icon ID for UI
		Text = "Ultraviolet Theme", -- Text for Ui
	},
	[3] = {
		Icon = Images.Cash, -- Icon ID for UI
		Text = "250 Coins", -- Text for Ui
	},
	[4] = {
		Icon = Images.StarterPack, -- Icon ID for UI
		Text = "Cool Trail", -- Text for Ui
	},
	[5] = {
		Icon = Images.Cash, -- Icon ID for UI
		Text = "500 Coins", -- Text for Ui
	},
	[6] = {
		Icon = Images.SecretPack, -- Icon ID for UI
		Text = "Red & Black Trail", -- Text for Ui
	},
	[7] = {
		Icon = Images.ThemeIcons.ObsidianGold, -- Icon ID for UI
		Text = "Obsidian Gold Theme", -- Text for Ui
	},
}

export type DailyRewards = typeof(DailyRewards)

return DailyRewards
