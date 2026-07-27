--!strict
--[[
	Live gamepass catalog. Each GiftID is a developer product that grants the
	same permanent in-game entitlement to the selected recipient.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Passes = {
	["VIP"] = {
		Enabled = true,
		PassID = 1928329888,
		GiftID = 3611981520,
	},

	-- Limited release: take off sale and disable on the next content update.
	-- Existing native/gifted owners keep the entitlement permanently.
	["Offline Earnings+"] = {
		Enabled = true,
		PassID = 1931016250,
		GiftID = 3611981607,
	},

	["2x Cash"] = {
		Enabled = true,
		PassID = 1928155908,
		GiftID = 3611981574,
	},

	["2x Speed"] = {
		Enabled = true,
		PassID = 1928221965,
		GiftID = 3611986927,
	},
}

export type Passes = typeof(Passes)

return Passes
