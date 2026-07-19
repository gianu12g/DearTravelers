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

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

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
local camera = Workspace.CurrentCamera

type ItemType = "Pass" | "Product" | "Pack"

local INFO_TYPE: { [ItemType]: Enum.InfoType } = {
	Pass = Enum.InfoType.GamePass,
	Product = Enum.InfoType.Product,
	Pack = Enum.InfoType.Product,
}

local PROMPT_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FOV_OPEN = 50
local FOV_CLOSE = 70
local BLUR_SIZE = 40

type GiftData = {
	GiftType: "Pass" | "Product",
	GiftName: string,
	GiftTarget: number,
}

local giftData: GiftData = {
	GiftType = "Pass",
	GiftName = "",
	GiftTarget = 0,
}

local priceCache: { [ItemType]: { [number]: number } } = {
	Pass = {},
	Product = {},
	Pack = {},
}

-- Local mirror of the two replicated ownership tables, refreshed by
-- DataController.observe in Start(). GiftedPasses is a map (passName ->
-- true), Packs is an array of pack names -- matching the shapes the
-- source's own ReplicationController.Subscribe calls assumed.
local giftedPasses: { [string]: boolean } = {}
local ownedPacks: { string } = {}

local MonetizationController = {}

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

function MonetizationController.GetPrice(itemType: ItemType, itemName: string): number?
	local id: number?
	if itemType == "Pass" then
		local passConfig = PassesConfig[itemName]
		id = if passConfig ~= nil then passConfig.PassID else nil
	elseif itemType == "Product" then
		local productConfig = ProductsConfig[itemName]
		id = if productConfig ~= nil then productConfig.ProductID else nil
	else
		local packConfig = PacksConfig[itemName]
		id = if packConfig ~= nil then packConfig.ProductID else nil
	end

	if id == nil then
		log.warn(`GetPrice: unknown {itemType} "{itemName}"`)
		return nil
	end

	return fetchPrice(id, itemType)
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

	if camera ~= nil then
		TweenService:Create(camera, PROMPT_TWEEN_INFO, { FieldOfView = FOV_OPEN }):Play()
	end

	local blur = game:GetService("Lighting"):FindFirstChildOfClass("BlurEffect")
	if blur ~= nil then
		blur.Enabled = true
		TweenService:Create(blur, PROMPT_TWEEN_INFO, { Size = BLUR_SIZE }):Play()
	end
end

local function closePromptAnimation()
	local playerGui = player:WaitForChild("PlayerGui")
	local fullGui = playerGui:WaitForChild("Full")
	local mainGui = playerGui:WaitForChild("Main") :: ScreenGui
	local promptUi = fullGui:WaitForChild("PromptUi") :: Frame
	promptUi.Visible = false
	mainGui.Enabled = true

	if camera ~= nil then
		TweenService:Create(camera, PROMPT_TWEEN_INFO, { FieldOfView = FOV_CLOSE }):Play()
	end

	local blur = game:GetService("Lighting"):FindFirstChildOfClass("BlurEffect")
	if blur ~= nil then
		local blurTween = TweenService:Create(blur, PROMPT_TWEEN_INFO, { Size = 0 })
		blurTween.Completed:Once(function()
			blur.Enabled = false
		end)
		blurTween:Play()
	end
end

function MonetizationController.StartPassPrompt(passName: string)
	local passConfig = PassesConfig[passName]
	if passConfig == nil then
		log.warn(`StartPassPrompt: unknown pass "{passName}"`)
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, passConfig.PassID)
	openPromptAnimation()
end

function MonetizationController.StartProductPrompt(productName: string)
	local productConfig = ProductsConfig[productName]
	if productConfig == nil then
		log.warn(`StartProductPrompt: unknown product "{productName}"`)
		return
	end
	MarketplaceService:PromptProductPurchase(player, productConfig.ProductID)
	openPromptAnimation()
end

function MonetizationController.StartPackPrompt(packName: string)
	local packConfig = PacksConfig[packName]
	if packConfig == nil then
		log.warn(`StartPackPrompt: unknown pack "{packName}"`)
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

function MonetizationController.SetPassButton(button: GuiButton, passName: string)
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartPassPrompt(passName)
	end)

	if MonetizationController.IsPassOwned(passName) then
		applyOwnedState(button)
		return
	end

	DataController.observe({ "UISystem", "GiftedPasses" }, function(value: any)
		if type(value) == "table" and value[passName] then
			applyOwnedState(button)
		end
	end)
end

function MonetizationController.SetProductButton(button: GuiButton, productName: string)
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartProductPrompt(productName)
	end)
end

function MonetizationController.SetPackButton(button: GuiButton, packName: string)
	button.MouseButton1Click:Connect(function()
		MonetizationController.StartPackPrompt(packName)
	end)

	if MonetizationController.IsPackOwned(packName) then
		applyOwnedState(button)
		return
	end

	DataController.observe({ "UISystem", "Packs" }, function(value: any)
		if type(value) == "table" and table.find(value, packName) ~= nil then
			applyOwnedState(button)
		end
	end)
end

function MonetizationController.SetPassGiftButton(button: GuiButton, passName: string)
	button.MouseButton1Click:Connect(function()
		giftData.GiftType = "Pass"
		giftData.GiftName = passName
		local frame = Frames.get("GiftPlayerChoose")
		local main = frame:WaitForChild("Main")
		local holder = main:WaitForChild("Holder")
		local heading = holder:WaitForChild("HeadngText") :: TextLabel
		heading.Text = `- Gift "{passName}" To -`
		UISignals.OpenFrame.Fire("GiftPlayerChoose")
	end)
end

function MonetizationController.SetProductGiftButton(button: GuiButton, productName: string)
	button.MouseButton1Click:Connect(function()
		giftData.GiftType = "Product"
		giftData.GiftName = productName
		local frame = Frames.get("GiftPlayerChoose")
		local main = frame:WaitForChild("Main")
		local holder = main:WaitForChild("Holder")
		local heading = holder:WaitForChild("HeadngText") :: TextLabel
		heading.Text = `- Gift "{productName}" To -`
		UISignals.OpenFrame.Fire("GiftPlayerChoose")
	end)
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
	areYouSure.Text = `Are you sure you want to gift "{giftData.GiftName}" to {username}?`

	UISignals.OpenFrame.Fire("GiftConfirm", false)
end

local function createPlayerFrame(
	scrollFrame: ScrollingFrame,
	template: Frame,
	userId: number,
	username: string,
	displayName: string,
	isFriend: boolean?
)
	if scrollFrame:FindFirstChild(tostring(userId)) ~= nil then
		return
	end

	local frame = template:Clone()
	frame.Name = tostring(userId)
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

	local inServer = Players:GetPlayerByUserId(userId) ~= nil
	if inServer and isFriend then
		frame.LayoutOrder = 1
	elseif inServer then
		frame.LayoutOrder = 2
	elseif isFriend then
		frame.LayoutOrder = 3
	end

	if isFriend then
		frame:SetAttribute("Friend", true)
	end

	frame.Parent = scrollFrame
end

function MonetizationController.Init()
	Net.promptStart.listen(function()
		openPromptAnimation()
	end)
end

function MonetizationController.Start()
	DataController.observe({ "UISystem", "GiftedPasses" }, function(value: any)
		if type(value) == "table" then
			giftedPasses = value
		end
	end)

	DataController.observe({ "UISystem", "Packs" }, function(value: any)
		if type(value) == "table" then
			ownedPacks = value
		end
	end)

	local giftPlayerChooseFrame = Frames.get("GiftPlayerChoose")
	local giftConfirmFrame = Frames.get("GiftConfirm")
	local main = giftPlayerChooseFrame:WaitForChild("Main")
	local scrollFrame = main:WaitForChild("Holder") :: ScrollingFrame
	local template = scrollFrame:WaitForChild("Template") :: Frame
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
		UISignals.OpenFrame.Fire("Shop")
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
				createPlayerFrame(scrollFrame, template, item.Id, item.Username, item.DisplayName, true)
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

	for _, other in Players:GetPlayers() do
		if other ~= player then
			createPlayerFrame(scrollFrame, template, other.UserId, other.Name, other.DisplayName, false)
		end
	end

	Players.PlayerAdded:Connect(function(other)
		createPlayerFrame(scrollFrame, template, other.UserId, other.Name, other.DisplayName, false)
	end)

	Players.PlayerRemoving:Connect(function(other)
		local entry = scrollFrame:FindFirstChild(tostring(other.UserId))
		if entry == nil then
			return
		end
		if entry:GetAttribute("Friend") then
			entry.LayoutOrder = 3
		else
			entry:Destroy()
		end
	end)

	local yesButton = giftConfirmFrame:WaitForChild("Yes") :: GuiButton
	yesButton.MouseButton1Click:Connect(function()
		Net.giftStart.send({
			targetUserId = giftData.GiftTarget,
			itemKind = giftData.GiftType,
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

	MarketplaceService.PromptProductPurchaseFinished:Connect(closePromptAnimation)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(closePromptAnimation)

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
