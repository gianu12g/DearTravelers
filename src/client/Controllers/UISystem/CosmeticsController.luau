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

-- The one place that decides EquipButton.PriceTag.Text -- shared by the full
-- render() and the in-place equip update, so the two paths cannot drift
-- apart on what a card should say.
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
		-- Holder's ScrollingFrame uses AutomaticCanvasSize=Y, so destroying
		-- every card collapses the canvas and clamps CanvasPosition to 0 --
		-- save/restore across the rebuild so an open menu doesn't yank the
		-- player back to the top. Restored next resumption cycle (task.defer),
		-- once the new cards' layout has actually recomputed the canvas;
		-- Roblox clamps the assignment to the valid range itself.
		local savedCanvasPosition = scrollFrame.CanvasPosition

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
				-- Stripped before this card is ever parented (below), so
				-- UIKitController's DescendantAdded wiring never sees the
				-- attribute and never spawns Purchase's Shine effect inside
				-- this hidden subtree -- race-free by construction, not by
				-- timing. The card Icon's own Float effect is untouched.
				clearEffectAttribute(purchase)
				for _, descendant in purchase:GetDescendants() do
					clearEffectAttribute(descendant)
				end
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
					-- VFX cards are permanently gradient-only. Strip the
					-- template's Float effect before parenting so UIKit never
					-- starts an invisible infinite tween for this hidden icon.
					clearEffectAttribute(icon)
					for _, descendant in icon:GetDescendants() do
						clearEffectAttribute(descendant)
					end
				end
			end

			local equipButton = card:FindFirstChild("EquipButton")
			if equipButton ~= nil and equipButton:IsA("GuiButton") then
				local priceTag = equipButton:FindFirstChild("PriceTag")
				if priceTag ~= nil and priceTag:IsA("TextLabel") then
					priceTag.Text = equipButtonLabel(entry.Id, equippedId, defaultId)
				end
				equipButton.MouseButton1Click:Connect(function()
					onEquipButtonClicked(slot, entry.Id)
				end)
			end

			card.Parent = holder
		end

		task.defer(function()
			scrollFrame.CanvasPosition = savedCanvasPosition
		end)
	end

	-- Updates just `id`'s card (if the active slot even has one owned/rendered
	-- for it -- the other tab, or an unowned id, means no-op) in place: same
	-- label decision render() uses, no destroy/rebuild, no scroll disturbance.
	local function updateEquipButtonLabel(id: string)
		local card = holder:FindFirstChild(id)
		if card == nil then
			return
		end
		local equipButton = card:FindFirstChild("EquipButton")
		if equipButton == nil or not equipButton:IsA("GuiButton") then
			return
		end
		local priceTag = equipButton:FindFirstChild("PriceTag")
		if priceTag == nil or not priceTag:IsA("TextLabel") then
			return
		end
		local slot: CosmeticsCatalog.Slot = activeSlot
		priceTag.Text = equipButtonLabel(id, equippedIds[slot], defaultIdForSlot(slot))
	end

	-- {"Cosmetics","Owned"} fires once per server tableInsert -- grant-all
	-- does hundreds in one burst, which would otherwise mean hundreds of full
	-- render()s. Coalesce to one: set a dirty flag, defer a single render,
	-- and let any observer fires arriving before that deferred call runs
	-- just keep the flag set instead of scheduling a second one.
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

	-- Re-renders (debounced -- see scheduleRender) so a live grant() shows up
	-- while the menu is already open.
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

	-- In place, NOT a re-render -- see updateEquipButtonLabel. At 131 cards a
	-- full render() per equip (destroy + reclone + rebuild everything) is
	-- wasted work for a change that only ever affects two cards.
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
