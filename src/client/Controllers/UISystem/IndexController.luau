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

local log = Log.new("IndexController")

-- The template's authored strings for a level nobody has found yet. Read from
-- Studio rather than reproduced here would be circular (the template IS the
-- undiscovered state), so these two are the one place the locked copy lives.
local UNDISCOVERED_TIER_TEXT = "???"
local UNDISCOVERED_NAME_TEXT = "UNKNOWN!"

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
		Studio authored this grid around a fixed CanvasSize.Y scale of 1, with
		the cards AND the layout padding sized as percentages of that canvas.
		Switching to AutomaticCanvasSize without undoing that is circular --
		card height depends on canvas height while canvas height depends on the
		cards -- and the canvas collapses to zero instead of growing.

		Same fix, and same reasoning, as MonetizationController's gift list
		(see its freezeHeight comment): turn the already-resolved heights into
		OFFSETS first, then drop the fixed canvas. Only the Y axis is frozen --
		X stays a scale so the grid still reflows with the frame's width, which
		is what makes UIListLayout.Wraps do the right thing on other screen
		sizes.

		Done before `template.Parent = nil` below, because AbsoluteSize reads 0
		once an object is unparented -- and before any clone is taken, so all 30
		cards inherit the frozen height rather than each needing the same fix.
	]]
	local function freezeHeight(gui: GuiObject)
		local height = gui.AbsoluteSize.Y
		if height > 0 then
			gui.Size = UDim2.new(gui.Size.X.Scale, gui.Size.X.Offset, 0, height)
		end
	end
	freezeHeight(template)

	local listLayout = scrollFrame:FindFirstChildOfClass("UIListLayout")
	if listLayout ~= nil and listLayout.Padding.Scale ~= 0 then
		--[[
			Padding is a percentage of the same canvas the cards were, so it has
			the identical circularity. Convert against the frame's own width, the
			axis this horizontal, wrapping layout actually pads along.

			FLOOR, never round. The authored row is tuned to exactly fit: at
			621.74 wide, four 0.225-scale cards leave only 0.826px of slack
			across three gaps. The true padding is 0.033 * 621.74 = 20.517px;
			rounding that UP to 21 costs 1.449px total and silently drops the
			row to three cards. Flooring to 20 keeps four per row with slack,
			and losing a sub-pixel of gap is invisible where losing a column is
			not.
		]]
		local resolved = scrollFrame.AbsoluteSize.X * listLayout.Padding.Scale + listLayout.Padding.Offset
		if resolved > 0 then
			listLayout.Padding = UDim.new(0, math.floor(resolved))
		end
	end

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
		Both proven menus put the cards in an inner Frame rather than directly
		in the ScrollingFrame -- ThemeShop.MainScrollingFrame.Holder and
		Cosmetics.MainScrollingFrame.Holder are both AutomaticSize = Y,
		Size = {1,0},{0,0}, anchored top-centre. The Index was authored with its
		cards parented straight into the ScrollingFrame, so build the missing
		level here rather than diverging from the shape that already works.

		Why it matters beyond parity: AutomaticCanvasSize then measures ONE
		child whose own AutomaticSize does the accumulating, instead of
		re-measuring 30 siblings' contribution to AbsoluteContentSize. That is
		the arrangement whose scroll behavior you have already validated.
	]]
	local cardHolder = Instance.new("Frame")
	cardHolder.Name = "Holder"
	cardHolder.BackgroundTransparency = 1
	cardHolder.BorderSizePixel = 0
	cardHolder.AnchorPoint = Vector2.new(0.5, 0)
	cardHolder.Position = UDim2.fromScale(0.5, 0)
	cardHolder.Size = UDim2.fromScale(1, 0)
	cardHolder.AutomaticSize = Enum.AutomaticSize.Y
	if listLayout ~= nil then
		listLayout.Parent = cardHolder
	end
	cardHolder.Parent = scrollFrame

	--[[
		A UIAspectRatioConstraint on a ScrollingFrame constrains its CANVAS, not
		just its frame, and that silently defeats AutomaticCanvasSize. Measured
		in-session on this exact frame: with the constraint attached the canvas
		pins to 324px (= 621.74 width / 1.919 ratio, DominantAxis Width) while
		the content holder measures 1669px; detach it and the canvas immediately
		becomes 1669. Neither ThemeShop.MainScrollingFrame nor
		Cosmetics.MainScrollingFrame has one, and both report
		AbsoluteCanvasSize == their holder's height.

		Removed rather than worked around because it is inert for layout here:
		the frame's own AbsoluteSize stayed 324 with the constraint detached
		(its Size is already a scale of HolderParent, which carries the shape).
		Done in code, not Studio, because StarterGui is not Rojo-managed -- a
		place-side deletion would live only in the .rbxl and could be undone by
		any re-author of this frame.
	]]
	local aspectConstraint = scrollFrame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspectConstraint ~= nil then
		aspectConstraint:Destroy()
	end

	-- Now safe: the canvas is driven by the holder's content height instead of
	-- the other way round.
	scrollFrame.CanvasSize = UDim2.new()
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	-- ClipsDescendants is deliberately LEFT ALONE (authored false). ThemeShop
	-- and Cosmetics clip because their ScrollingFrame is the outer element;
	-- this frame is wrapped in HolderParent for exactly that job, and clipping
	-- here would shave the cards' UIStrokes at the scroll edge. It is also not
	-- needed for the canvas fix -- measured: with the aspect constraint removed
	-- the canvas reached 1669 whether clipping was on or off.

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
		TierLabel: TextLabel?,
		NameLabel: TextLabel?,
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
		local nameInstance = if decor ~= nil then decor:FindFirstChild("squishyName") else nil
		local nameLabel = if nameInstance ~= nil and nameInstance:IsA("TextLabel") then nameInstance else nil
		-- Authored with "?" as its literal Instance name (the undiscovered
		-- glyph), so this is a name lookup, not a typo.
		local tierInstance = root:FindFirstChild("?")
		local tierLabel = if tierInstance ~= nil and tierInstance:IsA("TextLabel") then tierInstance else nil

		return {
			Level = level,
			-- Seeded false so the first applyDiscovery for a discovered level
			-- always registers as a change and paints; see its early-out.
			IsDiscovered = false,
			Root = root,
			Icon = icon,
			DefaultIconImage = if icon ~= nil then icon.Image else "",
			DefaultIconColor = if icon ~= nil then icon.ImageColor3 else Color3.new(0, 0, 0),
			TierLabel = tierLabel,
			NameLabel = nameLabel,
		}
	end

	local function applyDiscovery(card: CardView, isDiscovered: boolean, force: boolean?)
		if card.IsDiscovered == isDiscovered and force ~= true then
			return
		end
		card.IsDiscovered = isDiscovered

		local icon = card.Icon
		if icon ~= nil then
			-- White is the neutral tint that shows the art as authored; the
			-- locked colour comes off the template so re-authoring it in Studio
			-- needs no change here.
			icon.ImageColor3 = if isDiscovered then Color3.new(1, 1, 1) else card.DefaultIconColor
			icon.Image = if isDiscovered
				then iconImageForLevel(card.Level, card.DefaultIconImage)
				else card.DefaultIconImage
		end

		local tierLabel = card.TierLabel
		if tierLabel ~= nil then
			tierLabel.Text = if isDiscovered
				then Format.FormatNumber(RebirthConfig.tierNumberForModelLevel(card.Level))
				else UNDISCOVERED_TIER_TEXT
		end

		local nameLabel = card.NameLabel
		if nameLabel ~= nil then
			local tierDef = MergeConfig.Tiers[card.Level]
			nameLabel.Text = if isDiscovered and tierDef ~= nil then tierDef.Name else UNDISCOVERED_NAME_TEXT
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
