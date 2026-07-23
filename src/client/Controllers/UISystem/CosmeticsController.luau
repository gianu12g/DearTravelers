--!strict
--[[
	Cosmetics menu (COSMETICS_PLAN.md): keycap Theme + squishy Trail catalog,
	owned-only, equip/unequip. `Top.Keys` / `Top.Trails` pick the active slot;
	`Top.Close` already has Ui-Close = true, handled globally by
	UIKitController -- nothing to wire here.

	Equip is fire-and-forget: Net.cosmeticEquip carries no result packet, and
	the accepted (or silently rejected) equip is visible only via
	DataController.observe on the replicated Cosmetics fields, which is what
	actually drives every re-render below.

	No Init() -- Frames.get yields, and there is no unsolicited early-push
	race to guard against here (same reasoning as WheelSpinController's own
	no-Init note): the menu only reacts to things this client did (open the
	frame, click a card) or to data that arrives after Start() has already
	registered every observer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local KeyCapsController = require(script.Parent.Parent.KeyCapsController)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CosmeticsController")

--[[
	Per-slot icon override lookup (Shared.AssetIds.Images' rbxassetid-number
	convention -- every id here is preloaded at boot via
	AssetIds/Preloader.luau, which recurses into nested groups). Keycap
	themes are backed directly by Images.ThemeIcons -- one entry per catalog
	id, added to Images.luau itself, no local duplicate needed here. Squishy
	trails have no icon assets authored yet (COSMETICS_PLAN.md): an empty
	local map until they exist, same two-step flow (an Images.luau entry,
	then a line in TRAIL_ICON_OVERRIDES) once art does.
]]
local TRAIL_ICON_OVERRIDES: { [string]: number } = {}

local CosmeticsController = {}

local function catalogForSlot(slot: CosmeticsCatalog.Slot): { CosmeticsCatalog.CatalogEntry }
	if slot == "KeycapThemes" then
		return CosmeticsCatalog.KeycapThemes
	end
	return CosmeticsCatalog.SquishyTrails
end

local function defaultIdForSlot(slot: CosmeticsCatalog.Slot): string
	if slot == "KeycapThemes" then
		return CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID
	end
	return CosmeticsCatalog.DEFAULT_SQUISHY_TRAIL_ID
end

local function iconOverridesForSlot(slot: CosmeticsCatalog.Slot): { [string]: number }
	if slot == "KeycapThemes" then
		return Images.ThemeIcons
	end
	return TRAIL_ICON_OVERRIDES
end

local function toIdSet(ids: { string }): { [string]: true }
	local set: { [string]: true } = {}
	for _, id in ids do
		set[id] = true
	end
	return set
end

-- ColorSequence.new throws above 20 keypoints, so themes with more colors
-- than that get sampled down to MAX_GRADIENT_KEYPOINTS evenly-spaced steps
-- instead of one keypoint per color. Every theme today has 5-6 colors, so
-- sampleCount == #colors and this reduces to the identity mapping -- current
-- behavior is unchanged.
local MAX_GRADIENT_KEYPOINTS = 20

-- Theme Colors (dark -> light) become an evenly-spaced ColorSequence for the
-- card's own UIGradient. ColorSequence requires >= 2 keypoints with the
-- first at Time 0 and the last at Time 1 -- both guaranteed exactly by this
-- spacing, not just approximately.
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

function CosmeticsController.Start()
	local frame = Frames.get("Cosmetics")
	local top = frame:WaitForChild("Top")
	local keysButton = top:WaitForChild("Keys") :: GuiButton
	local trailsButton = top:WaitForChild("Trails") :: GuiButton
	local scrollFrame = frame:WaitForChild("MainScrollingFrame")
	local holder = scrollFrame:WaitForChild("Holder") :: Frame
	local template = holder:WaitForChild("ThemeTemplate1") :: Frame

	local activeSlot: CosmeticsCatalog.Slot = "KeycapThemes"
	local ownedIds: { KeycapThemes: { [string]: true }, SquishyTrails: { [string]: true } } = {
		KeycapThemes = {},
		SquishyTrails = {},
	}
	local equippedIds: { KeycapThemes: string, SquishyTrails: string } = {
		KeycapThemes = CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID,
		SquishyTrails = CosmeticsCatalog.DEFAULT_SQUISHY_TRAIL_ID,
	}

	-- Not equipped -> equip it. Equipped and already the default -> no-op
	-- (the default is never unequipped from). Equipped and NOT the default
	-- -> equip the default, i.e. unequip.
	local function onEquipButtonClicked(slot: CosmeticsCatalog.Slot, id: string)
		if id ~= equippedIds[slot] then
			Net.cosmeticEquip.send({ slot = slot, id = id })
			return
		end
		local defaultId = defaultIdForSlot(slot)
		if id ~= defaultId then
			Net.cosmeticEquip.send({ slot = slot, id = defaultId })
		end
	end

	-- Clones `template` once per owned entry in the active slot, in catalog
	-- order. Never touches the template original (Parent stays Holder,
	-- Visible stays false) or the Holder's own UIListLayout.
	local function render()
		for _, child in holder:GetChildren() do
			if child ~= template and child:IsA("Frame") then
				child:Destroy()
			end
		end

		local slot: CosmeticsCatalog.Slot = activeSlot
		local owned = ownedIds[slot]
		local equippedId = equippedIds[slot]
		local defaultId = defaultIdForSlot(slot)
		local layoutOrder = 0

		for _, entry in catalogForSlot(slot) do
			if not owned[entry.Id] then
				continue
			end
			layoutOrder += 1

			local card = template:Clone() :: Frame
			card.Name = entry.Id
			card.Visible = true
			card.LayoutOrder = layoutOrder

			local title = card:FindFirstChild("Title")
			if title ~= nil and title:IsA("TextLabel") then
				title.Text = entry.DisplayName
			end
			local purchase = card:FindFirstChild("Purchase")
			if purchase ~= nil and purchase:IsA("GuiObject") then
				purchase.Visible = false
			end

			-- Gradient restyle is THEME-ONLY -- trail card visuals beyond the
			-- icon stay name-only for now, stubbed pending design
			-- (COSMETICS_PLAN.md "Trails UI").
			if slot == "KeycapThemes" then
				local colors = KeyCapsController.getThemeColors(entry.Id)
				local gradient = card:FindFirstChild("UIGradient")
				if colors ~= nil and gradient ~= nil and gradient:IsA("UIGradient") then
					local sequence = colorSequenceFromTheme(colors)
					if sequence ~= nil then
						gradient.Color = sequence
					end
				end
			end

			local iconId = iconOverridesForSlot(slot)[entry.Id]
			local icon = card:FindFirstChild("Icon")
			if iconId ~= nil and icon ~= nil and icon:IsA("ImageLabel") then
				icon.Image = `rbxassetid://{iconId}`
			end

			local equipButton = card:FindFirstChild("EquipButton")
			if equipButton ~= nil and equipButton:IsA("GuiButton") then
				local priceTag = equipButton:FindFirstChild("PriceTag")
				if priceTag ~= nil and priceTag:IsA("TextLabel") then
					if entry.Id ~= equippedId then
						priceTag.Text = "Equip"
					elseif entry.Id == defaultId then
						priceTag.Text = "Equipped"
					else
						priceTag.Text = "Unequip"
					end
				end
				equipButton.MouseButton1Click:Connect(function()
					onEquipButtonClicked(slot, entry.Id)
				end)
			end

			card.Parent = holder
		end
	end

	keysButton.MouseButton1Click:Connect(function()
		activeSlot = "KeycapThemes"
		render()
	end)
	trailsButton.MouseButton1Click:Connect(function()
		activeSlot = "SquishyTrails"
		render()
	end)

	-- Re-renders so a live grant() shows up while the menu is already open.
	DataController.observe({ "Cosmetics", "Owned" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		local keycapThemes = value.KeycapThemes
		local squishyTrails = value.SquishyTrails
		ownedIds.KeycapThemes = toIdSet(if type(keycapThemes) == "table" then keycapThemes else {})
		ownedIds.SquishyTrails = toIdSet(if type(squishyTrails) == "table" then squishyTrails else {})
		render()
	end)

	DataController.observe({ "Cosmetics", "KeycapThemeId" }, function(value: any)
		if type(value) ~= "string" then
			return
		end
		equippedIds.KeycapThemes = value
		render()
	end)

	DataController.observe({ "Cosmetics", "SquishyTrailId" }, function(value: any)
		if type(value) ~= "string" then
			return
		end
		equippedIds.SquishyTrails = value
		render()
	end)

	log.info("ready")
end

return CosmeticsController
