--!strict
--[[
	Daily-reward slot display data (icon + label per day). Ported 1:1 from
	the UISystem dump's ReplicatedStorage.Configuration.DailyRewards.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local DailyRewards = {
	[1] = {
		Icon = 73989013612789, -- Icon ID for UI
		Text = "One", -- Text for Ui
	},
	[2] = {
		Icon = 88132060004695, -- Icon ID for UI
		Text = "Two", -- Text for Ui
	},
	[3] = {
		Icon = 135629275004235, -- Icon ID for UI
		Text = "Three", -- Text for Ui
	},
	[4] = {
		Icon = 73167539394400, -- Icon ID for UI
		Text = "Four", -- Text for Ui
	},
	[5] = {
		Icon = 110024503496390, -- Icon ID for UI
		Text = "Five", -- Text for Ui
	},
	[6] = {
		Icon = 127607991886697, -- Icon ID for UI
		Text = "Six", -- Text for Ui
	},
	[7] = {
		Icon = 137945076270111, -- Icon ID for UI
		Text = "Seven", -- Text for Ui
	},
}

export type DailyRewards = typeof(DailyRewards)

return DailyRewards
