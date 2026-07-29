--!strict
--[[
	Gamepass/product/pack purchases and gifting (PORT-SPEC.md §1, source
	ServerScriptService.Services.MarketplaceService, renamed
	MonetizationService -- "MarketplaceService" would shadow the Roblox
	service of the same name that this file wraps).

	CRITICAL: only one script in the whole game may assign
	MarketplaceService.ProcessReceipt -- a second assignment silently
	replaces the first, and Roblox will keep re-delivering unprocessed
	receipts against whichever one wins, which is exactly the kind of bug
	that only shows up as a support ticket about a lost purchase.
	ProcessReceipt is a write-only callback member -- reading it back to
	check for a prior assignment throws at runtime ("you can only set the
	callback value, get is not available"), so a runtime collision guard
	is IMPOSSIBLE here. A repo-wide grep for ProcessReceipt before this
	port found no existing assignment outside this file (see the
	implementer's report), so Init() below assigns it unconditionally as
	the sole owner; that same repo-wide grep is the only guard against a
	second assignment being introduced elsewhere.

	Cash grants (source: DataService:Increment(player, "Cash", n)) map onto
	the merged Coins balance via CoinsService (PORT-SPEC.md §2) -- see
	Modules/UISystem/ProductRewards.luau.

	Developer-product receipts use a bounded PurchaseId ledger. Rewards are
	mutated and immediately saved before PurchaseGranted is returned. Paid
	gifts are first written into the target profile's durable ProfileStore
	message queue, so the recipient may be offline, in another server, or
	leave while the purchase prompt is open without losing the gift.
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(ServerStorage.Services.CoinsService)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local CosmeticsService = require(ServerStorage.Services.CosmeticsService)
local CosmeticsShopConfig = require(ReplicatedStorage.Shared.CosmeticsShopConfig)
local DataService = require(ServerStorage.Services.DataService)
local General = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PackRewards = require(ServerStorage.Modules.UISystem.PackRewards)
local Packs = require(ReplicatedStorage.Shared.UISystem.Config.Packs)
local PassRewards = require(ServerStorage.Modules.UISystem.PassRewards)
local Passes = require(ReplicatedStorage.Shared.UISystem.Config.Passes)
local ProductRewards = require(ServerStorage.Modules.UISystem.ProductRewards)
local Products = require(ReplicatedStorage.Shared.UISystem.Config.Products)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("MonetizationService")

local MAX_ITEM_NAME_LENGTH = 64
local REWARD_RETRIES = 5
local MAX_PROCESSED_PURCHASE_IDS = 200
local MAX_PROCESSED_VOUCHER_TRANSFER_IDS = 500
local GIFT_MESSAGE_KIND = "MonetizationGift"
local VOUCHER_TRANSFER_MESSAGE_KIND = "VoucherTransferV1"
local OWNED_PURCHASE_CONFIRM_SECONDS = 6
-- A well-formed PendingGifts ring entry otherwise never
-- expires: it's cleared only by a matching receipt or a
-- PromptProductPurchaseFinished decline, neither of which fires for a
-- session that disconnects, crashes, or is shut down while the Roblox prompt
-- is open. Past this many seconds, hasPendingGift treats
-- that one entry as absent rather than a permanent lock -- long enough for
-- Roblox to redeliver a pending receipt after the player's next join, so a
-- genuinely in-flight purchase still resolves instead of being silently
-- dropped.
local PENDING_INTENT_GRACE_SECONDS = 300
-- Same bound as DataService's own MAX_PENDING_INTENTS (duplicated locally,
-- same convention as MAX_PROCESSED_PURCHASE_IDS above) -- the ring append
-- below evicts down to this many entries before persisting.
local MAX_PENDING_INTENTS = 3

type PassEntry = { Enabled: boolean, PassID: number, GiftID: number? }
type ProductEntry = { ProductID: number, GiftID: number? }
type PackEntry = {
	Enabled: boolean,
	ProductID: number,
	GiftID: number?,
	ExpectedGiftPrice: number?,
}

--[[
	Shared/UISystem/Config/{Passes,Products,Packs}.luau are each typed via
	typeof(<table literal>) -- a SEALED record with one field per item name,
	not an indexed map. That's fine for `Config.Passes.VIP`, useless for the
	dynamic `Config.Passes[passName]` lookups this entire gifting/purchase
	flow is built on (the item name always arrives over the wire or off a
	ProductId match, never as a literal). The double cast (through `any`) is
	Luau's escape hatch for "these types are structurally unrelated, but
	every entry has been checked to share this shape" -- checked against the
	dumped config content directly, not guessed.
]]
local PassesByName = (Passes :: any) :: { [string]: PassEntry }
local ProductsByName = (Products :: any) :: { [string]: ProductEntry }
local PacksByName = (Packs :: any) :: { [string]: PackEntry }

type ProductInfo = {
	kind: "PassGift" | "ProductPurchase" | "ProductGift" | "PackPurchase" | "PackGift" | "VoucherPurchase" | "Unknown",
	name: string,
}

local processingReceipts: { [Player]: true } = {}
local voucherActionBusy: { [Player]: true } = {}
local voucherTransferFlushBusy: { [Player]: true } = {}
local voucherTransferRetryScheduled: { [Player]: true } = {}
type OwnedPurchaseConfirmation = { Key: string, ExpiresAt: number }
type OwnedPurchaseConfirmations = { [Player]: OwnedPurchaseConfirmation }
local ownedVoucherPurchaseConfirmations: OwnedPurchaseConfirmations = {}
local ownedCashPurchaseConfirmations: OwnedPurchaseConfirmations = {}
local giftStartLimiter = RateLimiter.new(0.2, 1)
-- Owned cards deliberately require two prompt clicks. Keep the burst at two
-- so the confirmation click is not discarded, while the refill still
-- throttles sustained packet spam.
local voucherPurchaseLimiter = RateLimiter.new(2, 2)
local voucherGiftLimiter = RateLimiter.new(0.2, 1)
local cosmeticCashBuyLimiter = RateLimiter.new(0.5, 2)
local warnedUnavailableRewards: { [string]: true } = {}
local warnedReceipts: { [string]: true } = {}

local function warnUnavailableReward(kind: string, itemName: string, playerName: string)
	local key = `{kind}:{itemName}`
	if warnedUnavailableRewards[key] then
		return
	end
	warnedUnavailableRewards[key] = true
	log.warn(`{kind} reward "{itemName}" is unavailable for {playerName}; further warnings suppressed`)
end

local function warnReceiptOnce(purchaseId: string, message: string)
	if warnedReceipts[purchaseId] then
		return
	end
	warnedReceipts[purchaseId] = true
	log.error(message .. "; further warnings for this receipt suppressed")
end

-- Display name for a cosmetic notification/toast. Falls back to the raw id
-- if it somehow isn't in the catalog (can't happen for a call site that
-- already validated the id, but a label is never worth an error).
local function cosmeticLabel(slot: CosmeticsCatalog.Slot, id: string): string
	for _, entry in CosmeticsCatalog.catalogForSlot(slot) do
		if entry.Id == id then
			return entry.DisplayName
		end
	end
	return id
end

local function confirmOwnedPurchase(
	confirmations: OwnedPurchaseConfirmations,
	player: Player,
	key: string,
	message: string
): boolean
	local now = os.clock()
	local current = confirmations[player]
	if current ~= nil and current.Key == key and current.ExpiresAt >= now then
		confirmations[player] = nil
		return true
	end
	confirmations[player] = {
		Key = key,
		ExpiresAt = now + OWNED_PURCHASE_CONFIRM_SECONDS,
	}
	UINotificationService.SendNotification(player, "Info", message)
	return false
end

local function hasProcessedPurchase(data: DataService.PlayerData, purchaseId: string): boolean
	local ids = (data.UISystem.ProcessedPurchaseIds :: any) :: { string }
	return table.find(ids, purchaseId) ~= nil
end

local function appendProcessedPurchase(data: DataService.PlayerData, purchaseId: string): { string }
	local ids = (data.UISystem.ProcessedPurchaseIds :: any) :: { string }
	local updated = table.clone(ids)
	table.insert(updated, purchaseId)
	while #updated > MAX_PROCESSED_PURCHASE_IDS do
		table.remove(updated, 1)
	end
	return updated
end

local function savedPurchaseExists(savedData: any, purchaseId: string): boolean
	return type(savedData) == "table"
		and type(savedData.UISystem) == "table"
		and type(savedData.UISystem.ProcessedPurchaseIds) == "table"
		and table.find(savedData.UISystem.ProcessedPurchaseIds, purchaseId) ~= nil
end

local function hasProcessedVoucherTransfer(data: DataService.PlayerData, transferId: string): boolean
	return table.find(data.UISystem.ProcessedVoucherTransferIds, transferId) ~= nil
end

local function appendProcessedVoucherTransfer(data: DataService.PlayerData, transferId: string): { string }
	local updated = table.clone(data.UISystem.ProcessedVoucherTransferIds)
	table.insert(updated, transferId)
	while #updated > MAX_PROCESSED_VOUCHER_TRANSFER_IDS do
		table.remove(updated, 1)
	end
	return updated
end

local function isValidUserId(value: unknown): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
		and value == math.floor(value)
end

local function getProductInfo(productId: number): ProductInfo
	-- Both ThemeShop products pay out the same fungible voucher to the
	-- purchaser. Theme and recipient selection happen only after this receipt.
	if
		productId == CosmeticsShopConfig.VOUCHER_PRODUCT_ID
		or productId == CosmeticsShopConfig.GIFT_VOUCHER_PRODUCT_ID
	then
		return { kind = "VoucherPurchase", name = "Theme Ticket" }
	end

	for passName, passInfo in PassesByName do
		if passInfo.GiftID == productId then
			return { kind = "PassGift", name = passName }
		end
	end
	for productName, productInfo in ProductsByName do
		if productInfo.ProductID == productId then
			return { kind = "ProductPurchase", name = productName }
		elseif productInfo.GiftID == productId then
			return { kind = "ProductGift", name = productName }
		end
	end
	for packName, packInfo in PacksByName do
		if packInfo.ProductID == productId then
			return { kind = "PackPurchase", name = packName }
		elseif packInfo.GiftID == productId then
			return { kind = "PackGift", name = packName }
		end
	end
	return { kind = "Unknown", name = "" }
end

local function passOwned(targetUserId: number, passName: string): boolean?
	local target = Players:GetPlayerByUserId(targetUserId)
	local data = if target ~= nil then DataService.getData(target) else nil
	if data ~= nil then
		local giftedPasses = (data.UISystem.GiftedPasses :: any) :: { [string]: boolean }
		if giftedPasses[passName] then
			return true
		end
	end

	local passInfo = PassesByName[passName]
	if passInfo == nil then
		return nil
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(targetUserId, passInfo.PassID)
	end)
	return if ok then owned == true else nil
end

local function notifyGiftSent(target: Player, gifterUserId: number?, itemLabel: string)
	local gifter = if gifterUserId ~= nil then Players:GetPlayerByUserId(gifterUserId) else nil
	if gifter ~= nil then
		UINotificationService.SendNotification(gifter, "Success", "Sent gift successfully")
		UINotificationService.EmitConfetti(gifter)
	end
	UINotificationService.SendNotification(target, "Success", `Someone sent you {itemLabel}`)
end

local function runReward(rewardFunction: (Player) -> boolean, target: Player): boolean
	local lastError: any = nil
	for _ = 1, REWARD_RETRIES do
		local ok, granted = pcall(rewardFunction, target)
		if ok then
			return granted == true
		end
		lastError = granted
	end
	log.warn(`reward failed for {target.Name}: {tostring(lastError)}`)
	return false
end

local function givePass(
	target: Player,
	passName: string,
	isGift: boolean,
	gifterUserId: number?,
	isNew: boolean
): boolean
	local rewardFunction = PassRewards[passName]
	if rewardFunction == nil or not runReward(rewardFunction, target) then
		warnUnavailableReward("pass", passName, target.Name)
		return false
	end

	if isGift then
		DataService.set(target, { "UISystem", "GiftedPasses", passName }, true)
	end

	if not isNew then
		return true
	end

	if isGift then
		notifyGiftSent(target, gifterUserId, `the {passName} gamepass`)
	else
		UINotificationService.SendNotification(target, "Success", `Purchased {passName} gamepass successfully`)
		UINotificationService.EmitConfetti(target)
	end
	return true
end

local function giveProduct(
	target: Player,
	productName: string,
	isGift: boolean,
	gifterUserId: number?,
	isNew: boolean
): boolean
	local rewardFunction = ProductRewards[productName]
	if rewardFunction == nil or not runReward(rewardFunction, target) then
		warnUnavailableReward("product", productName, target.Name)
		return false
	end

	if not isNew then
		return true
	end

	if isGift then
		notifyGiftSent(target, gifterUserId, productName)
	else
		UINotificationService.SendNotification(target, "Success", `Purchased {productName} successfully`)
		UINotificationService.EmitConfetti(target)
	end
	return true
end

-- Gift delivery, called from the RECIPIENT's server when their durable
-- message is processed (onGiftMessage below) -- mirrors givePass/giveProduct's
-- isGift=true path, including notifyGiftSent's "tell the gifter too, if
-- they're still online somewhere" best effort.
local function giveCosmeticGift(target: Player, slot: CosmeticsCatalog.Slot, id: string): (boolean, boolean)
	local data = DataService.getData(target)
	if data == nil then
		return false, false
	end
	if table.find(data.Cosmetics.Owned[slot], id) ~= nil then
		-- This path only handles already-paid legacy cosmetic gift messages.
		-- A duplicate must still deliver value, but CosmeticsService.grant()
		-- deliberately treats "already owned" as an idempotent no-op.
		return true, true
	end
	if not CosmeticsService.grant(target, slot, id) then
		warnUnavailableReward("cosmetic", `{slot}:{id}`, target.Name)
		return false, false
	end
	return true, false
end

local function givePack(player: Player, packName: string, isGift: boolean, gifterUserId: number?): boolean
	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local packs = (data.UISystem.Packs :: any) :: { string }
	if table.find(packs, packName) ~= nil then
		return true
	end

	local rewardFunction = PackRewards[packName]
	if rewardFunction == nil or not runReward(rewardFunction, player) then
		warnUnavailableReward("pack", packName, player.Name)
		return false
	end

	local updated = table.clone(packs)
	table.insert(updated, packName)
	DataService.set(player, { "UISystem", "Packs" }, updated)

	if isGift then
		notifyGiftSent(player, gifterUserId, packName)
	else
		UINotificationService.SendNotification(player, "Success", `Purchased {packName} successfully`)
		UINotificationService.EmitConfetti(player)
	end
	return true
end

-- Evicts from the front (oldest) once the ring exceeds MAX_PENDING_INTENTS,
-- same "keep the newest" shape as DataService's own repairPendingGifts and
-- appendProcessedPurchase above.
local function appendPendingGift(
	current: { DataService.PendingGiftEntry },
	entry: DataService.PendingGiftEntry
): { DataService.PendingGiftEntry }
	local updated = table.clone(current)
	table.insert(updated, entry)
	while #updated > MAX_PENDING_INTENTS do
		table.remove(updated, 1)
	end
	return updated
end

local function savedGiftIntentExists(
	savedData: any,
	kind: string,
	itemName: string,
	targetUserId: number,
	productId: number,
	startedAt: number
): boolean
	local saved = if type(savedData) == "table" and type(savedData.UISystem) == "table"
		then savedData.UISystem.PendingGifts
		else nil
	if type(saved) ~= "table" then
		return false
	end
	for _, entry in saved do
		if
			type(entry) == "table"
			and entry.Kind == kind
			and entry.ItemName == itemName
			and entry.TargetUserId == targetUserId
			and entry.ProductId == productId
			and entry.StartedAt == startedAt
		then
			return true
		end
	end
	return false
end

-- Appends one entry onto the gifter's PendingGifts ring (evicting the oldest
-- past MAX_PENDING_INTENTS) and durably persists it before the purchase
-- prompt opens. `data` is re-read here rather than accepted from the caller:
-- every call site either has no yield before this call (so it's equivalent)
-- or -- startPassGift's ownership check -- DOES yield first, and a re-read
-- here guarantees the ring this function appends onto
-- reflects anything a racing request from the same player already persisted
-- during that yield, not a stale snapshot from before it.
local function persistGiftIntent(
	gifter: Player,
	kind: "Pass" | "Product" | "Pack",
	itemName: string,
	targetUserId: number,
	productId: number
): boolean
	local data = DataService.getData(gifter)
	if data == nil then
		return false
	end
	local startedAt = os.time()
	local entry: DataService.PendingGiftEntry =
		{ Kind = kind, ItemName = itemName, TargetUserId = targetUserId, ProductId = productId, StartedAt = startedAt }
	local before = data.UISystem.PendingGifts
	DataService.set(gifter, { "UISystem", "PendingGifts" }, appendPendingGift(before, entry))
	local verified = DataService.saveAndAwait(gifter, function(savedData: any)
		return savedGiftIntentExists(savedData, kind, itemName, targetUserId, productId, startedAt)
	end, 30)
	if not verified then
		-- Save failed or timed out verifying -- remove the just-appended entry
		-- from the in-memory replica rather than leaving a stuck one. This is
		-- belt-and-braces, not the primary defence: PENDING_INTENT_GRACE_SECONDS
		-- (see hasPendingGift) is what actually guarantees the player isn't
		-- blocked forever if even this best-effort clear doesn't reach the
		-- durable store before the session ends. Best effort, result ignored --
		-- there is nothing else to try.
		DataService.set(gifter, { "UISystem", "PendingGifts" }, before)
		DataService.saveAndAwait(gifter, function(savedData: any)
			return not savedGiftIntentExists(savedData, kind, itemName, targetUserId, productId, startedAt)
		end, 10)
	end
	return verified
end

-- An entry present in the ring is not, on its own, still a block: past the
-- grace window it's either a completed-but-unacknowledged receipt (which
-- still needs the intent, so it's NOT cleared here -- Roblox redelivers it on
-- the player's next join and processReceiptForPlayer will read it) or a
-- purchase that was abandoned by a disconnect/crash with no receipt ever
-- coming (which this grace window exists to stop from blocking forever).
-- Either way, treating it as absent lets the player start a new purchase;
-- a genuinely in-flight receipt is still honored when it arrives.
local function hasPendingGift(player: Player): boolean
	local data = DataService.getData(player)
	if data == nil then
		return false
	end
	local now = os.time()
	for _, entry in data.UISystem.PendingGifts do
		if now - entry.StartedAt < PENDING_INTENT_GRACE_SECONDS then
			return true
		end
	end
	return false
end

local function startPassGift(gifter: Player, passName: string, targetUserId: number)
	if hasPendingGift(gifter) then
		UINotificationService.SendNotification(gifter, "Error", "Your previous purchase is still resolving")
		return
	end
	local owned = passOwned(targetUserId, passName)
	if owned == nil then
		UINotificationService.SendNotification(gifter, "Error", "Ownership could not be verified. Please try again.")
		return
	end
	if owned then
		UINotificationService.SendNotification(gifter, "Error", "Player already owns the gamepass")
		return
	end

	-- passOwned above yields inside UserOwnsGamePassAsync, wide enough for a
	-- second gift-start call from the
	-- same player to persist its own intent in the gap between the gate check
	-- above and here. Re-check right before the intent write so that racing
	-- call is caught instead of both proceeding.
	if hasPendingGift(gifter) then
		UINotificationService.SendNotification(gifter, "Error", "Your previous purchase is still resolving")
		return
	end

	local giftProductId = PassesByName[passName].GiftID
	if giftProductId == nil then
		UINotificationService.SendNotification(gifter, "Error", "That gamepass can't be gifted")
		return
	end

	if not persistGiftIntent(gifter, "Pass", passName, targetUserId, giftProductId) then
		UINotificationService.SendNotification(gifter, "Error", "Gift could not be prepared. Please try again.")
		return
	end
	Net.promptStart.sendTo(nil, gifter)
	MarketplaceService:PromptProductPurchase(gifter, giftProductId)
end

local function startProductGift(gifter: Player, productName: string, targetUserId: number)
	if hasPendingGift(gifter) then
		UINotificationService.SendNotification(gifter, "Error", "Your previous purchase is still resolving")
		return
	end
	local giftProductId = ProductsByName[productName].GiftID
	if giftProductId == nil then
		UINotificationService.SendNotification(gifter, "Error", "That item can't be gifted")
		return
	end

	if not persistGiftIntent(gifter, "Product", productName, targetUserId, giftProductId) then
		UINotificationService.SendNotification(gifter, "Error", "Gift could not be prepared. Please try again.")
		return
	end
	Net.promptStart.sendTo(nil, gifter)
	MarketplaceService:PromptProductPurchase(gifter, giftProductId)
end

local function startPackGift(gifter: Player, packName: string, targetUserId: number)
	if hasPendingGift(gifter) then
		UINotificationService.SendNotification(gifter, "Error", "Your previous purchase is still resolving")
		return
	end

	local packInfo = PacksByName[packName]
	local giftProductId = if packInfo ~= nil then packInfo.GiftID else nil
	if giftProductId == nil or giftProductId <= 0 then
		UINotificationService.SendNotification(gifter, "Error", "That pack can't be gifted")
		return
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	local targetData = if target ~= nil then DataService.getData(target) else nil
	if targetData == nil then
		UINotificationService.SendNotification(gifter, "Error", "That player is no longer available")
		return
	end
	if table.find(targetData.UISystem.Packs, packName) ~= nil then
		UINotificationService.SendNotification(gifter, "Error", "Player already owns this pack")
		return
	end

	local expectedPrice = packInfo.ExpectedGiftPrice
	if expectedPrice ~= nil then
		local ok, productInfo = pcall(function()
			return MarketplaceService:GetProductInfoAsync(giftProductId, Enum.InfoType.Product)
		end)
		if not ok or productInfo == nil or productInfo.PriceInRobux ~= expectedPrice then
			UINotificationService.SendNotification(gifter, "Error", "That pack gift is not available yet")
			return
		end
	end

	if hasPendingGift(gifter) then
		UINotificationService.SendNotification(gifter, "Error", "Your previous purchase is still resolving")
		return
	end
	if not persistGiftIntent(gifter, "Pack", packName, targetUserId, giftProductId) then
		UINotificationService.SendNotification(gifter, "Error", "Gift could not be prepared. Please try again.")
		return
	end
	Net.promptStart.sendTo(nil, gifter)
	MarketplaceService:PromptProductPurchase(gifter, giftProductId)
end

local function onGiftStart(data: { targetUserId: number, itemKind: string, itemName: string }, player: Player)
	local targetUserId = data.targetUserId
	local itemKind = data.itemKind
	local itemName = data.itemName

	if not isValidUserId(targetUserId) then
		return
	end
	if targetUserId == player.UserId then
		UINotificationService.SendNotification(player, "Error", "You can't gift yourself")
		return
	end
	if itemKind ~= "Pass" and itemKind ~= "Product" and itemKind ~= "Pack" then
		return
	end
	if typeof(itemName) ~= "string" or #itemName == 0 or #itemName > MAX_ITEM_NAME_LENGTH then
		return
	end

	local fromAdmin = table.find(General.Admins, player.UserId) ~= nil
	local target = Players:GetPlayerByUserId(targetUserId)

	if itemKind == "Pass" then
		local passInfo = PassesByName[itemName]
		if passInfo == nil or not passInfo.Enabled then
			UINotificationService.SendNotification(player, "Error", "That gamepass is not available yet")
			return
		end
		if fromAdmin then
			if target == nil or not givePass(target, itemName, true, player.UserId, true) then
				UINotificationService.SendNotification(player, "Error", "The admin gift could not be granted")
			end
			return
		end
		startPassGift(player, itemName, targetUserId)
	elseif itemKind == "Product" then
		if ProductsByName[itemName] == nil then
			return
		end
		if fromAdmin then
			if target == nil or not giveProduct(target, itemName, true, player.UserId, true) then
				UINotificationService.SendNotification(player, "Error", "The admin gift could not be granted")
			end
			return
		end
		startProductGift(player, itemName, targetUserId)
	else
		local packInfo = PacksByName[itemName]
		if packInfo == nil or not packInfo.Enabled then
			UINotificationService.SendNotification(player, "Error", "That pack is not available yet")
			return
		end
		if fromAdmin then
			if target == nil or not givePack(target, itemName, true, player.UserId) then
				UINotificationService.SendNotification(player, "Error", "The admin gift could not be granted")
			end
			return
		end
		startPackGift(player, itemName, targetUserId)
	end
end

local function isValidSlotValue(value: unknown): boolean
	return value == "KeycapThemes" or value == "SquishyBeams" or value == "MergePops"
end

-- Shared by the ThemeShop packet handlers: known slot and catalog/id-length
-- bounds. Defaults are accepted because CashPurchase on any owned card is an
-- intentional cash-to-voucher duplicate conversion; voucher redemption still
-- rejects ownership below.
local function validateCosmeticRequest(slotValue: unknown, idValue: unknown): (boolean, CosmeticsCatalog.Slot?, string?)
	if not isValidSlotValue(slotValue) then
		return false, nil, nil
	end
	if typeof(idValue) ~= "string" or #idValue == 0 or #idValue > MAX_ITEM_NAME_LENGTH then
		return false, nil, nil
	end
	local slot = slotValue :: CosmeticsCatalog.Slot
	if not CosmeticsCatalog.isValidId(slot, idValue) then
		return false, nil, nil
	end
	return true, slot, idValue
end

local function promptVoucherProduct(player: Player, productId: number)
	if hasPendingGift(player) then
		UINotificationService.SendNotification(player, "Error", "Your previous purchase is still resolving")
		return
	end
	local ok, promptError = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	if not ok then
		log.warn(`failed to open voucher prompt for {player.Name}: {tostring(promptError)}`)
		UINotificationService.SendNotification(player, "Error", "The purchase prompt could not be opened")
		return
	end
	Net.promptStart.sendTo(nil, player)
end

local function savedCosmeticOwned(savedData: any, slot: CosmeticsCatalog.Slot, id: string): boolean
	return type(savedData) == "table"
		and type(savedData.Cosmetics) == "table"
		and type(savedData.Cosmetics.Owned) == "table"
		and type(savedData.Cosmetics.Owned[slot]) == "table"
		and table.find(savedData.Cosmetics.Owned[slot], id) ~= nil
end

local function redeemVoucher(player: Player, slot: CosmeticsCatalog.Slot, id: string)
	local data = DataService.getData(player)
	if data == nil then
		return
	end
	if table.find(data.Cosmetics.Owned[slot], id) ~= nil then
		UINotificationService.SendNotification(player, "Error", "You already own this")
		return
	end
	if data.UISystem.Vouchers <= 0 then
		promptVoucherProduct(player, CosmeticsShopConfig.VOUCHER_PRODUCT_ID)
		return
	end

	-- Cooperative Luau cannot interleave these two non-yielding mutations.
	-- Any saved snapshot therefore contains both the entitlement and debit.
	local owned = table.clone(data.Cosmetics.Owned)
	local slotOwned = table.clone(owned[slot])
	table.insert(slotOwned, id)
	owned[slot] = slotOwned
	DataService.set(player, { "Cosmetics", "Owned" }, owned)
	DataService.set(player, { "UISystem", "Vouchers" }, data.UISystem.Vouchers - 1)

	local saved = DataService.saveAndAwait(player, function(savedData: any)
		return savedCosmeticOwned(savedData, slot, id)
	end, 30)
	if not saved then
		-- The receipt-created voucher was already durable. A crash before this
		-- redemption saves restores that voucher, so value cannot be lost.
		log.warn(`voucher redemption for {player.Name} is still awaiting a durable save`)
	end
	UINotificationService.SendNotification(player, "Success", `Claimed {cosmeticLabel(slot, id)} successfully`)
	UINotificationService.EmitConfetti(player)
end

local function savedVoucherTransferExists(
	savedData: any,
	transferId: string,
	targetUserId: number,
	requestId: string
): boolean
	local pending = if type(savedData) == "table" and type(savedData.UISystem) == "table"
		then savedData.UISystem.PendingVoucherTransfers
		else nil
	if type(pending) ~= "table" then
		return false
	end
	for _, entry in pending do
		if
			type(entry) == "table"
			and entry.TransferId == transferId
			and entry.TargetUserId == targetUserId
			and entry.RequestId == requestId
		then
			return true
		end
	end
	return false
end

local function savedVoucherTransferAbsent(savedData: any, transferId: string): boolean
	local pending = if type(savedData) == "table" and type(savedData.UISystem) == "table"
		then savedData.UISystem.PendingVoucherTransfers
		else nil
	if type(pending) ~= "table" then
		return false
	end
	for _, entry in pending do
		if type(entry) == "table" and entry.TransferId == transferId then
			return false
		end
	end
	return true
end

local function removePendingVoucherTransfer(
	pending: { DataService.PendingVoucherTransferEntry },
	transferId: string
): { DataService.PendingVoucherTransferEntry }
	local updated = table.clone(pending)
	for index, entry in updated do
		if entry.TransferId == transferId then
			table.remove(updated, index)
			break
		end
	end
	return updated
end

local flushPendingVoucherTransfers: (Player) -> ()

local function scheduleVoucherTransferRetry(player: Player)
	if voucherTransferRetryScheduled[player] or player.Parent ~= Players then
		return
	end
	voucherTransferRetryScheduled[player] = true
	task.delay(15, function()
		voucherTransferRetryScheduled[player] = nil
		if player.Parent == Players then
			flushPendingVoucherTransfers(player)
		end
	end)
end

flushPendingVoucherTransfers = function(player: Player)
	if voucherTransferFlushBusy[player] or player.Parent ~= Players then
		return
	end
	voucherTransferFlushBusy[player] = true
	local retryNeeded = false
	local ok, flushError = xpcall(function()
		if not DataService.awaitData(player, 30) then
			return
		end
		while player.Parent == Players do
			local data = DataService.getData(player)
			local entry = if data ~= nil then data.UISystem.PendingVoucherTransfers[1] else nil
			if data == nil or entry == nil then
				break
			end

			local durable = DataService.saveAndAwait(player, function(savedData: any)
				return savedVoucherTransferExists(savedData, entry.TransferId, entry.TargetUserId, entry.RequestId)
			end, 30)
			if not durable then
				retryNeeded = true
				break
			end

			local sent = DataService.messagePlayer(entry.TargetUserId, {
				Kind = VOUCHER_TRANSFER_MESSAGE_KIND,
				TransferId = entry.TransferId,
				GifterUserId = player.UserId,
			})
			if not sent then
				retryNeeded = true
				break
			end

			local latest = DataService.getData(player)
			if latest == nil then
				break
			end
			DataService.set(
				player,
				{ "UISystem", "PendingVoucherTransfers" },
				removePendingVoucherTransfer(latest.UISystem.PendingVoucherTransfers, entry.TransferId)
			)
			DataService.saveAndAwait(player, function(savedData: any)
				return savedVoucherTransferAbsent(savedData, entry.TransferId)
			end, 30)
			UINotificationService.SendNotification(player, "Success", "Theme Ticket sent successfully")
			UINotificationService.EmitConfetti(player)
			Net.voucherGiftResult.sendTo({ ok = true, requestId = entry.RequestId }, player)
		end
	end, debug.traceback)
	voucherTransferFlushBusy[player] = nil
	if not ok then
		log.error(`voucher transfer flush failed for {player.Name}: {tostring(flushError)}`)
		retryNeeded = true
	end
	if retryNeeded then
		scheduleVoucherTransferRetry(player)
	end
end

local function queueVoucherTransfer(player: Player, targetUserId: number, requestId: string)
	local data = DataService.getData(player)
	if data == nil then
		Net.voucherGiftResult.sendTo({ ok = false, requestId = requestId }, player)
		return
	end
	if #data.UISystem.PendingVoucherTransfers > 0 then
		UINotificationService.SendNotification(player, "Error", "Your previous ticket gift is still resolving")
		Net.voucherGiftResult.sendTo({ ok = false, requestId = requestId }, player)
		flushPendingVoucherTransfers(player)
		return
	end
	if data.UISystem.Vouchers <= 0 then
		Net.voucherGiftResult.sendTo({ ok = false, requestId = requestId }, player)
		promptVoucherProduct(player, CosmeticsShopConfig.GIFT_VOUCHER_PRODUCT_ID)
		return
	end

	local entry: DataService.PendingVoucherTransferEntry = {
		TransferId = HttpService:GenerateGUID(false),
		TargetUserId = targetUserId,
		RequestId = requestId,
	}
	DataService.setValues(player, { "UISystem" }, {
		Vouchers = data.UISystem.Vouchers - 1,
		PendingVoucherTransfers = { entry },
	})
	local durable = DataService.saveAndAwait(player, function(savedData: any)
		return savedVoucherTransferExists(savedData, entry.TransferId, targetUserId, requestId)
	end, 30)
	if not durable then
		UINotificationService.SendNotification(player, "Error", "Your ticket gift is queued and still syncing")
		Net.voucherGiftResult.sendTo({ ok = false, requestId = requestId }, player)
		scheduleVoucherTransferRetry(player)
		return
	end
	UINotificationService.SendNotification(player, "Success", "Theme Ticket gift queued")
	task.spawn(flushPendingVoucherTransfers, player)
end

local function runVoucherAction(player: Player, action: () -> ()): boolean
	if voucherActionBusy[player] then
		UINotificationService.SendNotification(player, "Error", "Your ticket action is still resolving")
		return false
	end
	voucherActionBusy[player] = true
	local ok, actionError = xpcall(action, debug.traceback)
	voucherActionBusy[player] = nil
	if not ok then
		log.error(`voucher action failed for {player.Name}: {tostring(actionError)}`)
		UINotificationService.SendNotification(player, "Error", "Ticket action failed. Please try again.")
		return false
	end
	return true
end

local function onVoucherPurchase(data: { slot: string, id: string }, player: Player)
	local valid, slot, id = validateCosmeticRequest(data.slot, data.id)
	if not valid or slot == nil or id == nil then
		return
	end
	runVoucherAction(player, function()
		if not DataService.awaitData(player, 10) then
			return
		end
		local playerData = DataService.getData(player)
		if playerData == nil then
			return
		end
		if table.find(playerData.Cosmetics.Owned[slot], id) ~= nil then
			local confirmed = confirmOwnedPurchase(
				ownedVoucherPurchaseConfirmations,
				player,
				`{slot}:{id}`,
				`You already own {cosmeticLabel(slot, id)}. Click Purchase again within {OWNED_PURCHASE_CONFIRM_SECONDS}s to buy 1 Theme Ticket.`
			)
			if not confirmed then
				return
			end
			promptVoucherProduct(player, CosmeticsShopConfig.VOUCHER_PRODUCT_ID)
		else
			ownedVoucherPurchaseConfirmations[player] = nil
			redeemVoucher(player, slot, id)
		end
	end)
end

local function onVoucherGift(data: { targetUserId: number, requestId: string }, player: Player)
	if #data.requestId == 0 or #data.requestId > 128 then
		return
	end
	if not isValidUserId(data.targetUserId) then
		Net.voucherGiftResult.sendTo({ ok = false, requestId = data.requestId }, player)
		return
	end
	if data.targetUserId == player.UserId then
		UINotificationService.SendNotification(player, "Error", "You can't gift yourself")
		Net.voucherGiftResult.sendTo({ ok = false, requestId = data.requestId }, player)
		return
	end
	local completed = runVoucherAction(player, function()
		if not DataService.awaitData(player, 10) then
			Net.voucherGiftResult.sendTo({ ok = false, requestId = data.requestId }, player)
			return
		end
		queueVoucherTransfer(player, data.targetUserId, data.requestId)
	end)
	if not completed then
		Net.voucherGiftResult.sendTo({ ok = false, requestId = data.requestId }, player)
	end
end

local function onCosmeticCashBuy(data: { slot: string, id: string }, player: Player)
	local ok, slot, id = validateCosmeticRequest(data.slot, data.id)
	if not ok or slot == nil or id == nil then
		return
	end
	if not DataService.awaitData(player, 10) then
		return
	end
	local playerData = DataService.getData(player)
	if playerData == nil then
		return
	end
	local alreadyOwned = table.find(playerData.Cosmetics.Owned[slot], id) ~= nil

	if alreadyOwned then
		local confirmed = confirmOwnedPurchase(
			ownedCashPurchaseConfirmations,
			player,
			`{slot}:{id}`,
			`You already own {cosmeticLabel(slot, id)}. Click Cash Purchase again within {OWNED_PURCHASE_CONFIRM_SECONDS}s to buy 1 Theme Ticket.`
		)
		if not confirmed then
			return
		end
	else
		ownedCashPurchaseConfirmations[player] = nil
	end

	local cost = if alreadyOwned then CosmeticsShopConfig.VOUCHER_CASH_PRICE else CosmeticsShopConfig.CASH_PRICE[slot]
	if not CoinsService.trySpend(player, cost) then
		UINotificationService.SendNotification(player, "Error", "You don't have enough cash")
		return
	end

	if alreadyOwned then
		DataService.set(player, { "UISystem", "Vouchers" }, playerData.UISystem.Vouchers + 1)
		UINotificationService.SendNotification(
			player,
			"Success",
			`You already owned {cosmeticLabel(slot, id)}, so you received 1 Theme Ticket`
		)
		UINotificationService.EmitConfetti(player)
		return
	end

	if not CosmeticsService.grant(player, slot, id) then
		-- The deduction already committed inside trySpend -- refund it rather
		-- than silently taking the player's cash for a grant that failed.
		CoinsService.add(player, cost)
		UINotificationService.SendNotification(player, "Error", "Purchase failed. Please try again.")
		return
	end

	UINotificationService.SendNotification(player, "Success", `Purchased {cosmeticLabel(slot, id)} successfully`)
	UINotificationService.EmitConfetti(player)
end

type ReceiptInfo = { PlayerId: number, ProductId: number, PurchaseId: string }

-- Searches the PendingGifts ring for the entry this receipt is for. Returns
-- the entry's index (so the caller can remove exactly that one entry, never
-- the whole ring) alongside the entry itself; nil, nil on no match. Earliest
-- match wins -- entries are appended oldest-to-newest, so this is the
-- oldest still-pending intent for this product, the natural "this receipt is
-- for whichever attempt has been waiting longest" tie-break when more than
-- one entry could otherwise match.
local function findPendingGiftEntry(
	data: DataService.PlayerData,
	info: ProductInfo,
	productId: number
): (number?, DataService.PendingGiftEntry?)
	local expectedKind = if info.kind == "PassGift" then "Pass" elseif info.kind == "PackGift" then "Pack" else "Product"
	for index, entry in data.UISystem.PendingGifts do
		if
			entry.Kind == expectedKind
			and entry.ItemName == info.name
			and entry.ProductId == productId
			and isValidUserId(entry.TargetUserId)
		then
			return index, entry
		end
	end
	return nil, nil
end

local function removePendingGiftAt(
	list: { DataService.PendingGiftEntry },
	index: number
): { DataService.PendingGiftEntry }
	local updated = table.clone(list)
	table.remove(updated, index)
	return updated
end

-- A paid-gift receipt yields while MessageAsync queues delivery. Remove the
-- exact intent it matched from the latest ring after that yield rather than a
-- captured numeric index, which may now point at another entry.
local function removeMatchingPendingGift(
	list: { DataService.PendingGiftEntry },
	matched: DataService.PendingGiftEntry
): { DataService.PendingGiftEntry }
	local updated = table.clone(list)
	for index, entry in updated do
		if
			entry.Kind == matched.Kind
			and entry.ItemName == matched.ItemName
			and entry.TargetUserId == matched.TargetUserId
			and entry.ProductId == matched.ProductId
			and entry.StartedAt == matched.StartedAt
		then
			table.remove(updated, index)
			break
		end
	end
	return updated
end

local function processReceiptForPlayer(receiptInfo: ReceiptInfo, player: Player): Enum.ProductPurchaseDecision
	if #receiptInfo.PurchaseId == 0 or #receiptInfo.PurchaseId > 128 then
		log.error(`invalid PurchaseId received for product {receiptInfo.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not DataService.awaitData(player, 60) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = DataService.getData(player)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- A previous attempt may have granted the reward but timed out while
	-- waiting for the DataStore. Never grant twice; just keep driving the
	-- same PurchaseId to durable storage.
	if hasProcessedPurchase(data, receiptInfo.PurchaseId) then
		local saved = DataService.saveAndAwait(player, function(savedData: any)
			return savedPurchaseExists(savedData, receiptInfo.PurchaseId)
		end, 30)
		return if saved
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local info = getProductInfo(receiptInfo.ProductId)
	if info.kind == "Unknown" then
		-- A stale/misconfigured product must remain retryable. Acknowledging it
		-- would permanently discard a paid purchase with no reward.
		warnReceiptOnce(
			receiptInfo.PurchaseId,
			`unrecognised product id {receiptInfo.ProductId} purchased by {player.Name}`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = false
	-- Retain the stable entry identity, not its array index: MessageAsync
	-- yields, so another prompt may append/remove ring entries before the
	-- receipt finishes.
	local matchedGiftEntry: DataService.PendingGiftEntry? = nil
	if info.kind == "PassGift" or info.kind == "ProductGift" or info.kind == "PackGift" then
		local index, entry = findPendingGiftEntry(data, info, receiptInfo.ProductId)
		if index == nil or entry == nil then
			warnReceiptOnce(
				receiptInfo.PurchaseId,
				`receipt {receiptInfo.PurchaseId} has no matching durable gift intent for {player.Name}`
			)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		matchedGiftEntry = entry
		granted = DataService.messagePlayer(entry.TargetUserId, {
			Kind = GIFT_MESSAGE_KIND,
			PurchaseId = receiptInfo.PurchaseId,
			RewardKind = if info.kind == "PassGift"
				then "Pass"
				elseif info.kind == "PackGift" then "Pack"
				else "Product",
			ItemName = info.name,
			GifterUserId = player.UserId,
		})
	elseif info.kind == "VoucherPurchase" then
		-- The receipt's entire reward is one fungible voucher. No theme or
		-- recipient intent is consulted, so receipt ordering is irrelevant.
		granted = true
	else
		granted = if info.kind == "ProductPurchase"
			then giveProduct(player, info.name, false, nil, true)
			else givePack(player, info.name, false, nil)
	end

	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local uiUpdates: { [string]: any } = {
		ProcessedPurchaseIds = appendProcessedPurchase(data, receiptInfo.PurchaseId),
		PendingGifts = if matchedGiftEntry ~= nil
			then removeMatchingPendingGift(data.UISystem.PendingGifts, matchedGiftEntry)
			else data.UISystem.PendingGifts,
	}
	-- Never include Vouchers in an unrelated receipt batch. Legacy gift
	-- delivery yields above; writing its pre-yield balance here could erase a
	-- redemption, transfer, or newly received voucher that happened meanwhile.
	if info.kind == "VoucherPurchase" then
		uiUpdates.Vouchers = data.UISystem.Vouchers + 1
	end
	DataService.setValues(player, { "UISystem" }, uiUpdates)
	if info.kind == "VoucherPurchase" then
		UINotificationService.SendNotification(player, "Success", "Purchased 1 Theme Ticket")
		UINotificationService.EmitConfetti(player)
	end

	local saved = DataService.saveAndAwait(player, function(savedData: any)
		return savedPurchaseExists(savedData, receiptInfo.PurchaseId)
	end, 30)
	return if saved then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
end

local function onProcessReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if processingReceipts[player] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	processingReceipts[player] = true
	local ok, decision = xpcall(function()
		return processReceiptForPlayer(receiptInfo, player)
	end, debug.traceback)
	processingReceipts[player] = nil

	if not ok then
		log.error(`receipt processing failed for {player.Name}: {tostring(decision)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

local function onGiftMessage(player: Player, message: { [string]: any }): boolean
	local purchaseId = message.PurchaseId
	local rewardKind = message.RewardKind
	local gifterUserId = message.GifterUserId
	if
		type(purchaseId) ~= "string"
		or #purchaseId == 0
		or #purchaseId > 128
		or (rewardKind ~= "Pass" and rewardKind ~= "Product" and rewardKind ~= "Pack" and rewardKind ~= "Cosmetic")
		or not isValidUserId(gifterUserId)
	then
		log.warn(`discarding malformed paid-gift message for {player.Name}`)
		return true
	end

	-- Cosmetic gifts carry Slot/ItemId instead of ItemName -- extended
	-- validation here rather than a second registerMessageHandler kind,
	-- since it's the same durable-message contract (PurchaseId + gifter)
	-- with a different payload shape (COSMETICS_PLAN.md).
	if rewardKind == "Cosmetic" then
		local slotValue = message.Slot
		local itemId = message.ItemId
		if
			not isValidSlotValue(slotValue)
			or typeof(itemId) ~= "string"
			or #itemId == 0
			or #itemId > MAX_ITEM_NAME_LENGTH
			or not CosmeticsCatalog.isValidId(slotValue :: CosmeticsCatalog.Slot, itemId)
		then
			log.warn(`discarding malformed paid-cosmetic-gift message for {player.Name}`)
			return true
		end

		local data = DataService.getData(player)
		if data == nil then
			return false
		end
		if hasProcessedPurchase(data, purchaseId) then
			return true
		end
		local granted, duplicateVoucher = giveCosmeticGift(player, slotValue :: CosmeticsCatalog.Slot, itemId)
		if not granted then
			return false
		end
		-- Record idempotency before any best-effort UI. If a notification ever
		-- fails, replay sees this marker and cannot grant the cosmetic/voucher
		-- a second time.
		if duplicateVoucher then
			DataService.setValues(player, { "UISystem" }, {
				Vouchers = data.UISystem.Vouchers + 1,
				ProcessedPurchaseIds = appendProcessedPurchase(data, purchaseId),
			})
			notifyGiftSent(player, gifterUserId, "a Theme Ticket because you already owned that cosmetic")
			UINotificationService.EmitConfetti(player)
		else
			DataService.set(player, { "UISystem", "ProcessedPurchaseIds" }, appendProcessedPurchase(data, purchaseId))
			notifyGiftSent(player, gifterUserId, cosmeticLabel(slotValue :: CosmeticsCatalog.Slot, itemId))
		end
		return true
	end

	local itemName = message.ItemName
	if type(itemName) ~= "string" or #itemName == 0 or #itemName > MAX_ITEM_NAME_LENGTH then
		log.warn(`discarding malformed paid-gift message for {player.Name}`)
		return true
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end
	if hasProcessedPurchase(data, purchaseId) then
		return true
	end

	local granted = if rewardKind == "Pass"
		then PassesByName[itemName] ~= nil and givePass(player, itemName, true, gifterUserId, true)
		elseif rewardKind == "Pack" then PacksByName[itemName] ~= nil and givePack(
			player,
			itemName,
			true,
			gifterUserId
		)
		else ProductsByName[itemName] ~= nil and giveProduct(player, itemName, true, gifterUserId, true)
	if not granted then
		return false
	end

	DataService.set(player, { "UISystem", "ProcessedPurchaseIds" }, appendProcessedPurchase(data, purchaseId))
	return true
end

local function onVoucherTransferMessage(player: Player, message: { [string]: any }): boolean
	local transferId = message.TransferId
	local gifterUserId = message.GifterUserId
	if type(transferId) ~= "string" or #transferId == 0 or #transferId > 128 or not isValidUserId(gifterUserId) then
		log.warn(`discarding malformed voucher-transfer message for {player.Name}`)
		return true
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end
	if hasProcessedVoucherTransfer(data, transferId) then
		return true
	end

	DataService.setValues(player, { "UISystem" }, {
		Vouchers = data.UISystem.Vouchers + 1,
		ProcessedVoucherTransferIds = appendProcessedVoucherTransfer(data, transferId),
	})
	UINotificationService.SendNotification(player, "Success", "Someone sent you a Theme Ticket")
	UINotificationService.EmitConfetti(player)
	return true
end

-- The player just declined the prompt for `productId`. Multiple entries for
-- the same gift product id can coexist in the ring, so remove only the
-- most-recently-started matching entry -- never every matching entry.
local function removeMostRecentGiftByProductId(
	list: { DataService.PendingGiftEntry },
	productId: number
): ({ DataService.PendingGiftEntry }, boolean)
	local bestIndex: number? = nil
	local bestStartedAt = -1
	for index, entry in list do
		if entry.ProductId == productId and entry.StartedAt >= bestStartedAt then
			bestIndex = index
			bestStartedAt = entry.StartedAt
		end
	end
	if bestIndex == nil then
		return list, false
	end
	return removePendingGiftAt(list, bestIndex), true
end

local MonetizationService = {}

function MonetizationService.Init()
	--[[
		The bundled Roblox type defs' exact ReceiptInfo shape is not
		verified here (no luau-lsp on PATH for this pass). onProcessReceipt
		only reads PlayerId, ProductId, and PurchaseId, real fields on every receipt
		Roblox has ever sent, so the narrow local param type above is
		safe; the cast below is only needed because the property's
		declared parameter type may be wider than what's deliberately
		typed here (ARCHITECTURE.md: narrow, documented compatibility
		cast at the boundary, same pattern as DataService's Token cast).
	]]
	MarketplaceService.ProcessReceipt = onProcessReceipt :: any
	DataService.registerMessageHandler(GIFT_MESSAGE_KIND, onGiftMessage)
	DataService.registerMessageHandler(VOUCHER_TRANSFER_MESSAGE_KIND, onVoucherTransferMessage)

	Net.giftStart.listen(function(data, player)
		if player == nil or not giftStartLimiter:allow(player) then
			return
		end
		onGiftStart(data, player)
	end)

	Net.voucherPurchase.listen(function(data, player)
		if player == nil or not voucherPurchaseLimiter:allow(player) then
			return
		end
		onVoucherPurchase(data, player)
	end)

	Net.voucherGift.listen(function(data, player)
		if player == nil then
			return
		end
		if not voucherGiftLimiter:allow(player) then
			if #data.requestId > 0 and #data.requestId <= 128 then
				Net.voucherGiftResult.sendTo({ ok = false, requestId = data.requestId }, player)
			end
			return
		end
		onVoucherGift(data, player)
	end)

	Net.cosmeticCashBuy.listen(function(data, player)
		if player == nil or not cosmeticCashBuyLimiter:allow(player) then
			return
		end
		onCosmeticCashBuy(data, player)
	end)
end

function MonetizationService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		processingReceipts[player] = nil
		voucherActionBusy[player] = nil
		voucherTransferFlushBusy[player] = nil
		voucherTransferRetryScheduled[player] = nil
		ownedVoucherPurchaseConfirmations[player] = nil
		ownedCashPurchaseConfirmations[player] = nil
	end)

	local function recoverVoucherTransfers(player: Player)
		task.spawn(function()
			if DataService.awaitData(player, 30) then
				flushPendingVoucherTransfers(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		recoverVoucherTransfers(player)
	end
	Players.PlayerAdded:Connect(recoverVoucherTransfers)

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			if purchased then
				return
			end
			local player = Players:GetPlayerByUserId(userId)
			local data = if player ~= nil then DataService.getData(player) else nil
			if player == nil or data == nil then
				return
			end
			local updatedGifts, giftRemoved = removeMostRecentGiftByProductId(data.UISystem.PendingGifts, productId)
			if giftRemoved then
				DataService.set(player, { "UISystem", "PendingGifts" }, updatedGifts)
			end
		end
	)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			if not purchased then
				return
			end

			local passName: string? = nil
			for name, info in PassesByName do
				if info.PassID == passId then
					passName = name
					break
				end
			end
			if passName == nil then
				return
			end

			if not givePass(player, passName, false, nil, true) then
				log.warn(`gamepass {passName} was purchased but its reward is unavailable`)
			end
		end
	)

	log.info("ready")
end

return MonetizationService
