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

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

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
local GIFT_MESSAGE_KIND = "MonetizationGift"

type PassEntry = { Enabled: boolean, PassID: number, GiftID: number? }
type ProductEntry = { ProductID: number, GiftID: number? }
type PackEntry = { Enabled: boolean, ProductID: number }

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
	kind: "PassGift" | "ProductPurchase" | "ProductGift" | "PackPurchase" | "Unknown",
	name: string,
}

local processingReceipts: { [Player]: true } = {}
local giftStartLimiter = RateLimiter.new(0.2, 1)
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

local function emptyPendingGift()
	return { Kind = "", ItemName = "", TargetUserId = 0, ProductId = 0 }
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

local function isValidUserId(value: unknown): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
		and value == math.floor(value)
end

local function getProductInfo(productId: number): ProductInfo
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

local function givePack(player: Player, packName: string): boolean
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

	UINotificationService.SendNotification(player, "Success", `Purchased {packName} successfully`)
	UINotificationService.EmitConfetti(player)
	return true
end

local function persistGiftIntent(
	gifter: Player,
	kind: "Pass" | "Product",
	itemName: string,
	targetUserId: number,
	productId: number
): boolean
	local pending = { Kind = kind, ItemName = itemName, TargetUserId = targetUserId, ProductId = productId }
	DataService.set(gifter, { "UISystem", "PendingGift" }, pending)
	return DataService.saveAndAwait(gifter, function(savedData: any)
		local saved = if type(savedData) == "table" and type(savedData.UISystem) == "table"
			then savedData.UISystem.PendingGift
			else nil
		return type(saved) == "table"
			and saved.Kind == kind
			and saved.ItemName == itemName
			and saved.TargetUserId == targetUserId
			and saved.ProductId == productId
	end, 30)
end

local function hasPendingGift(player: Player): boolean
	local data = DataService.getData(player)
	return data ~= nil and data.UISystem.PendingGift.Kind ~= ""
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
	if itemKind ~= "Pass" and itemKind ~= "Product" then
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
	else
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
	end
end

type ReceiptInfo = { PlayerId: number, ProductId: number, PurchaseId: string }

local function pendingGiftMatches(data: DataService.PlayerData, info: ProductInfo, productId: number): (boolean, number)
	local pending = data.UISystem.PendingGift
	local expectedKind = if info.kind == "PassGift" then "Pass" else "Product"
	local matches = pending.Kind == expectedKind
		and pending.ItemName == info.name
		and pending.ProductId == productId
		and isValidUserId(pending.TargetUserId)
	return matches, pending.TargetUserId
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
	if info.kind == "PassGift" or info.kind == "ProductGift" then
		local matches, targetUserId = pendingGiftMatches(data, info, receiptInfo.ProductId)
		if not matches then
			warnReceiptOnce(
				receiptInfo.PurchaseId,
				`receipt {receiptInfo.PurchaseId} has no matching durable gift intent for {player.Name}`
			)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		granted = DataService.messagePlayer(targetUserId, {
			Kind = GIFT_MESSAGE_KIND,
			PurchaseId = receiptInfo.PurchaseId,
			RewardKind = if info.kind == "PassGift" then "Pass" else "Product",
			ItemName = info.name,
			GifterUserId = player.UserId,
		})
	else
		granted = if info.kind == "ProductPurchase"
			then giveProduct(player, info.name, false, nil, true)
			else givePack(player, info.name)
	end

	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	DataService.setValues(player, { "UISystem" }, {
		ProcessedPurchaseIds = appendProcessedPurchase(data, receiptInfo.PurchaseId),
		PendingGift = if info.kind == "PassGift" or info.kind == "ProductGift"
			then emptyPendingGift()
			else data.UISystem.PendingGift,
	})

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
	local itemName = message.ItemName
	local gifterUserId = message.GifterUserId
	if
		type(purchaseId) ~= "string"
		or #purchaseId == 0
		or #purchaseId > 128
		or (rewardKind ~= "Pass" and rewardKind ~= "Product")
		or type(itemName) ~= "string"
		or #itemName == 0
		or #itemName > MAX_ITEM_NAME_LENGTH
		or not isValidUserId(gifterUserId)
	then
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
		else ProductsByName[itemName] ~= nil and giveProduct(player, itemName, true, gifterUserId, true)
	if not granted then
		return false
	end

	DataService.set(player, { "UISystem", "ProcessedPurchaseIds" }, appendProcessedPurchase(data, purchaseId))
	return true
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

	Net.giftStart.listen(function(data, player)
		if player == nil or not giftStartLimiter:allow(player) then
			return
		end
		onGiftStart(data, player)
	end)
end

function MonetizationService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		processingReceipts[player] = nil
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			if purchased then
				return
			end
			local player = Players:GetPlayerByUserId(userId)
			local data = if player ~= nil then DataService.getData(player) else nil
			if player ~= nil and data ~= nil and data.UISystem.PendingGift.ProductId == productId then
				DataService.set(player, { "UISystem", "PendingGift" }, emptyPendingGift())
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
