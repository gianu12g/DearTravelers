--!strict
--[[
	The Quests panel: Daily / Weekly / Monthly tabs over a scrolling list of
	quest rows (description + progress bar + "45/100" counter).

	Same pooling model as IndexController and ThemeShopController: rows are
	created once, reconfigured on tab switch, never destroyed and re-cloned, and
	CanvasPosition is preserved across a re-render. Unlike the Index this frame
	is NOT run through UI.UISystem.ScrollCanvas -- see the note at the top of
	Start() for why its authored layout is already correct.

	Descriptions and goals come from the SHARED catalog (Config/Quests) and
	progress comes from the player's replicated profile, so the client renders a
	row without the server having to describe it -- only how far along it is.

	Rewards are automatic; there is no claim button on the authored row. See
	Config/Quests's header for why.

	No Init() -- Frames.get yields and nothing here needs another module's
	Start() to have run. Same reasoning as ThemeShopController's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.Parent.UI.Motion)
local QuestsConfig = require(ReplicatedStorage.Shared.UISystem.Config.Quests)

local log = Log.new("QuestsController")

local QuestsController = {}

function QuestsController.Start()
	local frame = Frames.get("Quests")
	local top = frame:WaitForChild("Top")
	local holderParent = frame:WaitForChild("HolderParent")
	local scrollFrame = holderParent:WaitForChild("Holder") :: ScrollingFrame
	local template = scrollFrame:WaitForChild("1") :: Frame

	--[[
		Deliberately NOT run through UI.UISystem.ScrollCanvas, unlike the Index.

		This frame is already authored to fit its content exactly: the canvas is
		one window tall and each row is 0.32 of it, so three rows fill the view
		with nothing to scroll. Normalizing would freeze those percentage heights
		into fixed pixel offsets to break a circularity that only matters when
		the canvas has to GROW -- here it buys nothing and costs the rows their
		ability to rescale with the frame.

		The moment a period carries more than three quests this stops being true
		and the rows will overflow without scrolling. That is the point to switch
		this back to ScrollCanvas.normalize (and re-add the inner holder), not
		before.
	]]
	local rowHolder = scrollFrame

	-- Authored inside the ScrollingFrame as the example row; it would otherwise
	-- render as a permanent extra entry that no data drives.
	template.Parent = nil

	type RowView = {
		Root: Frame,
		Description: TextLabel?,
		DescriptionShadow: TextLabel?,
		Counter: TextLabel?,
		CounterShadow: TextLabel?,
		ProgressBar: GuiObject?,
		ProgressBarFullSize: UDim2,
		-- Which quest this pooled row currently shows, and the fraction its bar
		-- is already at. Together they decide tween-vs-snap: see applyProgress.
		QuestId: string,
		BarFraction: number,
		BarTween: Motion.Handle?,
	}

	local rowPool: { RowView } = {}
	local activePeriod: QuestsConfig.Period = "Daily"
	-- Replicated progress, per period, keyed by quest id. Empty until the first
	-- observe callback lands; a missing id simply reads as 0 progress, so a row
	-- renders correctly before any data arrives rather than blanking.
	local progressByPeriod: { [string]: { [string]: number } } = {}

	--[[
		The authored row carries each text twice -- a main label and a shadow
		directly behind it -- and they must always agree. Collect them in child
		order: the first match is the shadow (authored behind), the second the
		main label. Both are driven together by setText below rather than the
		caller having to remember there are two.
	]]
	local function collectPair(root: Instance, matches: (TextLabel) -> boolean): (TextLabel?, TextLabel?)
		local found: { TextLabel } = {}
		for _, d in root:GetDescendants() do
			if d:IsA("TextLabel") and matches(d) then
				table.insert(found, d)
			end
		end
		return found[1], found[2]
	end

	local function setText(main: TextLabel?, shadow: TextLabel?, text: string)
		if main ~= nil then
			main.Text = text
		end
		if shadow ~= nil then
			shadow.Text = text
		end
	end

	local function createRowView(): RowView
		local root = template:Clone() :: Frame
		root.Visible = false

		-- The counter is the label authored as "45/100"; the description is the
		-- other pair. Matching on the authored slash keeps this working if the
		-- labels are ever renamed, since the template names them all "TextLabel".
		local counter, counterShadow = collectPair(root, function(l)
			return string.find(l.Text, "/", 1, true) ~= nil
		end)
		local description, descriptionShadow = collectPair(root, function(l)
			return string.find(l.Text, "/", 1, true) == nil
		end)

		local barInstance = root:FindFirstChild("progressBar", true)
		local progressBar = if barInstance ~= nil and barInstance:IsA("GuiObject") then barInstance else nil

		return {
			Root = root,
			Description = description,
			DescriptionShadow = descriptionShadow,
			Counter = counter,
			CounterShadow = counterShadow,
			ProgressBar = progressBar,
			-- Captured from the authored bar, so a full bar is exactly what was
			-- designed rather than an assumed UDim2.fromScale(1, 1).
			ProgressBarFullSize = if progressBar ~= nil then progressBar.Size else UDim2.fromScale(1, 1),
			QuestId = "",
			BarFraction = 0,
			BarTween = nil,
		}
	end

	--[[
		Drives the bar's X to `fraction` of the full track width.

		The authored bar is centre-anchored (AnchorPoint 0.5) with
		Position.X = Size.X.Scale / 2 -- 0.234113 against 0.468227 -- which is
		what pins its LEFT edge to 0. That relationship is the placement, so it
		is preserved rather than replaced: X size and X position move together,
		and the anchor is left exactly as authored. Tweening Size alone would
		grow the bar in both directions and walk its left edge off the track.

		Full is X scale 1 (the whole track), not the authored 0.468 -- that value
		is the mock's "45/100" example, not the maximum. Y and both offsets are
		carried through untouched, so the bar keeps its designed thickness.

		Tweens only when the SAME quest's progress changed. A row showing a
		different quest (first paint, or a tab switch reusing this pooled row)
		snaps, because animating from the previous quest's value would show
		progress that never happened. Any in-flight tween is cancelled first so
		two updates in quick succession cannot fight over the same properties.
	]]
	local function applyProgress(row: RowView, questId: string, fraction: number)
		local bar = row.ProgressBar
		if bar == nil then
			return
		end

		local authored = row.ProgressBarFullSize
		local goalSize = UDim2.new(fraction, authored.X.Offset, authored.Y.Scale, authored.Y.Offset)
		local basePosition = bar.Position
		local goalPosition = UDim2.new(fraction / 2, basePosition.X.Offset, basePosition.Y.Scale, basePosition.Y.Offset)
		local sameQuest = row.QuestId == questId

		local inFlight = row.BarTween
		if inFlight ~= nil then
			inFlight.cancel()
			row.BarTween = nil
		end

		if sameQuest and fraction ~= row.BarFraction then
			row.BarTween = Motion.tween(bar, { Size = goalSize, Position = goalPosition }, "smooth", function()
				row.BarTween = nil
			end)
		else
			bar.Size = goalSize
			bar.Position = goalPosition
		end

		row.QuestId = questId
		row.BarFraction = fraction
	end

	local function configureRow(row: RowView, quest: QuestsConfig.Quest, index: number)
		row.Root.LayoutOrder = index
		setText(row.Description, row.DescriptionShadow, quest.Description)

		local tracked = progressByPeriod[activePeriod]
		local raw = if tracked ~= nil then tracked[quest.Id] else nil
		local goal = if quest.Goal > 0 then quest.Goal else 1
		local progress = math.clamp(if type(raw) == "number" and raw == raw then raw else 0, 0, goal)
		setText(row.Counter, row.CounterShadow, `{Format.FormatNumber(progress)}/{Format.FormatNumber(quest.Goal)}`)

		applyProgress(row, quest.Id, progress / goal)

		if row.Root.Parent == nil then
			row.Root.Parent = rowHolder
		end
		row.Root.Visible = true
	end

	--[[
		Reconfigures the pool for `activePeriod`, growing it only when this
		period has more quests than any period rendered so far, and hiding the
		surplus. Identical strategy to ThemeShopController.renderSlot -- see its
		comment for why the pool is never torn down.
	]]
	local function renderPeriod()
		local savedCanvasPosition = scrollFrame.CanvasPosition
		local quests = QuestsConfig.Catalog[activePeriod]

		for index, quest in quests do
			local row = rowPool[index]
			if row == nil then
				row = createRowView()
				table.insert(rowPool, row)
			end
			configureRow(row, quest, index)
		end
		for index = #quests + 1, #rowPool do
			rowPool[index].Root.Visible = false
		end

		task.defer(function()
			scrollFrame.CanvasPosition = savedCanvasPosition
		end)
	end

	for _, period in QuestsConfig.PERIODS do
		local button = top:FindFirstChild(period)
		if button ~= nil and button:IsA("GuiButton") then
			button.MouseButton1Click:Connect(function()
				if activePeriod ~= period then
					activePeriod = period
					renderPeriod()
				end
			end)
		else
			log.warn(`Quests.Top.{period} is missing or is not a button -- that tab will not switch`)
		end
	end

	--[[
		One observer per track. The server writes progress one quest at a time
		(DataService.set on {"Quests", period, "Progress", id}), so a burst of
		metric awards in a single frame would otherwise repaint per write --
		coalesce behind task.defer exactly as ThemeShop does for owned cosmetics.

		Only the ACTIVE period repaints; the other two just update their cached
		table and are picked up whenever their tab is next opened.
	]]
	local refreshPending = false
	local function scheduleRefresh()
		if refreshPending then
			return
		end
		refreshPending = true
		task.defer(function()
			refreshPending = false
			renderPeriod()
		end)
	end

	for _, period in QuestsConfig.PERIODS do
		DataController.observe({ "Quests", period, "Progress" }, function(value: any)
			progressByPeriod[period] = if type(value) == "table" then value else {}
			if activePeriod == period then
				scheduleRefresh()
			end
		end)
	end

	renderPeriod()
	log.info("ready")
end

return QuestsController
