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

	KNOWN GAP (flagged, not silently dropped -- see the implementer's
	report): the source supported gifting an OFFLINE player via
	DataService:MessagePlayer, a cross-server ProfileStore messaging feature
	the target DataService does not expose (it was not part of
	PORT-SPEC.md's DataService merge). Gifting here requires the target to be
	in THIS server at both gift-start and purchase-completion time; if they
	leave in between, the purchase still completes (the buyer already paid --
	ProcessReceipt cannot un-charge Robux) but the gift is lost and logged as
	an error rather than silently eaten.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local General = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PackRewards = require(ServerStorage.Modules.UISystem.PackRewards)
local Packs = require(ReplicatedStorage.Shared.UISystem.Config.Packs)
local PassRewards = require(ServerStorage.Modules.UISystem.PassRewards)
local Passes = require(ReplicatedStorage.Shared.UISystem.Config.Passes)
local ProductRewards = require(ServerStorage.Modules.UISystem.ProductRewards)
local Products = require(ReplicatedStorage.Shared.UISystem.Config.Products)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("MonetizationService")

local MAX_ITEM_NAME_LENGTH = 64
local REWARD_RETRIES = 5

type PassEntry = { PassID: number, GiftID: number? }
type ProductEntry = { ProductID: number, GiftID: number? }
type PackEntry = { ProductID: number }

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

type GiftCacheEntry = {
	kind: "Pass" | "Product",
	itemName: string,
	targetUserId: number,
}

type ProductInfo = {
	kind: "PassGift" | "ProductPurchase" | "ProductGift" | "PackPurchase" | "Unknown",
	name: string,
}

-- Which product/gift the gifter is mid-purchase of, keyed by the GIFTER.
-- Cleared on PlayerRemoving -- an abandoned gift attempt has nothing left to
-- resolve once the gifter is gone.
local giftCache: { [Player]: GiftCacheEntry } = {}

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

local function passOwned(target: Player, passName: string): boolean
	local data = DataService.getData(target)
	if data ~= nil then
		local giftedPasses = (data.UISystem.GiftedPasses :: any) :: { [string]: boolean }
		if giftedPasses[passName] then
			return true
		end
	end

	local passInfo = PassesByName[passName]
	if passInfo == nil then
		return false
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(target.UserId, passInfo.PassID)
	end)
	return ok and owned == true
end

local function notifyGiftSent(target: Player, gifterUserId: number?, itemLabel: string)
	local gifter = if gifterUserId ~= nil then Players:GetPlayerByUserId(gifterUserId) else nil
	if gifter ~= nil then
		UINotificationService.SendNotification(gifter, "Success", "Sent gift successfully")
		UINotificationService.EmitConfetti(gifter)
	end
	UINotificationService.SendNotification(target, "Success", `Someone sent you {itemLabel}`)
end

local function givePass(target: Player, passName: string, isGift: boolean, gifterUserId: number?, isNew: boolean)
	if isGift then
		DataService.set(target, { "UISystem", "GiftedPasses", passName }, true)
	end

	local rewardFunction = PassRewards[passName]
	if rewardFunction ~= nil then
		task.spawn(function()
			Format.Retry(function()
				rewardFunction(target)
			end, REWARD_RETRIES)
		end)
	end

	if not isNew then
		return
	end

	if isGift then
		notifyGiftSent(target, gifterUserId, `the {passName} gamepass`)
	else
		UINotificationService.SendNotification(target, "Success", `Purchased {passName} gamepass successfully`)
		UINotificationService.EmitConfetti(target)
	end
end

local function giveProduct(target: Player, productName: string, isGift: boolean, gifterUserId: number?, isNew: boolean)
	local rewardFunction = ProductRewards[productName]
	if rewardFunction ~= nil then
		task.spawn(function()
			Format.Retry(function()
				rewardFunction(target)
			end, REWARD_RETRIES)
		end)
	end

	if not isNew then
		return
	end

	if isGift then
		notifyGiftSent(target, gifterUserId, productName)
	else
		UINotificationService.SendNotification(target, "Success", `Purchased {productName} successfully`)
		UINotificationService.EmitConfetti(target)
	end
end

local function givePack(player: Player, packName: string)
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	local packs = (data.UISystem.Packs :: any) :: { string }
	if table.find(packs, packName) ~= nil then
		return
	end

	local updated = table.clone(packs)
	table.insert(updated, packName)
	DataService.set(player, { "UISystem", "Packs" }, updated)

	local rewardFunction = PackRewards[packName]
	if rewardFunction ~= nil then
		task.spawn(function()
			Format.Retry(function()
				rewardFunction(player)
			end, REWARD_RETRIES)
		end)
	end

	UINotificationService.SendNotification(player, "Success", `Purchased {packName} successfully`)
	UINotificationService.EmitConfetti(player)
end

local function startPassGift(gifter: Player, passName: string, target: Player)
	if passOwned(target, passName) then
		UINotificationService.SendNotification(gifter, "Error", "Player already owns the gamepass")
		return
	end

	local giftProductId = PassesByName[passName].GiftID
	if giftProductId == nil then
		UINotificationService.SendNotification(gifter, "Error", "That gamepass can't be gifted")
		return
	end

	giftCache[gifter] = { kind = "Pass", itemName = passName, targetUserId = target.UserId }
	Net.promptStart.sendTo(nil, gifter)
	MarketplaceService:PromptProductPurchase(gifter, giftProductId)
end

local function startProductGift(gifter: Player, productName: string, target: Player)
	local giftProductId = ProductsByName[productName].GiftID
	if giftProductId == nil then
		UINotificationService.SendNotification(gifter, "Error", "That item can't be gifted")
		return
	end

	giftCache[gifter] = { kind = "Product", itemName = productName, targetUserId = target.UserId }
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
	if itemKind ~= "Pass" and itemKind ~= "Product" then
		return
	end
	if typeof(itemName) ~= "string" or #itemName == 0 or #itemName > MAX_ITEM_NAME_LENGTH then
		return
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil then
		UINotificationService.SendNotification(player, "Error", "That player must be online to receive a gift")
		return
	end

	local fromAdmin = table.find(General.Admins, player.UserId) ~= nil

	if itemKind == "Pass" then
		if PassesByName[itemName] == nil then
			return
		end
		if fromAdmin then
			givePass(target, itemName, true, player.UserId, true)
			return
		end
		startPassGift(player, itemName, target)
	else
		if ProductsByName[itemName] == nil then
			return
		end
		if fromAdmin then
			giveProduct(target, itemName, true, player.UserId, true)
			return
		end
		startProductGift(player, itemName, target)
	end
end

local function onProcessReceipt(receiptInfo: { PlayerId: number, ProductId: number }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		-- The player is not in THIS server (a different server, or they've
		-- already left). Roblox retries ProcessReceipt on future
		-- joins/servers until a non-NotProcessedYet decision is returned, so
		-- this is the correct response, not a dropped purchase.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local info = getProductInfo(receiptInfo.ProductId)

	if info.kind == "PassGift" then
		local cache = giftCache[player]
		if cache ~= nil and cache.kind == "Pass" and cache.itemName == info.name then
			local target = Players:GetPlayerByUserId(cache.targetUserId)
			if target ~= nil then
				givePass(target, info.name, true, player.UserId, true)
			else
				log.error(
					`gift target (userId {cache.targetUserId}) left before "{info.name}" gift resolved -- {player.Name} paid, nothing granted`
				)
			end
		end
	elseif info.kind == "ProductGift" then
		local cache = giftCache[player]
		if cache ~= nil and cache.kind == "Product" and cache.itemName == info.name then
			local target = Players:GetPlayerByUserId(cache.targetUserId)
			if target ~= nil then
				giveProduct(target, info.name, true, player.UserId, true)
			else
				log.error(
					`gift target (userId {cache.targetUserId}) left before "{info.name}" gift resolved -- {player.Name} paid, nothing granted`
				)
			end
		end
	elseif info.kind == "ProductPurchase" then
		giveProduct(player, info.name, false, nil, true)
	elseif info.kind == "PackPurchase" then
		givePack(player, info.name)
	else
		log.warn(`unrecognised product id {receiptInfo.ProductId} purchased by {player.Name}`)
	end

	giftCache[player] = nil

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local MonetizationService = {}

function MonetizationService.Init()
	--[[
		The bundled Roblox type defs' exact ReceiptInfo shape is not
		verified here (no luau-lsp on PATH for this pass). onProcessReceipt
		only reads PlayerId and ProductId, real fields on every receipt
		Roblox has ever sent, so the narrow local param type above is
		safe; the cast below is only needed because the property's
		declared parameter type may be wider than what's deliberately
		typed here (ARCHITECTURE.md: narrow, documented compatibility
		cast at the boundary, same pattern as DataService's Token cast).
	]]
	MarketplaceService.ProcessReceipt = onProcessReceipt :: any

	Net.giftStart.listen(function(data, player)
		if player == nil then
			return
		end
		onGiftStart(data, player)
	end)
end

function MonetizationService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		giftCache[player] = nil
	end)

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

			givePass(player, passName, false, nil, true)
		end
	)

	log.info("ready")
end

return MonetizationService
