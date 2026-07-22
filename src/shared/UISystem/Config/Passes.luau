--!strict
--[[
	Gamepass catalog. Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.Passes.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Passes = {
	["VIP"] = {
		Enabled = false, -- Enable only after PassRewards implements the entitlement.
		PassID = 1853711135, -- Change this to whatever your pass ID is [Gamepass]
		GiftID = 3597136326, -- Change this to whatever your product ID is [Product]
	},

	["Teleporter"] = {
		Enabled = false,
		PassID = 1853549088, -- Change this to whatever your pass ID is [Gamepass]
		GiftID = 3597136834, -- Change this to whatever your product ID is [Product]
	},

	["x2 Speed"] = {
		Enabled = false,
		PassID = 1853099131, -- Change this to whatever your pass ID is [Gamepass]
		GiftID = 3597137176, -- Change this to whatever your product ID is [Product]
	},
}

export type Passes = typeof(Passes)

return Passes
