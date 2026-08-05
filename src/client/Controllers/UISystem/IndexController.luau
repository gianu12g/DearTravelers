--!strict
--[[
	The Squishy Index: one card per model level, revealed as the player first
	owns each one. IndexService owns discovery server-side; this renders it.

	Structurally this is ThemeShopController's menu with the purchase layer
	removed -- same pooled-card model, same tab-switch shape, same coalesced
	DataController.observe, same CanvasPosition preservation across a re-render.
	That is deliberate and load-bearing for scroll performance: the pool is
	built once at the catalog's full size and thereafter only reconfigured, so a
	discovery never destroys and re-clones the holder, and the card count never
	grows (unlike ThemeShop, this catalog is a fixed 30).

	Undiscovered presentation is exactly what the Studio template authors:
	Decor.Icon tinted pitch black, the `?` label reading "???", and
	Decor.squishyName reading "UNKNOWN!". Discovery UNDOES that rather than
	applying a separate style, so re-authoring the locked look in Studio needs
	no code change here -- the defaults are captured off the template clone at
	pool-creation time (DefaultIconColor et al) instead of being hardcoded.

	The Companions tab is a stub: the feature does not exist yet, so the button
	is wired to a no-op that keeps the Squishies tab selected rather than left
	dead (a dead button reads as a bug) -- see the companionBtn handler.

	No Init() -- Frames.get yields, and nothing here depends on another module's
	Start() having run. Same reasoning as ThemeShopController's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local ScrollCanvas = require(script.Parent.Parent.Parent.UI.UISystem.ScrollCanvas)

local log = Log.new("IndexController")

local IndexController = {}

--[[
	Squishies are indexed by MODEL LEVEL 1..MAX_MODEL_LEVEL, which is the
	rebirth-independent ceiling (30), NOT maxModelLevel(rebirths). The index is
	a collection log: levels beyond the player's current rebirth unlock must
	still be listed as undiscovered, or the log would visibly shrink and grow
	as they rebirth.
]]
local function catalogSize(): number
	return math.min(RebirthConfig.MAX_MODEL_LEVEL, #MergeConfig.Tiers)
end

function IndexController.Start()
	local frame = Frames.get("Index")
	local top = frame:WaitForChild("Top")
	local holderParent = frame:WaitForChild("HolderParent")
	local scrollFrame = holderParent:WaitForChild("Holder") :: ScrollingFrame
	local template = scrollFrame:WaitForChild("1") :: Frame
	local squishiesButton = frame:WaitForChild("squishiesBtn") :: GuiButton
	local companionButton = frame:WaitForChild("companionBtn") :: GuiButton

	local discoveredLabelInstance = top:FindFirstChild("discoveredLabel")
	local discoveredLabel = if discoveredLabelInstance ~= nil and discoveredLabelInstance:IsA("TextLabel")
		then discoveredLabelInstance
		else nil
	local discoveredShadowInstance = top:FindFirstChild("discoveredLabelShadow")
	local discoveredShadow = if discoveredShadowInstance ~= nil and discoveredShadowInstance:IsA("TextLabel")
		then discoveredShadowInstance
		else nil

	--[[
		Undoes the three authored traits that individually defeat
		AutomaticCanvasSize (fixed canvas scale + percentage-sized children,
		scale padding, and the canvas-constraining UIAspectRatioConstraint) and
		returns the inner AutomaticSize.Y content Frame that ThemeShop and
		Cosmetics both have. See ScrollCanvas's header for the measurements
		behind each one. Called BEFORE `template.Parent = nil` below, because
		freezing the template's height needs it still laid out.
	]]
	local cardHolder = ScrollCanvas.normalize(scrollFrame, template)

	--[[
		Card-level ClipsDescendants is deliberately NOT set, even though the
		Sunburst overhangs the card's top by ~10px. Measured on a live card, the
		card clips two things, not one:

		    Sunburst      spills  10.3px above the top
		    squishyName   spills  12.0px below the bottom  (and carries a UIStroke)

		So clipping to contain the Sunburst would shave the name label and its
		stroke by more than it trims off the burst -- the same stroke-cutting
		this whole frame is wrapped in HolderParent to avoid. If the Sunburst
		overhang ever needs removing, resize it (it is 1.206 x 1.609 scale of
		Decor) rather than clipping its parent.
	]]

	--[[
		The template lives INSIDE the ScrollingFrame in Studio (it is the
		authored example card), so it would otherwise render as a permanent
		31st card that no data drives. Reparent it out before the pool is built
		rather than hiding it: a Visible=false child still occupies a
		UIListLayout slot's ordering and still counts toward AbsoluteContentSize.
	]]
	template.Parent = nil

	type CardView = {
		Level: number,
		IsDiscovered: boolean,
		Root: Frame,
		Icon: ImageLabel?,
		DefaultIconImage: string,
		DefaultIconColor: Color3,
		-- The squishyName instance. Named for its ROLE (it shows the tier
		-- value) rather than its authored instance name, which no longer
		-- describes what it displays.
		ValueLabel: TextLabel?,
	}

	local cardPool: { CardView } = {}
	local discoveredLevels: { [number]: true } = {}
	local discoveredCount = 0

	local function iconImageForLevel(level: number, fallback: string): string
		local assetId = Images.SquishyIcons[level]
		return if assetId ~= nil then `rbxassetid://{assetId}` else fallback
	end

	local function createCardView(level: number): CardView
		local root = template:Clone() :: Frame
		root.Name = tostring(level)
		-- UIListLayout honours LayoutOrder; the authored template is 0 for
		-- every clone, which would leave ordering to Instance creation order.
		root.LayoutOrder = level

		local decor = root:FindFirstChild("Decor")
		local iconInstance = if decor ~= nil then decor:FindFirstChild("Icon") else nil
		local icon = if iconInstance ~= nil and iconInstance:IsA("ImageLabel") then iconInstance else nil
		-- The tier value lives in the squishyName slot now -- that is the
		-- position the card was designed to label from. Its authored instance
		-- name is kept (renaming it in Studio would only break this lookup),
		-- so ValueLabel below is named for what it shows, not what it is called.
		local nameInstance = if decor ~= nil then decor:FindFirstChild("squishyName") else nil
		local valueLabel = if nameInstance ~= nil and nameInstance:IsA("TextLabel") then nameInstance else nil
		if valueLabel ~= nil then
			valueLabel.Visible = true
		end

		-- Authored with "?" as its literal Instance name, so this is a name
		-- lookup, not a typo. Hidden rather than destroyed: re-enabling it is a
		-- one-line change and the authored instance stays visible to whoever
		-- opens the template in Studio. Nothing reflows (Decor and the card
		-- place their children absolutely), so hiding costs nothing.
		local questionInstance = root:FindFirstChild("?")
		if questionInstance ~= nil and questionInstance:IsA("GuiObject") then
			questionInstance.Visible = false
		end

		return {
			Level = level,
			-- Seeded false so the first applyDiscovery for a discovered level
			-- always registers as a change and paints; see its early-out.
			IsDiscovered = false,
			Root = root,
			Icon = icon,
			DefaultIconImage = if icon ~= nil then icon.Image else "",
			DefaultIconColor = if icon ~= nil then icon.ImageColor3 else Color3.new(0, 0, 0),
			ValueLabel = valueLabel,
		}
	end

	local function applyDiscovery(card: CardView, isDiscovered: boolean, force: boolean?)
		if card.IsDiscovered == isDiscovered and force ~= true then
			return
		end
		card.IsDiscovered = isDiscovered

		local icon = card.Icon
		if icon ~= nil then
			-- The SAME per-level art in both states -- an undiscovered card is
			-- that squishy's own silhouette, not a generic placeholder, so the
			-- image is set unconditionally and only the tint changes. White is
			-- the neutral tint that shows the art as authored; the blacked-out
			-- colour comes off the template, so re-authoring it in Studio needs
			-- no change here.
			icon.Image = iconImageForLevel(card.Level, card.DefaultIconImage)
			icon.ImageColor3 = if isDiscovered then Color3.new(1, 1, 1) else card.DefaultIconColor
		end

		-- The tier value IS the card's name now, in both states -- no "???"
		-- placeholder. Knowing a locked squishy is worth 512 is part of what
		-- makes the gap worth filling, and the black silhouette already carries
		-- "undiscovered" on its own.
		local valueLabel = card.ValueLabel
		if valueLabel ~= nil then
			valueLabel.Text = Format.FormatNumber(RebirthConfig.tierNumberForModelLevel(card.Level))
		end
	end

	local function refreshDiscoveredCounter()
		if discoveredLabel == nil and discoveredShadow == nil then
			return
		end
		local text = `{Format.FormatNumber(discoveredCount)}/{Format.FormatNumber(catalogSize())}`
		if discoveredLabel ~= nil then
			discoveredLabel.Text = text
		end
		if discoveredShadow ~= nil then
			discoveredShadow.Text = text
		end
	end

	--[[
		Builds the pool once, at the catalog's full size. Unlike ThemeShop --
		whose pool grows when a larger slot's catalog is opened -- this catalog
		is fixed, so there is no grow path and no hide path: every card is
		created, parented, and stays. A discovery only ever flips one card's
		presentation.

		CanvasPosition is saved and restored around the initial parenting for
		the same reason ThemeShop's renderSlot does it: parenting children into
		a ScrollingFrame re-runs the layout, which can clamp CanvasPosition
		while AbsoluteContentSize is still catching up.
	]]
	local function buildPool()
		local savedCanvasPosition = scrollFrame.CanvasPosition
		for level = 1, catalogSize() do
			local card = createCardView(level)
			table.insert(cardPool, card)
			applyDiscovery(card, discoveredLevels[level] == true, true)
			card.Root.Parent = cardHolder
		end
		task.defer(function()
			scrollFrame.CanvasPosition = savedCanvasPosition
		end)
	end

	local function refreshAllDiscovery()
		for _, card in cardPool do
			applyDiscovery(card, discoveredLevels[card.Level] == true)
		end
		refreshDiscoveredCounter()
	end

	--[[
		{"Index","DiscoveredSquishies"} fires once per server tableInsert, and a
		base activation replays every persisted squishy through
		Spawning.spawnRestingPart -- so a returning player with 12 levels found
		produces a burst of up to 12 callbacks in one frame. Coalesce to a
		single patch pass, exactly as ThemeShop does for {"Cosmetics","Owned"}.
	]]
	local refreshPending = false
	local function scheduleDiscoveryRefresh()
		if refreshPending then
			return
		end
		refreshPending = true
		task.defer(function()
			refreshPending = false
			if #cardPool == 0 then
				buildPool()
				refreshDiscoveredCounter()
			else
				refreshAllDiscovery()
			end
		end)
	end

	-- No bare buildPool() here: discoveredLevels is empty until the observe
	-- callback below fires, which it does immediately with the current value
	-- (DataController.observe replays on registration). Building first would
	-- paint every already-discovered card as locked for one frame -- the same
	-- reason ThemeShopController skips its own bare renderSlot().
	DataController.observe({ "Index", "DiscoveredSquishies" }, function(value: any)
		if type(value) ~= "table" then
			return
		end

		local levels: { [number]: true } = {}
		local count = 0
		local maxLevel = catalogSize()
		for _, level in value do
			-- Server-sanitized already (DataService.compactModelLevels), but a
			-- replicated value is still `any` here and a level beyond the
			-- catalog would index no card at all.
			if type(level) == "number" and level == level and level >= 1 and level <= maxLevel then
				local whole = math.floor(level)
				if levels[whole] == nil then
					levels[whole] = true
					count += 1
				end
			end
		end

		discoveredLevels = levels
		discoveredCount = count
		scheduleDiscoveryRefresh()
	end)

	--[[
		Tab stubs. Squishies is the only real tab today, so its handler exists
		purely to be the no-op that Companions falls back to -- keeping both
		buttons responsive without pretending Companions has content. When
		companions land, this is the seam: give each tab an active-catalog
		selector and route renderSlot through it, exactly like ThemeShop's
		activeSlot.
	]]
	squishiesButton.MouseButton1Click:Connect(function()
		-- Already the only view; nothing to switch to.
	end)
	companionButton.MouseButton1Click:Connect(function()
		log.info("companions tab pressed -- feature not implemented yet")
	end)

	refreshDiscoveredCounter()
	log.info("ready")
end

return IndexController
