--!strict
--[[
	Wheel-spin tuning: spin animation length, starting/free-spin economy, and
	the reward table with its roll chances. Ported 1:1 from the UISystem
	dump's ReplicatedStorage.Configuration.WheelSpin.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)

local WheelSpin = {
	NumberOfSpins = 5, -- Number of spins made before landing on selected segment
	FullSpinDuration = 4, -- The duration of spin
	StartingSpins = 1, -- The amount of spins have when they first join
	FreeSpinInterval = 5 * 60, -- The interval of free spin

	Rewards = {
		[1] = {
			Chance = 35, -- Percentage chance
			Icon = Images.Cash, -- Icon on UI
			Text = "100 Cash", -- Text on UI
		},
		[2] = {
			Chance = 30, -- Percentage chance
			Icon = Images.Cash, -- Icon on UI
			Text = "1K Cash", -- Text on UI
		},
		[3] = {
			Chance = 20, -- Percentage chance
			Icon = Images.Cash, -- Icon on UI
			Text = "10K Cash", -- Text on UI
		},
		[4] = {
			Chance = 10, -- Percentage chance
			Icon = Images.Cash, -- Icon on UI
			Text = "100K Cash", -- Text on UI
		},
		[5] = {
			Chance = 5, -- Percentage chance
			Icon = Images.Cash, -- Icon on UI
			Text = "150K Cash", -- Text on UI
		},
	},
}

export type WheelSpin = typeof(WheelSpin)

return WheelSpin
