--!strict
--[[
	ThemeShop purchase flow (COSMETICS_PLAN.md "shop pass"): Robux purchase,
	Cash purchase, gifting, and client-only preview for keycap Themes,
	squishy launch Beams, and Merge Pops.

	Structurally this is CosmeticsController's menu (same template-clone,
	same tab switching, same DataController.observe wiring) plus a purchase
	layer CosmeticsController never needed, since that menu shows owned
	items only. Unlike Cosmetics, ThemeShop's ThemeTemplate1 lists EVERY
	catalog entry. On an unowned card, Purchase spends one voucher when
	available or prompts the voucher product when empty. On an owned card it
	buys another voucher explicitly. CashPurchase grants the cosmetic when
	unowned and converts the duplicate into a voucher when owned. Gift
	transfers a generic voucher, so all three actions remain available.

	No Init() -- Frames.get yields, and nothing here needs another module's
	Start() to have already run: Frames.get/WaitForChild block until the
	frame exists regardless of load order, and MonetizationController is only
	reached from a user click (StartVoucherGiftPrompt) long after every
	Start() has had a chance to spawn (Loader.luau task.spawns each Start(),
	so they run in parallel, not in sequence -- see its own comment).
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AuthoredVfx = require(ReplicatedStorage.Shared.AuthoredVfx)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local CosmeticsShopConfig = require(ReplicatedStorage.Shared.CosmeticsShopConfig)
local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local KeyCapsController = require(script.Parent.Parent.KeyCapsController)
local LaunchBeamRuntime = require(ReplicatedStorage.Shared.LaunchBeamRuntime)
local Log = require(ReplicatedStorage.Shared.Log)
local MonetizationController = require(script.Parent.MonetizationController)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("ThemeShopController")
local player = Players.LocalPlayer
local launchBeamsFolder = ReplicatedStorage.Assets.VFX.LaunchBeams
local mergeVfxFolder = ReplicatedStorage.Assets.VFX.Merge

-- How long a client-only preview stays applied before auto-reverting.
local PREVIEW_DURATION = 15

local ThemeShopController = {}

local SHOP_DIVIDER_TEXT_BY_SLOT: { [CosmeticsCatalog.Slot]: string } = {
	KeycapThemes = "- Key Theme Shop -",
	SquishyBeams = "- Beam Theme Shop -",
	MergePops = "- Merge Pop Theme Shop -",
}

-- Purchase's ShineContainer descendant carries Ui-Effect = Shine in the
-- template, same as Cosmetics' Purchase button. Only stripped from controls
-- this controller hides; Gift remains visible because vouchers are fungible.
local function clearEffectAttribute(instance: Instance)
	if instance:GetAttribute("Ui-Effect") ~= nil then
		instance:SetAttribute("Ui-Effect", nil)
	end
end

--[[
	Every Ui-* attribute UIKitController.setupItem attaches purchase/gift/
	navigation behavior to (see its MarketplaceAttrs table, plus Ui-Frame and
	Ui-Close). COSMETICS_PLAN.md records that ThemeTemplate1 was found in
	Studio with a stray Ui-Pass/Ui-Pass-Robux on Purchase/Preview/Gift, which
	would silently rewire a cosmetic card's button into a gamepass prompt --
	fixed there, but nothing stops the template from being re-copied with the
	same mistake. UIKitController wires on PlayerGui.DescendantAdded, so this
	MUST run before `card.Parent = holder` below: stripped after parenting is
	stripped too late.
]]
local MONETIZATION_ATTRIBUTES = {
	"Ui-Product",
	"Ui-Product-Robux",
	"Ui-Pass",
	"Ui-Pass-Robux",
	"Ui-Gift-Pass",
	"Ui-Gift-Product",
	"Ui-Pack",
	"Ui-Pack-Robux",
	"Ui-Frame",
	"Ui-Close",
}

local function clearMonetizationAttributes(instance: Instance)
	for _, attribute in MONETIZATION_ATTRIBUTES do
		if instance:GetAttribute(attribute) ~= nil then
			instance:SetAttribute(attribute, nil)
		end
	end
end

local function clearMonetizationAttributesDeep(root: Instance)
	clearMonetizationAttributes(root)
	for _, descendant in root:GetDescendants() do
		clearMonetizationAttributes(descendant)
	end
end

-- Format.FormatNumber's "%.2f%s" always leaves exactly two decimal digits
-- ahead of the suffix letters (if any) -- "10.00M", not "10M". Trim the
-- trailing zero decimals, then a bare trailing dot, without disturbing the
-- suffix: "10.00M" -> "10M", "12.50M" -> "12.5M". Local to this controller
-- rather than added to the shared Format module, since FormatNumber has
-- other callers elsewhere that are not part of this change.
local function trimTrailingZeros(text: string): string
	local trimmed = string.gsub(text, "(%.%d-)0+(%a*)$", "%1%2")
	trimmed = string.gsub(trimmed, "%.(%a*)$", "%1")
	return trimmed
end

local function formatCashPrice(value: number): string
	return trimTrailingZeros(Format.FormatNumber(value))
end

local function toIdSet(ids: { string }): { [string]: true }
	local set: { [string]: true } = {}
	for _, id in ids do
		set[id] = true
	end
	return set
end

-- Same sampling as CosmeticsController.colorSequenceFromTheme -- see its
-- comment for why MAX_GRADIENT_KEYPOINTS exists.
local MAX_GRADIENT_KEYPOINTS = 20

local function colorSequenceFromTheme(colors: { Color3 }): ColorSequence?
	if #colors < 2 then
		return nil
	end

	local sampleCount = math.min(#colors, MAX_GRADIENT_KEYPOINTS)
	local keypoints: { ColorSequenceKeypoint } = {}
	for index = 1, sampleCount do
		local time = (index - 1) / (sampleCount - 1)
		local colorIndex = math.clamp(math.round(1 + time * (#colors - 1)), 1, #colors)
		table.insert(keypoints, ColorSequenceKeypoint.new(time, colors[colorIndex]))
	end
	return ColorSequence.new(keypoints)
end

local function colorSequenceFromBeam(id: string): ColorSequence?
	local template = launchBeamsFolder:FindFirstChild(id)
	local beam = if template ~= nil then template:FindFirstChildWhichIsA("Beam", true) else nil
	return if beam ~= nil and beam:IsA("Beam") then beam.Color else nil
end

local function colorSequenceFromMergePop(id: string): ColorSequence?
	local template = mergeVfxFolder:FindFirstChild(id)
	local emitter = if template ~= nil then template:FindFirstChildWhichIsA("ParticleEmitter", true) else nil
	return if emitter ~= nil and emitter:IsA("ParticleEmitter") then emitter.Color else nil
end

-- pcall-wrapped per quality-gate.md (GetProductInfoAsync can throw). Called
-- once per voucher product, from the end of Start() -- AFTER every
-- frame/button/observer
-- is already wired up, so a throttled Marketplace call never leaves the shop
-- unusable while it's in flight (see Start()'s own comment on the ordering).
-- render() itself must still stay yield-free (it destroys the holder's
-- children before rebuilding, and a yield in that window lets a second
-- render(), e.g. from a tab click racing an owned-items update, observe an
-- empty holder and append a full second catalog on top) -- this function is
-- never called FROM render(), only before/after it, so that holds regardless
-- of where in Start() it's called from. Every cosmetic shares these voucher
-- prices, so a successful fetch never needs refetching; a failed fetch keeps
-- the " ?" placeholder for the session rather than retrying (and therefore
-- yielding) on a later render.
local function robuxPriceText(productId: number): string
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product)
	end)
	if ok and info ~= nil and typeof(info.PriceInRobux) == "number" then
		return ` {info.PriceInRobux}`
	end
	return " ?"
end

-- The local player's own base BasePart, resolved the same way
-- MushController/IncomePopupController already do client-side (BaseService
-- is server-only; AssignedBase is the one attribute it publishes).
local function getOwnBasePart(): BasePart?
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return nil
	end
	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local bases = if mapLayout ~= nil then mapLayout:FindFirstChild("Bases") else nil
	local base = if bases ~= nil then bases:FindFirstChild(baseName) else nil
	return if base ~= nil and base:IsA("BasePart") then base else nil
end

local function isMergePopTemplate(template: Instance): boolean
	if not template:IsA("BasePart") and not template:IsA("Model") then
		return false
	end
	return template:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
end

--[[
	task.cancel errors ("cannot cancel thread") on a thread that is no longer
	suspended -- already dead (its callback already ran and returned), or
	currently running (cancelling yourself from inside your own callback,
	which clearPreview passed as task.delay's callback can do when the
	PREVIEW_DURATION timeout fires on its own). Every preview's cancel()
	calls this instead of task.cancel directly, so an already-resolved timer
	never turns "revert this preview" into an uncaught error.
]]
local function cancelThread(thread: thread)
	if coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end
end

local function preparePreviewPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
end

function ThemeShopController.Start()
	-- Placeholder until the real price lands at the end of Start() (see the
	-- fetch below) -- every card renders with this text until then. Wiring
	-- everything below FIRST, and only fetching afterward, means a throttled
	-- GetProductInfoAsync call no longer leaves the whole shop (tabs,
	-- purchase/gift/preview buttons, the owned-items observer) unwired for
	-- however long that yield takes; the previous ordering fetched before any
	-- of it was wired.
	local voucherRobuxPrice = " ?"
	local giftVoucherRobuxPrice = " ?"

	local frame = Frames.get("ThemeShop")
	local top = frame:WaitForChild("Top")
	local keysButton = top:WaitForChild("Keys") :: GuiButton
	local beamsButton = top:WaitForChild("Beams") :: GuiButton
	local mergePopButton = top:WaitForChild("MergePop") :: GuiButton
	local scrollFrame = frame:WaitForChild("MainScrollingFrame") :: ScrollingFrame
	local holder = scrollFrame:WaitForChild("Holder") :: Frame
	local template = holder:WaitForChild("ThemeTemplate1") :: Frame

	-- Defensive: render()'s destroy loop below already skips OwnedText by
	-- name (never by LayoutOrder), but if this ever drifted to a nonzero
	-- LayoutOrder in the template -- accidentally, in a future edit -- the
	-- unowned-before/owned-after split (unownedOrder < 0 < ownedOrder) would
	-- silently break. Forced once here rather than trusted to stay authored
	-- correctly.
	local ownedText = holder:FindFirstChild("OwnedText")
	if ownedText ~= nil and ownedText:IsA("GuiObject") then
		ownedText.LayoutOrder = 0
	end

	local activeSlot: CosmeticsCatalog.Slot = "KeycapThemes"
	local voucherCount = 0
	local ownedIds: {
		KeycapThemes: { [string]: true },
		SquishyBeams: { [string]: true },
		MergePops: { [string]: true },
	} =
		{
			KeycapThemes = {},
			SquishyBeams = {},
			MergePops = {},
		}

	--[[
		Client-only preview state (zero server calls). Only one preview is ever
		active: starting a new one ends whichever is currently applied, and the
		PREVIEW_DURATION timeout below ends it on its own. Deliberately NOT
		cancelled by switching tabs or closing the ThemeShop -- the whole point
		of a preview is to let the player look at their base unobstructed, so it
		runs its full duration regardless of what the player does with the shop
		UI in the meantime. `cancel` fully owns undoing whatever that preview
		touched (attribute overrides, beam clone, or burst clone) -- see each
		preview*() function.
	]]
	type PreviewHandle = { cancel: () -> () }
	local activePreview: PreviewHandle? = nil

	local function clearPreview()
		local preview = activePreview
		if preview == nil then
			return
		end
		activePreview = nil
		preview.cancel()
	end

	local function previewKeycapTheme(themeId: string)
		clearPreview()
		local basePart = getOwnBasePart()
		if basePart == nil then
			return
		end
		local keyCaps = basePart:FindFirstChild("KeyCaps")
		if keyCaps == nil then
			return
		end

		-- Local attribute override: KeyTracking's own attribute-changed
		-- connection (KeyCapsController) re-renders on this write same as it
		-- would for the server's real equip, so nothing here has to know how
		-- to paint a key -- only how to restore the attribute it overwrote.
		-- Appearance.applyTheme normalizes an id it doesn't recognize (catalog/
		-- THEMES drift) by writing DEFAULT_THEME straight back onto the
		-- attribute. Under the default (Deferred) Workspace.SignalBehavior,
		-- KeyCapsController's attribute-changed handler -- and so this
		-- normalization -- runs at the end of the current resumption cycle,
		-- not synchronously inside this SetAttribute call, so the read-back
		-- immediately below is best-effort for the drift case, not a
		-- guarantee: every previewable id here is already catalog-validated
		-- before previewKeycapTheme is ever called, and drift itself is
		-- caught separately by Appearance.warnCosmeticsCatalogDrift, so this
		-- doesn't need to be airtight. `appliedKeyThemes`/`appliedBaseTheme`
		-- (read back right after the write) are still compared against in
		-- cancel() rather than `themeId` itself, since whatever landed
		-- synchronously is the correct thing to undo either way.
		local originalKeyThemes: { [MeshPart]: any } = {}
		local appliedKeyThemes: { [MeshPart]: any } = {}
		local keys: { MeshPart } = {}
		for _, instance in keyCaps:GetDescendants() do
			if instance:IsA("MeshPart") and CollectionService:HasTag(instance, CosmeticsCatalog.KEY_TAG) then
				originalKeyThemes[instance] = instance:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE)
				instance:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, themeId)
				appliedKeyThemes[instance] = instance:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE)
				table.insert(keys, instance)
			end
		end
		local originalBaseTheme = basePart:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE)
		basePart:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, themeId)
		local appliedBaseTheme = basePart:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE)

		local timeoutThread = task.delay(PREVIEW_DURATION, clearPreview)
		activePreview = {
			cancel = function()
				cancelThread(timeoutThread)
				-- Only restore an attribute that still holds THIS preview's
				-- (possibly normalized) value. If the server re-stamped the
				-- real theme while the preview was active (equip, or a base
				-- reassignment -- CosmeticsService.applyKeycapTheme), that
				-- newer value must win; writing the stale snapshot back would
				-- clobber it.
				for _, key in keys do
					if
						key.Parent ~= nil
						and key:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE) == appliedKeyThemes[key]
					then
						key:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, originalKeyThemes[key])
					end
				end
				if
					basePart.Parent ~= nil
					and basePart:GetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE) == appliedBaseTheme
				then
					basePart:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, originalBaseTheme)
				end
			end,
		}
	end

	local function previewSquishyBeam(beamId: string)
		clearPreview()
		local basePart = getOwnBasePart()
		if basePart == nil then
			return
		end
		local beamTemplate = launchBeamsFolder:FindFirstChild(beamId)
		if beamTemplate == nil then
			return
		end
		if not beamTemplate:IsA("Model") then
			return
		end

		local offset = Vector3.new(0, basePart.Size.Y * 0.5, 0)
		local handle = LaunchBeamRuntime.attach(basePart, beamTemplate, offset)
		if handle == nil then
			return
		end
		task.spawn(LaunchBeamRuntime.fadeIn, handle, 0.4)

		local timeoutThread = task.delay(PREVIEW_DURATION, clearPreview)
		activePreview = {
			cancel = function()
				cancelThread(timeoutThread)
				LaunchBeamRuntime.destroy(handle)
			end,
		}
	end

	local function previewMergePop(popId: string)
		clearPreview()
		local basePart = getOwnBasePart()
		if basePart == nil then
			return
		end
		local popTemplate = mergeVfxFolder:FindFirstChild(popId)
		if popTemplate == nil then
			return
		end
		if not isMergePopTemplate(popTemplate) then
			return
		end

		local position = basePart.Position + Vector3.new(0, basePart.Size.Y * 0.5 + 2, 0)
		local burst = popTemplate:Clone()
		if burst:IsA("BasePart") then
			preparePreviewPart(burst)
			burst.CFrame = CFrame.new(position) * burst.CFrame.Rotation
		elseif burst:IsA("Model") then
			for _, descendant in burst:GetDescendants() do
				if descendant:IsA("BasePart") then
					preparePreviewPart(descendant)
				end
			end
			burst:PivotTo(CFrame.new(position) * burst:GetPivot().Rotation)
		else
			burst:Destroy()
			return
		end
		burst.Parent = Workspace

		local lifetime = AuthoredVfx.emitBurst(burst)
		local cleanupThread = task.delay(lifetime + 0.5, function()
			if burst.Parent ~= nil then
				burst:Destroy()
			end
		end)

		local timeoutThread = task.delay(PREVIEW_DURATION, clearPreview)
		activePreview = {
			cancel = function()
				cancelThread(timeoutThread)
				cancelThread(cleanupThread)
				if burst.Parent ~= nil then
					burst:Destroy()
				end
			end,
		}
	end

	--[[
		Clones `template` once per catalog entry in the active slot -- every
		entry, unlike CosmeticsController's owned-only menu. Never touches the
		template original (Parent stays Holder, Visible stays false in
		Studio) or the Holder's own UIListLayout.

		Unowned cards sort before OwnedText (LayoutOrder < 0, catalog order
		preserved); owned cards sort after it (LayoutOrder > 0, catalog order
		preserved) -- OwnedText itself (LayoutOrder 0) never needs touching.
	]]
	local function render()
		if ownedText ~= nil and ownedText:IsA("TextLabel") then
			ownedText.Text = SHOP_DIVIDER_TEXT_BY_SLOT[activeSlot]
		end

		local savedCanvasPosition = scrollFrame.CanvasPosition

		-- Skipped by name, not just by class: OwnedText is currently a
		-- TextLabel (not a Frame, so child:IsA("Frame") already excludes it),
		-- but the unowned/owned split below depends on this divider surviving
		-- every rebuild regardless of what type it's authored as.
		for _, child in holder:GetChildren() do
			if child ~= template and child.Name ~= "OwnedText" and child:IsA("Frame") then
				child:Destroy()
			end
		end

		local slot: CosmeticsCatalog.Slot = activeSlot
		local owned = ownedIds[slot]
		local unownedOrder = -1000000
		local ownedOrder = 0
		-- Fetched once per voucher product in Start(), not here -- every card
		-- in every slot shares them, and render() must stay yield-free (see
		-- robuxPriceText's comment).
		local unownedPurchaseText = if voucherCount > 0 then "Use Voucher" else voucherRobuxPrice
		local giftText = if voucherCount > 0 then "Gift Voucher" else giftVoucherRobuxPrice

		for _, entry in CosmeticsCatalog.catalogForSlot(slot) do
			local isOwned = owned[entry.Id] == true

			local card = template:Clone() :: Frame
			card.Name = entry.Id
			card.Visible = true
			if isOwned then
				ownedOrder += 1
				card.LayoutOrder = ownedOrder
			else
				unownedOrder += 1
				card.LayoutOrder = unownedOrder
			end

			local title = card:FindFirstChild("Title")
			if title ~= nil and title:IsA("TextLabel") then
				title.Text = entry.DisplayName
			end

			local gradient = card:FindFirstChild("UIGradient")
			if gradient ~= nil and gradient:IsA("UIGradient") then
				local sequence: ColorSequence?
				if slot == "KeycapThemes" then
					local colors = KeyCapsController.getThemeColors(entry.Id)
					sequence = if colors ~= nil then colorSequenceFromTheme(colors) else nil
				elseif slot == "SquishyBeams" then
					sequence = colorSequenceFromBeam(entry.Id)
				else
					sequence = colorSequenceFromMergePop(entry.Id)
				end
				if sequence ~= nil then
					gradient.Color = sequence
				end
			end

			local icon = card:FindFirstChild("Icon")
			if icon ~= nil and icon:IsA("ImageLabel") then
				if slot == "KeycapThemes" then
					local iconId = Images.ThemeIcons[entry.Id]
					if iconId ~= nil then
						icon.Image = `rbxassetid://{iconId}`
					end
				else
					icon.Visible = false
					clearEffectAttribute(icon)
					for _, descendant in icon:GetDescendants() do
						clearEffectAttribute(descendant)
					end
				end
			end

			local purchaseButton = card:FindFirstChild("Purchase")
			local cashButton = card:FindFirstChild("CashPurchase")
			local giftButton = card:FindFirstChild("Gift")
			local previewButton = card:FindFirstChild("Preview")

			-- Purchase remains useful on owned cards: after a confirmation
			-- click, it explicitly buys another generic voucher instead of
			-- trying to redeem one for a cosmetic the player already has.
			if purchaseButton ~= nil and purchaseButton:IsA("GuiButton") then
				purchaseButton.Visible = true
				local priceTag = purchaseButton:FindFirstChild("PriceTag")
				local voucherDisplay = purchaseButton:FindFirstChild("Vouchers")
				local hasVoucherDisplay = voucherDisplay ~= nil and voucherDisplay:IsA("GuiObject")
				if hasVoucherDisplay then
					local display = voucherDisplay :: GuiObject
					display.Visible = true
					local voucherText = Format.FormatNumber(voucherCount)
					local mainLabel = display:FindFirstChild("main")
					local shadowLabel = display:FindFirstChild("shadow")
					if mainLabel ~= nil and mainLabel:IsA("TextLabel") then
						mainLabel.Text = voucherText
					end
					if shadowLabel ~= nil and shadowLabel:IsA("TextLabel") then
						shadowLabel.Text = voucherText
					end
				end
				if priceTag ~= nil and priceTag:IsA("TextLabel") then
					priceTag.Text = if isOwned then voucherRobuxPrice else unownedPurchaseText
					priceTag.Visible = not hasVoucherDisplay
				end
				purchaseButton.MouseButton1Click:Connect(function()
					Net.voucherPurchase.send({
						slot = slot,
						id = entry.Id,
					})
				end)
			end

			-- CashPurchase also remains available. Confirming an already-owned
			-- cosmetic spends the voucher cash price and pays one voucher
			-- instead, so the transaction never becomes a duplicate no-op.
			if cashButton ~= nil and cashButton:IsA("GuiButton") then
				cashButton.Visible = true
				local priceTag = cashButton:FindFirstChild("PriceTag")
				if priceTag ~= nil and priceTag:IsA("TextLabel") then
					local cashPrice = if isOwned
						then CosmeticsShopConfig.VOUCHER_CASH_PRICE
						else CosmeticsShopConfig.CASH_PRICE[slot]
					priceTag.Text = formatCashPrice(cashPrice)
				end
				cashButton.MouseButton1Click:Connect(function()
					Net.cosmeticCashBuy.send({ slot = slot, id = entry.Id })
				end)
			end

			-- A gift is one fungible voucher, not this card's cosmetic, so the
			-- action remains useful even when the local player owns the card.
			if giftButton ~= nil and giftButton:IsA("GuiButton") then
				local priceTag = giftButton:FindFirstChild("PriceTag")
				if priceTag ~= nil and priceTag:IsA("TextLabel") then
					priceTag.Text = giftText
				end
				giftButton.MouseButton1Click:Connect(function()
					MonetizationController.StartVoucherGiftPrompt("ThemeShop")
				end)
			end

			if previewButton ~= nil and previewButton:IsA("GuiButton") then
				previewButton.MouseButton1Click:Connect(function()
					if slot == "KeycapThemes" then
						previewKeycapTheme(entry.Id)
					elseif slot == "SquishyBeams" then
						previewSquishyBeam(entry.Id)
					else
						previewMergePop(entry.Id)
					end
				end)
			end

			clearMonetizationAttributesDeep(card)
			card.Parent = holder
		end

		task.defer(function()
			scrollFrame.CanvasPosition = savedCanvasPosition
		end)
	end

	-- No bare render() here -- ownedIds is empty until the
	-- DataController.observe callback below fires, which it does immediately
	-- with the current value (DataController.observe replays on registration),
	-- same as CosmeticsController's own Start(). A bare render() first would
	-- paint every card, including free defaults, as unowned for one frame.
	-- No clearPreview() here (unlike each preview*() function's own call at
	-- its start, still needed for "a new preview replaces the old one") -- a
	-- running preview is deliberately left alone across a tab switch, same
	-- reasoning as the activePreview comment above: it runs its full
	-- PREVIEW_DURATION so the player can keep looking at their base
	-- regardless of which tab is open.
	keysButton.MouseButton1Click:Connect(function()
		activeSlot = "KeycapThemes"
		render()
	end)
	beamsButton.MouseButton1Click:Connect(function()
		activeSlot = "SquishyBeams"
		render()
	end)
	mergePopButton.MouseButton1Click:Connect(function()
		activeSlot = "MergePops"
		render()
	end)

	-- {"Cosmetics","Owned"} fires once per server tableInsert -- same
	-- burst-coalescing debounce as CosmeticsController.scheduleRender.
	local ownedRenderPending = false
	local function scheduleRender()
		if ownedRenderPending then
			return
		end
		ownedRenderPending = true
		task.defer(function()
			ownedRenderPending = false
			render()
		end)
	end

	DataController.observe({ "Cosmetics", "Owned" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		local keycapThemes = value.KeycapThemes
		local squishyBeams = value.SquishyBeams
		local mergePops = value.MergePops
		ownedIds.KeycapThemes = toIdSet(if type(keycapThemes) == "table" then keycapThemes else {})
		ownedIds.SquishyBeams = toIdSet(if type(squishyBeams) == "table" then squishyBeams else {})
		ownedIds.MergePops = toIdSet(if type(mergePops) == "table" then mergePops else {})
		scheduleRender()
	end)

	DataController.observe({ "UISystem", "Vouchers" }, function(value: any)
		if type(value) ~= "number" then
			return
		end
		voucherCount = math.max(0, math.floor(value))
		scheduleRender()
	end)

	-- No frame Visible-changed cancellation here (deliberately -- Frame close,
	-- Ui-Close, or UIKitController.OpenFrame switching to a different frame
	-- all set Visible = false): a running preview outlives the ThemeShop
	-- being closed, same as it now outlives a tab switch (see the
	-- activePreview comment above) -- ends only via PREVIEW_DURATION or a new
	-- preview replacing it. This already covers MonetizationController's
	-- Robux-prompt overlay too, which hides the whole PlayerGui
	-- (mainGui.Enabled = false) rather than this frame's Visible.
	--
	-- Fetched last, after every frame/button/observer above is already wired
	-- (see robuxPriceText's own comment) -- patches the placeholder into
	-- every already-rendered PriceTag with one re-render if it lands.
	local fetchedVoucherPrice = robuxPriceText(CosmeticsShopConfig.VOUCHER_PRODUCT_ID)
	local fetchedGiftVoucherPrice = robuxPriceText(CosmeticsShopConfig.GIFT_VOUCHER_PRODUCT_ID)
	if fetchedVoucherPrice ~= voucherRobuxPrice or fetchedGiftVoucherPrice ~= giftVoucherRobuxPrice then
		voucherRobuxPrice = fetchedVoucherPrice
		giftVoucherRobuxPrice = fetchedGiftVoucherPrice
		render()
	end

	log.info("ready")
end

return ThemeShopController
