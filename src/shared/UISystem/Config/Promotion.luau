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
	Packs = {
		["Starter Pack"] = Images.StarterPack, -- Change this to the Icon ID you want to use.
		["Secret Pack"] = Images.SecretPack, -- Change this to the Icon ID you want to use.
	},
	Passes = {
		["VIP"] = Images.VipPass, -- Change this to the Icon ID you want to use.
		["Teleporter"] = Images.TeleporterPass, -- Change this to the Icon ID you want to use.
		["x2 Speed"] = Images.SpeedPass, -- Change this to the Icon ID you want to use.
	},
	Products = {
		["100K Cash"] = Images.Cash100K, -- Change this to the Icon ID you want to use.
		["x5 Spins"] = Images.Wheel, -- Change this to the Icon ID you want to use.
	},
}

export type Promotion = typeof(Promotion)

return Promotion
