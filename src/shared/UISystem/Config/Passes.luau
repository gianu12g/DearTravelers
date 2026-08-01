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

	["Auto Merge"] = {
		Enabled = true,
		PassID = 1932824958,
		GiftID = 3612567312,
	},

	["x2 Spawn"] = {
		Enabled = true,
		PassID = 1932854966,
		GiftID = 3612567315,
	},

	["x2 Faster Lock"] = {
		Enabled = true,
		PassID = 1933604878,
		GiftID = 3612567320,
	},

	["x2 Squishy Health"] = {
		Enabled = true,
		PassID = 1933166941,
		GiftID = 3612567538,
	},

	["x2 Faster Launch"] = {
		Enabled = true,
		PassID = 1934084659,
		GiftID = 3612567539,
	},
}

export type Passes = typeof(Passes)

return Passes
