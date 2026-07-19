--!strict
--[[
	Developer-product "pack" catalog (bundled item grants, not currency).
	Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.Packs.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Packs = {
	["Starter Pack"] = {
		ProductID = 3596657710, -- Change this to whatever your product ID is
	},

	["Secret Pack"] = {
		ProductID = 3596657806, -- Change this to whatever your product ID is
	},
}

export type Packs = typeof(Packs)

return Packs
