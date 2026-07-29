--!strict
--[[
	Marketplace prompts (Passes/Products/Packs), price caching, ownership
	checks, and the gift-to-player flow. Ported from the source's
	Controllers/MarketplaceController.luau.

	Deviations from the source (PORT-SPEC.md §3-§4):
	  - ReplicationController.Subscribe/GetSignal -> DataController.observe
	    on {"UISystem","GiftedPasses"} / {"UISystem","Packs"}.
	  - Packets.Marketplace.StartGifting -> Net.giftStart. Packets.Marketplace
	    .PromptStart -> Net.promptStart.
	  - Packets.Marketplace.CheckPassOwned (an invoke asking the server
	    "does THIS OTHER PLAYER already own this pass") is DROPPED -- the
	    port has no request/response channel for another player's ownership,
	    only a replicated view of the LOCAL player's own. onPlayerSelected
	    below skips that pre-check and opens the confirm dialog directly;
	    the server (GiftService) is the sole authority on whether a gift is
	    valid and rejects/refunds an already-owned gift there, same as it
	    already has to for every other case (griefing, stale client state).
	  - GetProductInfoAsync-backed price cache is built lazily inside
	    fetchPrice(), called only from Start()-time UI wiring (Ui-*-Robux
	    attributes, PromotionController) -- never from Init().
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserService = game:GetService("UserService")

local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PacksConfig = require(ReplicatedStorage.Shared.UISystem.Config.Packs)
local PassesConfig = require(ReplicatedStorage.Shared.UISystem.Config.Passes)
local ProductsConfig = require(ReplicatedStorage.Shared.UISystem.Config.Products)
local UISignals = require(script.Parent.Parent.Parent.UI.UISystem.UISignals)

local log = Log.new("MonetizationController")

local player = Players.LocalPlayer

type ItemType = "Pass" | "Product" | "Pack"

local INFO_TYPE: { [ItemType]: Enum.InfoType } = {
	Pass = Enum.InfoType.GamePass,
	Product = Enum.InfoType.Product,
	Pack = Enum.InfoType.Product,
}

type GiftData = {
	GiftType: "Pass" | "Product" | "Pack" | "Voucher",
	GiftName: string,
	GiftTarget: number,
	-- Which frame opened the picker, so its Close button returns there
	-- instead of always going to "Shop" -- ThemeShopController reuses this
	-- same picker (StartVoucherGiftPrompt below), and closing it should not
	-- strand the player on an unrelated frame.
	OriginFrame: Frames.FrameName,
}

local giftData: GiftData = {
	GiftType = "Pass",
	GiftName = "",
	GiftTarget = 0,
	OriginFrame = "Shop",
}

local priceCache: { [ItemType]: { [number]: number } } = {
	Pass = {},
	Product = {},
	Pack = {},
}

type PackConfigEntry = {
	Enabled: boolean,
	ProductID: number,
	GiftID: number?,
	ExpectedPrice: number?,
	ExpectedGiftPrice: number?,
}

local PacksByName = (PacksConfig :: any) :: { [string]: PackConfigEntry }
local warnedPackPrices: { [string]: true } = {}

-- Local mirror of the two replicated ownership tables, refreshed by
-- DataController.observe in Start(). GiftedPasses is a map (passName ->
-- true), Packs is an array of pack names -- matching the shapes the
-- source's own ReplicationController.Subscribe calls assumed.
local giftedPasses: { [string]: boolean } = {}
local ownedPacks: { string } = {}
local passButtons: { { button: GuiButton, name: string } } = {}
local packButtons: { { button: GuiButton, name: string } } = {}
local voucherCount = 0
local voucherTransferPending = false
local voucherActiveRequestId: string? = nil
local voucherConfirmLabel: TextLabel? = nil

local MonetizationController = {}

local function updateVoucherConfirmLabel()
	local label = voucherConfirmLabel
	if label == nil or giftData.GiftType ~= "Voucher" then
		return
	end
	if voucherTransferPending then
		label.Text = "SENDING..."
	elseif voucherCount > 0 then
		label.Text = "SEND"
	else
		label.Text = "BUY"
	end
end

local function fetchPrice(id: number, itemType: ItemType): number?
	local cache = priceCache[itemType]
	local cached = cache[id]
	if cached ~= nil then
		return cached
	end

	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(id, INFO_TYPE[itemType])
	end)
	if ok and info ~= nil then
		cache[id] = info.PriceInRobux
		return info.PriceInRobux
	end
	return nil
end

local function isPackPriceLive(packName: string, packConfig: PackConfigEntry): boolean
	local expectedPrice = packConfig.ExpectedPrice
	if expectedPrice == nil then
		return true
	end

	local actualPrice = fetchPrice(packConfig.ProductID, "Pack")
	if actualPrice == expectedPrice then
		return true
	end

	if not warnedPackPrices[packName] then
		warnedPackPrices[packName] = true
		log.warn(
			`pack "{packName}" expects {expectedPrice} Robux, but Roblox returned {actualPrice or "no price"}; purchase disabled`
		)
	end
	return false
end

local function isPackGiftPriceLive(packName: string, packConfig: PackConfigEntry): boolean
	local giftId = packConfig.GiftID
	local expectedPrice = packConfig.ExpectedGiftPrice
	if giftId == nil or giftId <= 0 then
		return false
	end
	if expectedPrice == nil then
		return true
	end

	local actualPrice = fetchPrice(giftId, "Pack")
	if actualPrice == expectedPrice then
		return true
	end

	local warningKey = packName .. ":gift"
	if not warnedPackPrices[warningKey] then
		warnedPackPrices[warningKey] = true
		log.warn(
			`pack gift "{packName}" expects {expectedPrice} Robux, but Roblox returned {actualPrice or "no price"}; gift disabled`
		)
	end
	return false
end

function MonetizationController.GetPrice(itemType: ItemType, itemName: string): number?
	local id: number?
	local expectedPrice: number?
	if itemType == "Pass" then
		local passConfig = PassesConfig[itemName]
		id = if passConfig ~= nil then passConfig.PassID else nil
	elseif itemType == "Product" then
		local productConfig = ProductsConfig[itemName]
		id = if productConfig ~= nil then productConfig.ProductID else nil
	else
		local packConfig = PacksByName[itemName]
		id = if packConfig ~= nil then packConfig.ProductID else nil
		expectedPrice = if packConfig ~= nil then packConfig.ExpectedPrice else nil
	end

	if id == nil then
		log.warn(`GetPrice: unknown {itemType} "{itemName}"`)
		return nil
	end

	local marketplacePrice = fetchPrice(id, itemType)
	if itemType == "Pack" and expectedPrice ~= nil then
		return expectedPrice
	end
	return marketplacePrice
end

function MonetizationController.IsPassOwned(passName: string): boolean
	if giftedPasses[passName] then
		return true
	end

	local passConfig = PassesConfig[passName]
	if passConfig == nil then
		return false
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passConfig.PassID)
	end)
	return ok and owns == true
end

function MonetizationController.IsPackOwned(packName: string): boolean
	return table.find(ownedPacks, packName) ~= nil
end

local function openPromptAnimation()
	local playerGui = player:WaitForChild("PlayerGui")
	local fullGui = playerGui:WaitForChild("Full")
	local mainGui = playerGui:WaitForChild("Main") :: ScreenGui
	local promptUi = fullGui:WaitForChild("PromptUi") :: Frame
	promptUi.Visible = true
	mainGui.Enabled = false
	UISignals.PromptVisibilityChanged.Fire(true)
end

local function closePromptAnimation()
	local playerGui = player:WaitForChild("PlayerGui")
	local fullGui = playerGui:WaitForChild("Full")
	local mainGui = playerGui:WaitForChild("Main") :: ScreenGui
	local promptUi = fullGui:WaitForChild("PromptUi") :: Frame
	promptUi.Visible = false
	mainGui.Enabled = true
	UISignals.PromptVisibilityChanged.Fire(false)
end

function MonetizationController.StartPassPrompt(passName: string)
	local passConfig = PassesConfig[passName]
	if passConfig == nil or not passConfig.Enabled then
		log.warn(`StartPassPrompt: unknown pass "{passName}"`)
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, passConfig.PassID)
	openPromptAnimation()
end

function MonetizationController.StartProductPrompt(productName: string)
	local productConfig = ProductsConfig[productName]
	if productConfig == nil or productConfig.ProductID <= 0 then
		log.warn(`StartProductPrompt: unknown product "{productName}"`)
		return
	end
	MarketplaceService:PromptProductPurchase(player, productConfig.ProductID)
	openPromptAnimation()
end

function MonetizationController.StartPackPrompt(packName: string)
	local packConfig = PacksByName[packName]
	if packConfig == nil or not packConfig.Enabled then
		log.warn(`StartPackPrompt: unknown pack "{packName}"`)
		return
	end
	if not isPackPriceLive(packName, packConfig) then
		return
	end
	MarketplaceService:PromptProductPurchase(player, packConfig.ProductID)
	openPromptAnimation()
end

local function applyOwnedState(button: GuiButton)
	button.Visible = false
	local parent = button.Parent
	if parent == nil then
		return
	end
	local owned = parent:FindFirstChild("Owned")
	if owned ~= nil and owned:IsA("GuiObject") then
		owned.Visible = true
	end
end

local function updateOwnedButtons(buttons: { { button: GuiButton, name: string } }, owns: (string) -> boolean)
	for index = #buttons, 1, -1 do
		local entry = buttons[index]
		if entry.button.Parent == nil then
			table.remove(buttons, index)
		elseif owns(entry.name) then
			applyOwnedState(entry.button)
		end
	end
end

function MonetizationController.SetPassButton(button: GuiButton, passName: string)
	local passConfig = PassesConfig[passName]
	if passConfig == nil or not passConfig.Enabled then
		button.Visible = false
		return
	end
	table.insert(passButtons, { button = button, name = passName })
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartPassPrompt(passName)
	end)

	if MonetizationController.IsPassOwned(passName) then
		applyOwnedState(button)
	end
end

function MonetizationController.SetProductButton(button: GuiButton, productName: string)
	local productConfig = ProductsConfig[productName]
	if productConfig == nil or productConfig.ProductID <= 0 then
		button.Visible = false
		return
	end
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartProductPrompt(productName)
	end)
end

function MonetizationController.SetPackButton(button: GuiButton, packName: string)
	local packConfig = PacksByName[packName]
	if packConfig == nil or not packConfig.Enabled then
		button.Visible = false
		return
	end
	table.insert(packButtons, { button = button, name = packName })
	if MonetizationController.IsPackOwned(packName) then
		applyOwnedState(button)
		return
	end
	if not isPackPriceLive(packName, packConfig) then
		button.Active = false
		button.Selectable = false
		return
	end
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartPackPrompt(packName)
	end)
end

function MonetizationController.SetPassGiftButton(button: GuiButton, passName: string)
	local passConfig = PassesConfig[passName]
	if passConfig == nil or not passConfig.Enabled or passConfig.GiftID == nil then
		button.Visible = false
		return
	end
	button.MouseButton1Click:Connect(function()
		giftData.GiftType = "Pass"
		giftData.GiftName = passName
		giftData.OriginFrame = "Shop"
		local frame = Frames.get("GiftPlayerChoose")
		local main = frame:WaitForChild("Main")
		local holder = main:WaitForChild("Holder")
		local heading = holder:WaitForChild("HeadngText") :: TextLabel
		heading.Text = `- Gift "{passName}" To -`
		UISignals.OpenFrame.Fire("GiftPlayerChoose")
	end)
end

function MonetizationController.SetProductGiftButton(button: GuiButton, productName: string)
	local productConfig = ProductsConfig[productName]
	if productConfig == nil or productConfig.GiftID == nil then
		button.Visible = false
		return
	end
	button.MouseButton1Click:Connect(function()
		giftData.GiftType = "Product"
		giftData.GiftName = productName
		giftData.OriginFrame = "Shop"
		local frame = Frames.get("GiftPlayerChoose")
		local main = frame:WaitForChild("Main")
		local holder = main:WaitForChild("Holder")
		local heading = holder:WaitForChild("HeadngText") :: TextLabel
		heading.Text = `- Gift "{productName}" To -`
		UISignals.OpenFrame.Fire("GiftPlayerChoose")
	end)
end

function MonetizationController.SetPackGiftButton(button: GuiButton, packName: string)
	local packConfig = PacksByName[packName]
	if packConfig == nil or not packConfig.Enabled or packConfig.GiftID == nil then
		button.Visible = false
		return
	end
	if not isPackGiftPriceLive(packName, packConfig) then
		button.Active = false
		button.Selectable = false
		return
	end
	button.MouseButton1Click:Connect(function()
		giftData.GiftType = "Pack"
		giftData.GiftName = packName
		giftData.OriginFrame = "Shop"
		local frame = Frames.get("GiftPlayerChoose")
		local main = frame:WaitForChild("Main")
		local holder = main:WaitForChild("Holder")
		local heading = holder:WaitForChild("HeadngText") :: TextLabel
		heading.Text = `- Gift "{packName}" To -`
		UISignals.OpenFrame.Fire("GiftPlayerChoose")
	end)
end

-- Opens the existing target picker for a fungible Theme Ticket. Selecting a
-- player before the product prompt is UI state only: the Yes button prompts
-- when the balance is zero, then requires a second post-receipt SEND click.
function MonetizationController.StartVoucherGiftPrompt(originFrame: Frames.FrameName)
	giftData.GiftType = "Voucher"
	giftData.GiftName = "Theme Ticket"
	giftData.OriginFrame = originFrame
	voucherTransferPending = false
	voucherActiveRequestId = nil
	updateVoucherConfirmLabel()
	local frame = Frames.get("GiftPlayerChoose")
	local main = frame:WaitForChild("Main")
	local holder = main:WaitForChild("Holder")
	local heading = holder:WaitForChild("HeadngText") :: TextLabel
	heading.Text = '- Gift "Theme Ticket" To -'
	UISignals.OpenFrame.Fire("GiftPlayerChoose")
end

local function sanitizeUsername(text: string): string
	local parts: { string } = {}
	local underscoreUsed = false

	for i = 1, #text do
		local char = string.sub(text, i, i)
		if string.match(char, "[%a%d]") then
			table.insert(parts, char)
		elseif char == "_" and not underscoreUsed then
			table.insert(parts, char)
			underscoreUsed = true
		end
	end

	return table.concat(parts)
end

local function resolvePlayerByName(rawUsername: string): { userId: number, username: string, displayName: string }?
	local username = sanitizeUsername(rawUsername)
	if username == "" then
		return nil
	end

	local idOk, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(username)
	end)
	if not idOk or userId == nil then
		return nil
	end

	local infoOk, infoList = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync({ userId })
	end)
	if infoOk and infoList ~= nil and infoList[1] ~= nil then
		return { userId = userId, username = username, displayName = infoList[1].DisplayName }
	end
	return nil
end

local function onPlayerSelected(userId: number, username: string, _displayName: string)
	giftData.GiftTarget = userId

	local confirmFrame = Frames.get("GiftConfirm")
	local areYouSure = confirmFrame:WaitForChild("AreYouSureText") :: TextLabel
	if giftData.GiftType == "Voucher" then
		areYouSure.Text = `Send 1 Theme Ticket to {username}?`
	else
		areYouSure.Text = `Are you sure you want to gift "{giftData.GiftName}" to {username}?`
	end
	voucherTransferPending = false
	voucherActiveRequestId = nil
	updateVoucherConfirmLabel()

	UISignals.OpenFrame.Fire("GiftConfirm", false)
end

type GiftPlayerSection = "Server" | "Friend"

local GIFT_SERVER_ENTRY_ORDER = 20
local GIFT_FRIEND_ENTRY_ORDER = 40

local function updateServerEmptyState(holder: Frame)
	local emptyText = holder:FindFirstChild("ServerEmptyText")
	if emptyText == nil or not emptyText:IsA("GuiObject") then
		return
	end

	local hasServerPlayer = false
	for _, child in holder:GetChildren() do
		if child:IsA("Frame") and child:GetAttribute("GiftSection") == "Server" then
			hasServerPlayer = true
			break
		end
	end
	emptyText.Visible = not hasServerPlayer
end

local function createPlayerFrame(
	holder: Frame,
	template: Frame,
	userId: number,
	username: string,
	displayName: string,
	section: GiftPlayerSection
)
	local entryName = `{section}_{userId}`
	if holder:FindFirstChild(entryName) ~= nil then
		return
	end

	local frame = template:Clone()
	frame.Name = entryName
	frame.LayoutOrder = if section == "Server" then GIFT_SERVER_ENTRY_ORDER else GIFT_FRIEND_ENTRY_ORDER
	frame:SetAttribute("GiftSection", section)
	frame:SetAttribute("GiftUserId", userId)
	local displayLabel = frame:WaitForChild("DisplayUser") :: TextLabel
	local mainLabel = frame:WaitForChild("MainUser") :: TextLabel
	displayLabel.Text = displayName
	mainLabel.Text = username

	local icon = frame:FindFirstChild("Icon")
	if icon ~= nil and icon:IsA("ImageLabel") then
		task.defer(function()
			local ok, image = pcall(function()
				return Players:GetUserThumbnailAsync(
					userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size180x180
				)
			end)
			if ok then
				local imageIcon = icon :: ImageLabel
				imageIcon.Image = image
			end
		end)
	end

	local confirmButton = frame:FindFirstChild("Confirm")
	if confirmButton ~= nil and confirmButton:IsA("GuiButton") then
		confirmButton.MouseButton1Click:Connect(function()
			onPlayerSelected(userId, username, displayName)
		end)
	end

	frame.Parent = holder
	if section == "Server" then
		updateServerEmptyState(holder)
	end
end

function MonetizationController.Init()
	Net.promptStart.listen(function()
		openPromptAnimation()
	end)
	Net.voucherGiftResult.listen(function(result)
		if not voucherTransferPending or result.requestId ~= voucherActiveRequestId then
			return
		end
		voucherTransferPending = false
		voucherActiveRequestId = nil
		updateVoucherConfirmLabel()
		if result.ok and Frames.get("GiftConfirm").Visible then
			UISignals.CloseFrame.Fire(true)
		end
	end)
end

function MonetizationController.Start()
	DataController.observe({ "UISystem", "GiftedPasses" }, function(value: any)
		if type(value) == "table" then
			giftedPasses = value
			updateOwnedButtons(passButtons, function(passName: string)
				return giftedPasses[passName] == true
			end)
		end
	end)

	DataController.observe({ "UISystem", "Packs" }, function(value: any)
		if type(value) == "table" then
			ownedPacks = value
			updateOwnedButtons(packButtons, function(packName: string)
				return table.find(ownedPacks, packName) ~= nil
			end)
		end
	end)

	DataController.observe({ "UISystem", "Vouchers" }, function(value: any)
		if type(value) ~= "number" then
			return
		end
		voucherCount = math.max(0, math.floor(value))
		updateVoucherConfirmLabel()
	end)

	local giftPlayerChooseFrame = Frames.get("GiftPlayerChoose")
	local giftConfirmFrame = Frames.get("GiftConfirm")
	local scrollFrame = giftPlayerChooseFrame:WaitForChild("Main") :: ScrollingFrame
	local holder = scrollFrame:WaitForChild("Holder") :: Frame
	local template = holder:WaitForChild("Template") :: Frame

	-- Studio authored this list around a fixed CanvasSize.Y scale of 6.5,
	-- with both Holder and its rows sized as percentages of that canvas. Turn
	-- those already-resolved row heights into offsets before removing the
	-- fixed canvas; otherwise AutomaticSize would be circular (row height
	-- depends on holder height while holder height depends on its rows).
	local function freezeHeight(gui: GuiObject)
		local height = gui.AbsoluteSize.Y
		if height > 0 then
			gui.Size = UDim2.new(gui.Size.X.Scale, gui.Size.X.Offset, 0, height)
		end
	end
	freezeHeight(template)
	local heading = holder:FindFirstChild("HeadngText")
	if heading ~= nil and heading:IsA("GuiObject") then
		freezeHeight(heading)
	end
	local serverHeading = holder:FindFirstChild("PlayersInServerText")
	if serverHeading ~= nil and serverHeading:IsA("GuiObject") then
		freezeHeight(serverHeading)
		serverHeading.LayoutOrder = 10
	end
	local serverEmptyText = holder:FindFirstChild("ServerEmptyText")
	if serverEmptyText ~= nil and serverEmptyText:IsA("GuiObject") then
		freezeHeight(serverEmptyText)
		serverEmptyText.LayoutOrder = GIFT_SERVER_ENTRY_ORDER
	end
	local friendsHeading = holder:FindFirstChild("FriendsText")
	if friendsHeading ~= nil and friendsHeading:IsA("GuiObject") then
		freezeHeight(friendsHeading)
		friendsHeading.LayoutOrder = 30
	end

	holder.AnchorPoint = Vector2.new(holder.AnchorPoint.X, 0)
	holder.Position = UDim2.new(holder.Position.X.Scale, holder.Position.X.Offset, 0, 0)
	holder.Size = UDim2.new(holder.Size.X.Scale, holder.Size.X.Offset, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	scrollFrame.CanvasSize = UDim2.new()
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y

	template.Parent = nil

	local confirmButton = giftPlayerChooseFrame:WaitForChild("Confirm") :: GuiButton
	confirmButton.MouseButton1Click:Connect(function()
		local userSearch = giftPlayerChooseFrame:WaitForChild("UserSearch") :: TextBox
		local info = resolvePlayerByName(userSearch.Text)
		if info ~= nil then
			onPlayerSelected(info.userId, info.username, info.displayName)
		end
	end)

	local top = giftPlayerChooseFrame:WaitForChild("Top")
	local closeButton = top:WaitForChild("Close") :: GuiButton
	closeButton.MouseButton1Click:Connect(function()
		UISignals.OpenFrame.Fire(giftData.OriginFrame)
	end)

	for _, other in Players:GetPlayers() do
		if other ~= player then
			createPlayerFrame(holder, template, other.UserId, other.Name, other.DisplayName, "Server")
		end
	end
	updateServerEmptyState(holder)

	Players.PlayerAdded:Connect(function(other)
		if other ~= player then
			createPlayerFrame(holder, template, other.UserId, other.Name, other.DisplayName, "Server")
		end
	end)

	Players.PlayerRemoving:Connect(function(other)
		local serverEntry = holder:FindFirstChild(`Server_{other.UserId}`)
		if serverEntry ~= nil then
			serverEntry:Destroy()
		end
		updateServerEmptyState(holder)
	end)

	local friendsOk, friendPages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if friendsOk and friendPages ~= nil then
		local pages = friendPages
		while true do
			local ok, page = pcall(function()
				return pages:GetCurrentPage()
			end)
			if not ok then
				break
			end
			for _, item in page do
				createPlayerFrame(holder, template, item.Id, item.Username, item.DisplayName, "Friend")
			end
			if pages.IsFinished then
				break
			end
			local advanceOk = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
			if not advanceOk then
				break
			end
		end
	end

	local yesButton = giftConfirmFrame:WaitForChild("Yes") :: GuiButton
	local yesText = yesButton:FindFirstChild("TextLabel")
	if yesText ~= nil and yesText:IsA("TextLabel") then
		voucherConfirmLabel = yesText
	end
	yesButton.MouseButton1Click:Connect(function()
		local giftType = giftData.GiftType
		if giftType == "Voucher" then
			if voucherTransferPending then
				return
			end
			-- With no balance this asks the server to open the gift-voucher
			-- product. The selected target remains client-only until the player
			-- clicks SEND after the receipt increments Vouchers.
			local requestId = HttpService:GenerateGUID(false)
			if voucherCount > 0 then
				voucherTransferPending = true
				voucherActiveRequestId = requestId
				updateVoucherConfirmLabel()
			end
			Net.voucherGift.send({
				targetUserId = giftData.GiftTarget,
				requestId = requestId,
			})
			return
		end
		Net.giftStart.send({
			targetUserId = giftData.GiftTarget,
			itemKind = giftType,
			itemName = giftData.GiftName,
		})
		local purchaseConnection: RBXScriptConnection
		purchaseConnection = MarketplaceService.PromptProductPurchaseFinished:Connect(function(_, _, purchased)
			purchaseConnection:Disconnect()
			if purchased then
				UISignals.CloseFrame.Fire(true)
			end
		end)
	end)
	updateVoucherConfirmLabel()

	MarketplaceService.PromptProductPurchaseFinished:Connect(closePromptAnimation)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, passId: number, purchased: boolean)
		closePromptAnimation()
		if not purchased then
			return
		end
		for passName, passConfig in PassesConfig do
			if passConfig.PassID == passId then
				updateOwnedButtons(passButtons, function(name: string)
					return name == passName
				end)
				break
			end
		end
	end)

	local playerGui = player:WaitForChild("PlayerGui")
	local fullGui = playerGui:WaitForChild("Full")
	local promptUi = fullGui:WaitForChild("PromptUi")
	local grad = promptUi:WaitForChild("Grad")
	local gradient = grad:WaitForChild("UIGradient") :: UIGradient
	TweenService:Create(
		gradient,
		TweenInfo.new(10, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut, -1, true, 0),
		{ Rotation = 359 }
	):Play()

	log.info("ready")
end

return MonetizationController
