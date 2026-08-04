--!strict
--[[
	Developer-product "pack" catalog (bundled item grants, not currency).
	Ported 1:1 from the UISystem dump's
	ReplicatedStorage.Configuration.Packs.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Packs = {
	-- Limited shop offer. The client verifies the live prices before
	-- enabling either button.
	["Limited Themes Pack"] = {
		Enabled = true,
		ProductID = 3612150441,
		GiftID = 3612151351,
		ExpectedPrice = 49,
		ExpectedGiftPrice = 49,
	},
}

export type Packs = typeof(Packs)

return Packs
