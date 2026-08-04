--!strict
--[[
	ThemeShop pricing (COSMETICS_PLAN.md "shop pass"). Kept separate from
	CosmeticsCatalog (id authority) and from Shared/UISystem/Config/Products
	(the generic developer-product catalog) on purpose -- store logic stays
	fully separate from the ownership/equip backbone, same split the plan's
	"Out of scope" section already called for.

	ONE ticket/gift-ticket developer-product PAIR covers every cosmetic in
	every slot, at the same 299 R$ price. Both receipts grant one durable
	ticket to the PURCHASER; choosing a cosmetic or transferring that ticket
	to another player is a separate server-authoritative action afterward.
	There is deliberately no per-item Robux product: ~130 KeycapThemes alone
	would mean hundreds of Marketplace products to create and keep in sync,
	for a price that never varies.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)

local CosmeticsShopConfig = {}

-- Ticket and gift-ticket developer products. Both cost 299 R$ and both add
-- one ticket to the purchaser's balance. The separate ids preserve distinct
-- storefront copy/analytics; neither receipt contains a cosmetic or recipient.
CosmeticsShopConfig.TICKET_PRODUCT_ID = 3611999891
CosmeticsShopConfig.GIFT_TICKET_PRODUCT_ID = 3611999932
-- Owned-card CashPurchase is an explicit cash ticket exchange. Keep its
-- price independent from per-slot cosmetic tuning so a future cheaper slot
-- cannot become the unintended universal ticket price.
CosmeticsShopConfig.TICKET_CASH_PRICE = 10_000_000

--[[
	Cash price per slot. TUNING KNOBS -- change freely; every reader
	(MonetizationService's cash-buy handler, ThemeShopController's
	CashPurchase price tag) goes through this table, never a hardcoded
	number.

	10,000,000 for KeycapThemes is deliberate cash/Robux parity: "10M Cash"
	(Shared.UISystem.Config.Products) costs the same 299 R$ as
	TICKET_PRODUCT_ID above, so paying with Cash instead of Robux costs the
	cash-equivalent of the same Robux price. SquishyBeams and MergePops
	default to the same figure for the same reason -- there is no price
	differentiation between slots yet, only between payment methods.
]]
local CASH_PRICE: { [CosmeticsCatalog.Slot]: number } = {
	KeycapThemes = 10_000_000,
	SquishyBeams = 10_000_000,
	MergePops = 10_000_000,
}
CosmeticsShopConfig.CASH_PRICE = CASH_PRICE

export type CosmeticsShopConfig = typeof(CosmeticsShopConfig)

return CosmeticsShopConfig
