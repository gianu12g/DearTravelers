--!strict
--[[
	Rotating 3-slot promo carousel on the HUD's right side
	(PlayerGui.Main.HUD.Right.SideItem1-3). Ported from the source's
	Controllers/PromotionController.luau: tweens items in/out every 15s,
	filters out already-owned Packs/Passes via MonetizationController,
	and avoids repeating the same items back-to-back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Log = require(ReplicatedStorage.Shared.Log)
local MonetizationController = require(script.Parent.MonetizationController)
local PacksConfig = require(ReplicatedStorage.Shared.UISystem.Config.Packs)
local PassesConfig = require(ReplicatedStorage.Shared.UISystem.Config.Passes)
local ProductsConfig = require(ReplicatedStorage.Shared.UISystem.Config.Products)
local PromotionConfig = require(ReplicatedStorage.Shared.UISystem.Config.Promotion)

local log = Log.new("PromotionController")

local player = Players.LocalPlayer

type PromoType = "Pack" | "Pass" | "Product" | ""

type PoolEntry = {
	Type: PromoType,
	Name: string,
	Icon: number,
	Price: number?,
}

type ActivePromotion = {
	Type: PromoType,
	Name: string,
}

local PromotionController = {}

local function fillItemData(item: GuiObject, name: string, icon: number, price: number?)
	local container = item:FindFirstChild("Container")
	if container == nil then
		return
	end
	local iconLabel = container:FindFirstChild("Icon")
	if iconLabel ~= nil and iconLabel:IsA("ImageLabel") then
		iconLabel.Image = `rbxassetid://{icon}`
	end
	local priceLabel = container:FindFirstChild("Price")
	if priceLabel ~= nil and priceLabel:IsA("TextLabel") then
		priceLabel.Text = tostring(price or "?")
	end
	local titleLabel = container:FindFirstChild("Title")
	if titleLabel ~= nil and titleLabel:IsA("TextLabel") then
		titleLabel.Text = name
	end
end

local function tweenContainer(item: GuiObject, anchor: Vector2, easingDirection: Enum.EasingDirection)
	local container = item:FindFirstChild("Container")
	if container == nil or not container:IsA("GuiObject") then
		return nil
	end
	local tweenInfo = TweenInfo.new(0.6, Enum.EasingStyle.Sine, easingDirection)
	local tween = TweenService:Create(container, tweenInfo, { AnchorPoint = anchor })
	tween:Play()
	return tween
end

local function pickRandom(pool: { PoolEntry }, count: number, previousKeys: { [string]: boolean }): { PoolEntry }
	local preferred: { PoolEntry } = {}
	local fallback: { PoolEntry } = {}

	for _, entry in pool do
		if previousKeys[entry.Name] then
			table.insert(fallback, entry)
		else
			table.insert(preferred, entry)
		end
	end

	local function shuffle(list: { PoolEntry })
		for i = #list, 2, -1 do
			local j = math.random(i)
			list[i], list[j] = list[j], list[i]
		end
	end

	shuffle(preferred)
	shuffle(fallback)

	local combined: { PoolEntry } = {}
	for _, entry in preferred do
		table.insert(combined, entry)
	end
	for _, entry in fallback do
		table.insert(combined, entry)
	end

	local result: { PoolEntry } = {}
	for i = 1, math.min(count, #combined) do
		table.insert(result, combined[i])
	end
	return result
end

function PromotionController.Start()
	local playerGui = player:WaitForChild("PlayerGui")
	local main = playerGui:WaitForChild("Main")
	local hud = main:WaitForChild("HUD")
	local right = hud:WaitForChild("Right")

	local items: { [number]: GuiObject } = {
		[1] = right:WaitForChild("SideItem1") :: GuiObject,
		[2] = right:WaitForChild("SideItem2") :: GuiObject,
		[3] = right:WaitForChild("SideItem3") :: GuiObject,
	}

	local activePromotions: { [number]: ActivePromotion } = {
		[1] = { Type = "", Name = "" },
		[2] = { Type = "", Name = "" },
		[3] = { Type = "", Name = "" },
	}

	local function tweenIn()
		local lastTween: Tween? = nil
		for i = 1, 3 do
			lastTween = tweenContainer(items[i], Vector2.new(0, 0.5), Enum.EasingDirection.In)
			task.wait(0.2)
		end
		if lastTween ~= nil then
			lastTween.Completed:Wait()
		end
	end

	local function tweenOut()
		for i = 1, 3 do
			tweenContainer(items[i], Vector2.new(1, 0.5), Enum.EasingDirection.Out)
			task.wait(0.2)
		end
	end

	local function refreshPromotion()
		local previousKeys: { [string]: boolean } = {}
		for _, info in activePromotions do
			if info.Name ~= "" then
				previousKeys[info.Name] = true
			end
		end

		local pool: { PoolEntry } = {}

		for packName, iconId in PromotionConfig.Packs do
			local packConfig = PacksConfig[packName]
			if packConfig ~= nil and packConfig.Enabled and not MonetizationController.IsPackOwned(packName) then
				table.insert(pool, {
					Type = "Pack",
					Name = packName,
					Icon = iconId,
					Price = MonetizationController.GetPrice("Pack", packName),
				})
			end
		end

		for passName, iconId in PromotionConfig.Passes do
			local passConfig = PassesConfig[passName]
			if passConfig ~= nil and passConfig.Enabled and not MonetizationController.IsPassOwned(passName) then
				table.insert(pool, {
					Type = "Pass",
					Name = passName,
					Icon = iconId,
					Price = MonetizationController.GetPrice("Pass", passName),
				})
			end
		end

		for productName, iconId in PromotionConfig.Products do
			if ProductsConfig[productName] ~= nil then
				table.insert(pool, {
					Type = "Product",
					Name = productName,
					Icon = iconId,
					Price = MonetizationController.GetPrice("Product", productName),
				})
			end
		end

		local picked = pickRandom(pool, 3, previousKeys)

		for i = 1, 3 do
			local item = items[i]
			local entry = picked[i]

			if entry ~= nil then
				activePromotions[i] = { Type = entry.Type, Name = entry.Name }
				fillItemData(item, entry.Name, entry.Icon, entry.Price)
				item.Visible = true
			else
				activePromotions[i] = { Type = "", Name = "" }
				item.Visible = false
			end
		end
	end

	for i = 1, 3 do
		local item = items[i]
		if item:IsA("GuiButton") then
			item.MouseButton1Click:Connect(function()
				local info = activePromotions[i]
				if info.Type == "Product" then
					MonetizationController.StartProductPrompt(info.Name)
				elseif info.Type == "Pack" then
					MonetizationController.StartPackPrompt(info.Name)
				elseif info.Type == "Pass" then
					MonetizationController.StartPassPrompt(info.Name)
				end
			end)
		end
	end

	log.info("ready")

	while true do
		tweenIn()
		refreshPromotion()
		tweenOut()
		task.wait(15)
	end
end

return PromotionController
