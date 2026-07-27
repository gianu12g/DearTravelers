--!strict
--[[
	Live developer-product catalog (currency packs + spin packs).

	Not every product has a GiftID -- the spin packs cannot be gifted, only
	bought for yourself.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Products = {
	["10K Cash"] = {
		ProductID = 3611981992,
		GiftID = 3611982428,
	},
	["100K Cash"] = {
		ProductID = 3611982273,
		GiftID = 3611982480,
	},
	["1M Cash"] = {
		ProductID = 3611982313,
		GiftID = 3611982533,
	},
	["10M Cash"] = {
		ProductID = 3611982365,
		GiftID = 3611982590,
	},

	["2 Spins"] = {
		ProductID = 3611983395,
	},

	["5 Spins"] = {
		ProductID = 3611983417,
	},

	["10 Spins"] = {
		ProductID = 3611983494,
	},
}

export type Products = typeof(Products)

return Products
