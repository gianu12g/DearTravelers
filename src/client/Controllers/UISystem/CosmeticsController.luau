--!strict
--[[
	Cosmetics menu (COSMETICS_PLAN.md): keycap Theme, squishy Beam, and Merge
	Pop catalogs, owned-only, equip/unequip. `Top.Keys`, `Top.Beams`, and
	`Top.MergePop` pick the active slot; `Top.Close` already has Ui-Close = true,
	handled globally by
	UIKitController -- nothing to wire here.

	Equip is fire-and-forget: Net.cosmeticEquip carries no result packet, and
	the accepted (or silently rejected) equip is visible only via
	DataController.observe on the replicated Cosmetics fields, which is what
	drives the targeted card updates below.

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
local launchBeamsFolder = ReplicatedStorage.Assets.VFX.LaunchBeams
local mergeVfxFolder = ReplicatedStorage.Assets.VFX.Merge

--[[
	Keycap-theme cards use Images.ThemeIcons (every id is preloaded at boot
	via AssetIds/Preloader.luau). Beam and Merge Pop cards intentionally have
	no icon: their authored ColorSequence drives the card background gradient
	instead.
]]

local CosmeticsController = {}

local function catalogForSlot(slot: CosmeticsCatalog.Slot): { CosmeticsCatalog.CatalogEntry }
	if slot == "KeycapThemes" then
		return CosmeticsCatalog.KeycapThemes
	elseif slot == "SquishyBeams" then
		return CosmeticsCatalog.SquishyBeams
	end
	return CosmeticsCatalog.MergePops
end

local function defaultIdForSlot(slot: CosmeticsCatalog.Slot): string
	if slot == "KeycapThemes" then
		return CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID
	elseif slot == "SquishyBeams" then
		return CosmeticsCatalog.DEFAULT_SQUISHY_BEAM_ID
	end
	return CosmeticsCatalog.DEFAULT_MERGE_POP_ID
end

-- The one place that decides EquipButton.PriceTag.Text -- shared by pooled
-- card configuration and in-place equip updates so the two paths cannot
-- drift apart.
local function equipButtonLabel(id: string, equippedId: string, defaultId: string): string
	if id ~= equippedId then
		return "Equip"
	elseif id == defaultId then
		return "Equipped"
	end
	return "Unequip"
end

-- Purchase (and its ShineContainer descendant) carries Ui-Effect = Shine in
-- the template, for the shop's future reuse of this same card. This menu
-- hides Purchase, but UIKitController's DescendantAdded wiring still spawns
-- the Shine clone + infinite tween for every card unless the attribute is
-- stripped -- x131 idle tweens inside invisible buttons otherwise.
local function clearEffectAttribute(instance: Instance)
	if instance:GetAttribute("Ui-Effect") ~= nil then
		instance:SetAttribute("Ui-Effect", nil)
	end
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

function CosmeticsController.Start()
	local frame = Frames.get("Cosmetics")
	local top = frame:WaitForChild("Top")
	local keysButton = top:WaitForChild("Keys") :: GuiButton
	local beamsButton = top:WaitForChild("Beams") :: GuiButton
	local mergePopButton = top:WaitForChild("MergePop") :: GuiButton
	local scrollFrame = frame:WaitForChild("MainScrollingFrame") :: ScrollingFrame
	local holder = scrollFrame:WaitForChild("Holder") :: Frame
	local template = holder:WaitForChild("ThemeTemplate1") :: Frame

	local activeSlot: CosmeticsCatalog.Slot = "KeycapThemes"
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
	local equippedIds: { KeycapThemes: string, SquishyBeams: string, MergePops: string } = {
		KeycapThemes = CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID,
		SquishyBeams = CosmeticsCatalog.DEFAULT_SQUISHY_BEAM_ID,
		MergePops = CosmeticsCatalog.DEFAULT_MERGE_POP_ID,
	}
	type CardView = {
		Slot: CosmeticsCatalog.Slot,
		Id: string,
		Root: Frame,
		Title: TextLabel?,
		Gradient: UIGradient?,
		DefaultGradientColor: ColorSequence?,
		Icon: ImageLabel?,
		DefaultIconImage: string,
		EquipPriceTag: TextLabel?,
	}
	local cardPool: { CardView } = {}
	local activeCardsById: { [string]: CardView } = {}
	local hasRendered = false
	local gradientCache: {
		KeycapThemes: { [string]: ColorSequence },
		SquishyBeams: { [string]: ColorSequence },
		MergePops: { [string]: ColorSequence },
	} =
		{
			KeycapThemes = {},
			SquishyBeams = {},
			MergePops = {},
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

	-- Card Instances and their button connections are pooled. Tab switches
	-- reconfigure the pool; live grants add/remove only the changed cards.
	local function gradientFor(slot: CosmeticsCatalog.Slot, id: string): ColorSequence?
		local cached = gradientCache[slot][id]
		if cached ~= nil then
			return cached
		end

		local sequence: ColorSequence?
		if slot == "KeycapThemes" then
			local colors = KeyCapsController.getThemeColors(id)
			sequence = if colors ~= nil then colorSequenceFromTheme(colors) else nil
		elseif slot == "SquishyBeams" then
			sequence = colorSequenceFromBeam(id)
		else
			sequence = colorSequenceFromMergePop(id)
		end
		if sequence ~= nil then
			gradientCache[slot][id] = sequence
		end
		return sequence
	end

	local function updateEquipButtonLabel(id: string)
		local card = activeCardsById[id]
		if card == nil then
			return
		end
		local priceTag = card.EquipPriceTag
		if priceTag == nil then
			return
		end
		local slot: CosmeticsCatalog.Slot = activeSlot
		priceTag.Text = equipButtonLabel(id, equippedIds[slot], defaultIdForSlot(slot))
	end

	local function createCardView(): CardView
		local root = template:Clone() :: Frame
		root.Visible = false

		local titleInstance = root:FindFirstChild("Title")
		local title = if titleInstance ~= nil and titleInstance:IsA("TextLabel") then titleInstance else nil
		local gradientInstance = root:FindFirstChild("UIGradient")
		local gradient = if gradientInstance ~= nil and gradientInstance:IsA("UIGradient")
			then gradientInstance
			else nil
		local iconInstance = root:FindFirstChild("Icon")
		local icon = if iconInstance ~= nil and iconInstance:IsA("ImageLabel") then iconInstance else nil

		-- Purchase remains permanently hidden in Cosmetics. Strip its effect
		-- before the pooled card is first parented so UIKit never starts the
		-- hidden Shine tween.
		local purchase = root:FindFirstChild("Purchase")
		if purchase ~= nil and purchase:IsA("GuiObject") then
			purchase.Visible = false
			clearEffectAttribute(purchase)
			for _, descendant in purchase:GetDescendants() do
				clearEffectAttribute(descendant)
			end
		end

		local equipButtonInstance = root:FindFirstChild("EquipButton")
		local equipButton = if equipButtonInstance ~= nil and equipButtonInstance:IsA("GuiButton")
			then equipButtonInstance
			else nil
		local equipPriceTag: TextLabel? = nil
		if equipButton ~= nil then
			local priceTag = equipButton:FindFirstChild("PriceTag")
			if priceTag ~= nil and priceTag:IsA("TextLabel") then
				equipPriceTag = priceTag
			end
		end

		local card: CardView = {
			Slot = "KeycapThemes",
			Id = "",
			Root = root,
			Title = title,
			Gradient = gradient,
			DefaultGradientColor = if gradient ~= nil then gradient.Color else nil,
			Icon = icon,
			DefaultIconImage = if icon ~= nil then icon.Image else "",
			EquipPriceTag = equipPriceTag,
		}
		if equipButton ~= nil then
			equipButton.MouseButton1Click:Connect(function()
				onEquipButtonClicked(card.Slot, card.Id)
			end)
		end
		return card
	end

	local function configureCard(
		card: CardView,
		slot: CosmeticsCatalog.Slot,
		entry: CosmeticsCatalog.CatalogEntry,
		catalogIndex: number
	)
		local needsStaticUpdate = card.Slot ~= slot or card.Id ~= entry.Id
		card.Slot = slot
		card.Id = entry.Id
		card.Root.LayoutOrder = catalogIndex
		if needsStaticUpdate then
			card.Root.Name = entry.Id

			local title = card.Title
			if title ~= nil then
				title.Text = entry.DisplayName
			end

			local gradient = card.Gradient
			if gradient ~= nil then
				gradient.Color = gradientFor(slot, entry.Id) or card.DefaultGradientColor or gradient.Color
			end

			local icon = card.Icon
			if icon ~= nil then
				if slot == "KeycapThemes" then
					icon.Visible = true
					local iconId = Images.ThemeIcons[entry.Id]
					icon.Image = if iconId ~= nil then `rbxassetid://{iconId}` else card.DefaultIconImage
				else
					icon.Visible = false
				end
			end
		end

		local priceTag = card.EquipPriceTag
		if priceTag ~= nil then
			priceTag.Text = equipButtonLabel(entry.Id, equippedIds[slot], defaultIdForSlot(slot))
		end
		if card.Root.Parent == nil then
			card.Root.Parent = holder
		end
		card.Root.Visible = true
	end

	local function nextInactiveCard(): CardView
		for _, card in cardPool do
			if not card.Root.Visible then
				return card
			end
		end
		local card = createCardView()
		table.insert(cardPool, card)
		return card
	end

	local function renderSlot()
		local savedCanvasPosition = scrollFrame.CanvasPosition
		for _, card in cardPool do
			card.Root.Visible = false
		end
		table.clear(activeCardsById)

		local slot: CosmeticsCatalog.Slot = activeSlot
		local owned = ownedIds[slot]
		for catalogIndex, entry in catalogForSlot(slot) do
			if not owned[entry.Id] then
				continue
			end
			local card = nextInactiveCard()
			configureCard(card, slot, entry, catalogIndex)
			activeCardsById[entry.Id] = card
		end
		hasRendered = true

		task.defer(function()
			scrollFrame.CanvasPosition = savedCanvasPosition
		end)
	end

	local function reconcileActiveOwnership()
		local slot: CosmeticsCatalog.Slot = activeSlot
		local owned = ownedIds[slot]

		for id, card in activeCardsById do
			if not owned[id] then
				card.Root.Visible = false
				activeCardsById[id] = nil
			end
		end

		for catalogIndex, entry in catalogForSlot(slot) do
			if owned[entry.Id] and activeCardsById[entry.Id] == nil then
				local card = nextInactiveCard()
				configureCard(card, slot, entry, catalogIndex)
				activeCardsById[entry.Id] = card
			end
		end
	end

	-- A grant-all can fire the ownership observer hundreds of times. Coalesce
	-- each burst, then reconcile only added/removed cards. The first callback
	-- performs the one required initial pool render.
	local ownedRefreshPending = false
	local function scheduleOwnershipRefresh()
		if ownedRefreshPending then
			return
		end
		ownedRefreshPending = true
		task.defer(function()
			ownedRefreshPending = false
			if hasRendered then
				reconcileActiveOwnership()
			else
				renderSlot()
			end
		end)
	end

	keysButton.MouseButton1Click:Connect(function()
		if activeSlot ~= "KeycapThemes" or not hasRendered then
			activeSlot = "KeycapThemes"
			renderSlot()
		end
	end)
	beamsButton.MouseButton1Click:Connect(function()
		if activeSlot ~= "SquishyBeams" or not hasRendered then
			activeSlot = "SquishyBeams"
			renderSlot()
		end
	end)
	mergePopButton.MouseButton1Click:Connect(function()
		if activeSlot ~= "MergePops" or not hasRendered then
			activeSlot = "MergePops"
			renderSlot()
		end
	end)

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
		scheduleOwnershipRefresh()
	end)

	-- Equip changes continue to patch only the previous and current labels.
	DataController.observe({ "Cosmetics", "KeycapThemeId" }, function(value: any)
		if type(value) ~= "string" then
			return
		end
		local previousId = equippedIds.KeycapThemes
		equippedIds.KeycapThemes = value
		if activeSlot ~= "KeycapThemes" then
			return
		end
		updateEquipButtonLabel(previousId)
		updateEquipButtonLabel(value)
	end)

	DataController.observe({ "Cosmetics", "SquishyBeamId" }, function(value: any)
		if type(value) ~= "string" then
			return
		end
		local previousId = equippedIds.SquishyBeams
		equippedIds.SquishyBeams = value
		if activeSlot ~= "SquishyBeams" then
			return
		end
		updateEquipButtonLabel(previousId)
		updateEquipButtonLabel(value)
	end)

	DataController.observe({ "Cosmetics", "MergePopId" }, function(value: any)
		if type(value) ~= "string" then
			return
		end
		local previousId = equippedIds.MergePops
		equippedIds.MergePops = value
		if activeSlot ~= "MergePops" then
			return
		end
		updateEquipButtonLabel(previousId)
		updateEquipButtonLabel(value)
	end)

	log.info("ready")
end

return CosmeticsController
