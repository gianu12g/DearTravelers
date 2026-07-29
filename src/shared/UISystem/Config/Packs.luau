--!strict
--[[
	Developer-product "pack" catalog (bundled item grants, not currency).
	Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.Packs.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Packs = {
	-- Limited shop offer. These products were originally authored as
	-- "Secret Pack" (purchase) and "Starter Pack" (gift). Rename both in
	-- Creator Dashboard and set both prices to 49 Robux. The client verifies
	-- the live prices before enabling either button.
	["Arcade Themes Pack"] = {
		Enabled = true,
		ProductID = 3596657806,
		GiftID = 3596657710,
		ExpectedPrice = 49,
		ExpectedGiftPrice = 49,
	},
}

export type Packs = typeof(Packs)

return Packs
