--!strict
--[[
	Rotating 3-slot promo carousel on the HUD's right side
	(PlayerGui.Main.HUD.Right.SideProducts.SideItem1-3). Ported from the source's
	Controllers/PromotionController.luau, and avoids repeating the same items
	back-to-back. Configured passes remain visible after purchase so the HUD
	always keeps all three authored slots.

	Cycle: slide in -> hold 15s on screen -> slide out -> stay hidden 15s ->
	swap contents while off screen -> repeat. Contents are only ever swapped
	while the slots are off screen, so a promo is never replaced mid-display.
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

local SLOT_COUNT = 3
local DISPLAY_SECONDS = 15
local HIDDEN_SECONDS = 15
local TWEEN_SECONDS = 0.6
local STAGGER_SECONDS = 0.2

-- Anchors the source uses to park a slot off the right edge vs. flush on screen.
local ANCHOR_SHOWN = Vector2.new(0, 0.5)
local ANCHOR_HIDDEN = Vector2.new(1, 0.5)

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

-- Instant, un-tweened placement. Used once at boot so the first tweenIn()
-- actually animates instead of the slots popping in wherever the GUI authored
-- them.
local function snapContainer(item: GuiObject, anchor: Vector2)
	local container = item:FindFirstChild("Container")
	if container ~= nil and container:IsA("GuiObject") then
		container.AnchorPoint = anchor
	end
end

local function tweenContainer(item: GuiObject, anchor: Vector2, easingDirection: Enum.EasingDirection)
	local container = item:FindFirstChild("Container")
	if container == nil or not container:IsA("GuiObject") then
		return nil
	end
	local tweenInfo = TweenInfo.new(TWEEN_SECONDS, Enum.EasingStyle.Sine, easingDirection)
	local tween = TweenService:Create(container, tweenInfo, { AnchorPoint = anchor })
	tween:Play()
	return tween
end

local function pickRandom(pool: { PoolEntry }, count: number, previousKeys: { [string]: boolean }): { PoolEntry }
	-- When the pool cannot fill more than the slots there is nothing to rotate:
	-- every entry is shown every cycle. Shuffling here would only reorder which
	-- slot each promo lands in, which reads as the banner swapping to a
	-- "different" promo for no reason. Sort instead -- the pool is built by
	-- dictionary iteration, so its order is not stable between refreshes.
	if #pool <= count then
		local stable = table.clone(pool)
		table.sort(stable, function(a: PoolEntry, b: PoolEntry): boolean
			return a.Name < b.Name
		end)
		return stable
	end

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
	local sideProducts = right:WaitForChild("SideProducts")

	local items: { [number]: GuiObject } = {
		[1] = sideProducts:WaitForChild("SideItem1") :: GuiObject,
		[2] = sideProducts:WaitForChild("SideItem2") :: GuiObject,
		[3] = sideProducts:WaitForChild("SideItem3") :: GuiObject,
	}

	local activePromotions: { [number]: ActivePromotion } = {
		[1] = { Type = "", Name = "" },
		[2] = { Type = "", Name = "" },
		[3] = { Type = "", Name = "" },
	}

	-- Staggered slide, then wait out the last slot's tween so the caller's
	-- dwell timer only starts once every slot has actually settled.
	local function tweenAll(anchor: Vector2, easingDirection: Enum.EasingDirection)
		local lastTween: Tween? = nil
		for i = 1, SLOT_COUNT do
			lastTween = tweenContainer(items[i], anchor, easingDirection)
			if i < SLOT_COUNT then
				task.wait(STAGGER_SECONDS)
			end
		end
		if lastTween ~= nil then
			lastTween.Completed:Wait()
		end
	end

	local function tweenIn()
		tweenAll(ANCHOR_SHOWN, Enum.EasingDirection.In)
	end

	local function tweenOut()
		tweenAll(ANCHOR_HIDDEN, Enum.EasingDirection.Out)
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
			if passConfig ~= nil and passConfig.Enabled then
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

		local picked = pickRandom(pool, SLOT_COUNT, previousKeys)

		for i = 1, SLOT_COUNT do
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

	for i = 1, SLOT_COUNT do
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

	-- Park every slot off screen before the first fill, so the opening slide is
	-- an actual animation and no stale authored content is ever on screen.
	for i = 1, SLOT_COUNT do
		snapContainer(items[i], ANCHOR_HIDDEN)
	end

	refreshPromotion()
	while true do
		tweenIn()
		task.wait(DISPLAY_SECONDS)
		tweenOut()
		-- Both the swap and the idle gap happen off screen; without the wait the
		-- loop slid straight back in with new contents, which looked like the
		-- banner cancelling itself.
		refreshPromotion()
		task.wait(HIDDEN_SECONDS)
	end
end

return PromotionController
