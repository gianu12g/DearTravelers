--!strict
--[[
	What to promote on the right-side UI: icon IDs keyed by the same names
	used in Config/Packs.luau, Config/Passes.luau and Config/Products.luau.
	Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.Promotion.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).

	Icon IDs now come from Shared.AssetIds.Images instead of being inlined
	here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)

local Promotion = {
	Packs = {} :: { [string]: number },
	Passes = {
		["VIP"] = Images.VipPass, -- Change this to the Icon ID you want to use.
		["2x Cash"] = Images.Cash100K,
		["2x Speed"] = Images.SpeedPass,
	},
	Products = {} :: { [string]: number },
}

export type Promotion = typeof(Promotion)

return Promotion
