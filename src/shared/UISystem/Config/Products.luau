--!strict
--[[
	Developer-product catalog (currency packs + spin packs). Ported 1:1 from
	the UISystem dump's ReplicatedStorage.Configuration.Products.

	Not every product has a GiftID -- the spin packs cannot be gifted, only
	bought for yourself, matching the source table exactly.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Products = {
	["1K Cash"] = {
		ProductID = 3601118674, -- Change this to whatever your product ID is [Product]
		GiftID = 3601118829, -- Change this to whatever your product ID is [Product]
	},
	["100K Cash"] = {
		ProductID = 3601118714, -- Change this to whatever your product ID is [Product]
		GiftID = 3601118897, -- Change this to whatever your product ID is [Product]
	},
	["1M Cash"] = {
		ProductID = 3596658382, -- Change this to whatever your product ID is [Product]
		GiftID = 3596658445, -- Change this to whatever your product ID is [Product]
	},
	["10M Cash"] = {
		ProductID = 3601118759, -- Change this to whatever your product ID is [Product]
		GiftID = 3601118944, -- Change this to whatever your product ID is [Product]
	},

	["x2 Spins"] = {
		ProductID = 3596661032, -- Change this to whatever your product ID is [Product]
	},

	["x5 Spins"] = {
		ProductID = 3599716704, -- Change this to whatever your product ID is [Product]
	},

	["x10 Spins"] = {
		ProductID = 3599716772, -- Change this to whatever your product ID is [Product]
	},
}

export type Products = typeof(Products)

return Products
