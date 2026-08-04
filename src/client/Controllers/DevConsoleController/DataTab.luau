--!strict
--[[
	The Data tab: a generic editor over the target's whole profile. Filtering
	(search text, the noise toggle) happens entirely client-side against the
	latest Snapshot so a keystroke costs no round trip.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Snapshot = require(script.Parent.Snapshot)
local Style = require(script.Parent.Style)
local Widgets = require(script.Parent.Widgets)

--[[
	Dotted path prefixes the Data tab hides until "Show noise" is on. Every one
	is either an array the console can't meaningfully edit one row at a time
	(a devSet writes scalars, so editing Cosmetics.Owned.KeycapThemes.3 in place
	is the only thing you could do to it, and Grant All Cosmetics is the button
	you actually wanted), or a ledger that exists for idempotency and should be
	read, not typed into.

	Prefixes match on segment boundaries, so "Merge.Squishies" hides
	Merge.Squishies.7.Tier without also hiding a hypothetical Merge.SquishiesX.
]]
local NOISY_PATH_PREFIXES = {
	"Cosmetics.Owned",
	"Merge.Squishies",
	"UISystem.ProcessedPurchaseIds",
	"UISystem.RedeemedCodes",
	"UISystem.GiftedPasses",
	"UISystem.Packs",
	"UISystem.PendingGifts",
	"UISystem.ProcessedTicketTransferIds",
	"UISystem.PendingTicketTransfers",
	"UISystem.FriendsReward.JoinedFriends",
}

type DataRow = {
	frame: Frame,
	valueBox: TextBox,
	path: { string },
	kind: string,
}

export type Deps = {
	getTarget: () -> Player,
	setStatus: (boolean, string) -> (),
	registerPage: (string, Frame) -> (),
}

local DataTab = {}

local deps: Deps? = nil

local dataScroll: ScrollingFrame? = nil
local dataCountLabel: TextLabel? = nil
local noiseToggleButton: TextButton? = nil
local newKeyPathBox: TextBox? = nil
local newKeyValueBox: TextBox? = nil

local dataRows: { [string]: DataRow } = {}
local searchText = ""
local showNoise = false

local connections: { RBXScriptConnection } = {}

function DataTab.setup(newDeps: Deps)
	deps = newDeps
end

local function isNoisyPath(dotted: string): boolean
	for _, prefix in NOISY_PATH_PREFIXES do
		if dotted == prefix or string.sub(dotted, 1, #prefix + 1) == `{prefix}.` then
			return true
		end
	end
	return false
end

local function commitRow(row: DataRow, box: TextBox)
	local currentDeps = deps :: Deps
	Net.devSet.send({
		targetPlayer = currentDeps.getTarget(),
		path = row.path,
		kind = row.kind,
		value = box.Text,
	})
end

local function createDataRow(entry: Snapshot.SnapshotEntry, layoutOrder: number, parent: ScrollingFrame): DataRow
	local frame = Instance.new("Frame")
	frame.Name = Snapshot.dottedPath(entry.path)
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, -Style.SCROLL_ROW_INSET, 0, Style.ROW_HEIGHT - 4)
	frame.LayoutOrder = layoutOrder

	local label = Widgets.newLabel(
		Snapshot.dottedPath(entry.path),
		UDim2.fromScale(0.62, 1),
		Style.SMALL_TEXT_SIZE,
		Style.MUTED_TEXT_COLOR
	)
	label.Name = "PathLabel"
	-- Truncating the FRONT keeps the leaf key visible, which is the half of a
	-- long dotted path that tells you which field you are looking at.
	label.TextTruncate = Enum.TextTruncate.SplitWord
	label.Parent = frame

	local box = Widgets.newTextBox("", UDim2.new(0.38, -Style.GAP, 1, 0))
	box.Name = "ValueBox"
	box.Position = UDim2.fromScale(0.62, 0)
	box.Text = entry.value
	box.Parent = frame

	local row: DataRow = { frame = frame, valueBox = box, path = entry.path, kind = entry.kind }

	box.FocusLost:Connect(function(enterPressed: boolean)
		if not enterPressed then
			return
		end
		commitRow(row, box)
	end)

	frame.Parent = parent
	return row
end

--[[
	Rebuilds from the latest Snapshot, reusing existing row instances keyed by
	dotted path rather than destroying and recreating everything. That's what
	makes the "don't stomp a focused box" rule below possible: a full
	destroy/recreate would blow away the TextBox the developer is mid-edit in,
	which is exactly the poll-fights-the-typist bug this has to avoid.

	Filtering happens here rather than at the packet, so toggling a filter costs
	no round trip and the row you were editing survives one.
]]
function DataTab.rebuildDataRows()
	local body = dataScroll
	if body == nil then
		return
	end

	local entries = Snapshot.getEntries()
	local seen: { [string]: boolean } = {}
	local shown = 0
	local order = 0

	for _, entry in entries do
		local key = Snapshot.dottedPath(entry.path)

		if not showNoise and isNoisyPath(key) then
			continue
		end
		if searchText ~= "" and string.find(string.lower(key), searchText, 1, true) == nil then
			continue
		end

		order += 1
		shown += 1
		seen[key] = true

		local row = dataRows[key]
		if row == nil then
			dataRows[key] = createDataRow(entry, order, body)
		else
			row.frame.LayoutOrder = order
			row.path = entry.path
			row.kind = entry.kind
			if not row.valueBox:IsFocused() then
				row.valueBox.Text = entry.value
			end
		end
	end

	for key, row in dataRows do
		if not seen[key] then
			row.frame:Destroy()
			dataRows[key] = nil
		end
	end

	local countLabel = dataCountLabel
	if countLabel ~= nil then
		countLabel.Text = `{shown}/{#entries}`
	end
end

-- Destroys every row instance immediately, without touching the Snapshot or
-- rebuilding. Used when the target changes, so the OLD target's rows never
-- show under the NEW target's label even for one frame.
function DataTab.clearRows()
	for key, row in dataRows do
		row.frame:Destroy()
		dataRows[key] = nil
	end
end

local function setShowNoise(enabled: boolean)
	showNoise = enabled

	local button = noiseToggleButton
	if button ~= nil then
		button.Text = `Noise: {if enabled then "shown" else "hidden"}`
		button.BackgroundColor3 = if enabled then Style.ACCENT_COLOR else Style.FIELD_COLOR
	end

	DataTab.rebuildDataRows()
end

-- Dotted entry means a key containing a literal "." can't be created here --
-- an accepted limit of a text affordance, not something worth a richer
-- parser for.
local function inferKind(raw: string): string
	if tonumber(raw) ~= nil then
		return "number"
	elseif raw == "true" or raw == "false" then
		return "boolean"
	end
	return "string"
end

local function onCreateClicked()
	local currentDeps = deps :: Deps
	local pathBox = newKeyPathBox
	local valueBox = newKeyValueBox
	if pathBox == nil or valueBox == nil then
		return
	end

	local pathText = pathBox.Text
	if pathText == "" then
		currentDeps.setStatus(false, "enter a dotted path first")
		return
	end

	Net.devSet.send({
		targetPlayer = currentDeps.getTarget(),
		path = string.split(pathText, "."),
		kind = inferKind(valueBox.Text),
		value = valueBox.Text,
	})
end

function DataTab.build(parent: Frame)
	local currentDeps = deps :: Deps
	local page = Widgets.newPage(parent, "Data", currentDeps.registerPage)

	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.Size = UDim2.new(1, 0, 0, Style.ROW_HEIGHT)
	toolbar.BackgroundTransparency = 1
	toolbar.Parent = page

	local search = Widgets.newTextBox("filter by path, e.g. coins", UDim2.new(0.52, -Style.GAP, 1, 0))
	search.Name = "SearchBox"
	search.Parent = toolbar

	local noiseToggle = Widgets.newButton("Noise: hidden", UDim2.new(0.32, -Style.GAP, 1, 0))
	noiseToggle.Name = "NoiseToggle"
	noiseToggle.Position = UDim2.fromScale(0.52, 0)
	noiseToggle.TextSize = Style.SMALL_TEXT_SIZE
	noiseToggle.Parent = toolbar
	noiseToggleButton = noiseToggle

	local count = Widgets.newLabel("0/0", UDim2.fromScale(0.16, 1), Style.SMALL_TEXT_SIZE, Style.MUTED_TEXT_COLOR)
	count.Name = "CountLabel"
	count.Position = UDim2.fromScale(0.84, 0)
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Parent = toolbar
	dataCountLabel = count

	-- The scroll list owns the middle: toolbar above, new-key row below, both
	-- fixed height, so it takes whatever the window's current height leaves.
	local list = Widgets.newScrollList(
		page,
		"DataList",
		UDim2.fromOffset(0, Style.ROW_HEIGHT + Style.GAP),
		UDim2.new(1, 0, 1, -(2 * Style.ROW_HEIGHT + 2 * Style.GAP))
	)
	dataScroll = list

	local newKeyRow = Instance.new("Frame")
	newKeyRow.Name = "NewKeyRow"
	newKeyRow.AnchorPoint = Vector2.new(0, 1)
	newKeyRow.Position = UDim2.fromScale(0, 1)
	newKeyRow.Size = UDim2.new(1, 0, 0, Style.ROW_HEIGHT)
	newKeyRow.BackgroundTransparency = 1
	newKeyRow.Parent = page

	local pathBox = Widgets.newTextBox("Inventory.Sword", UDim2.new(0.44, -Style.GAP, 1, 0))
	pathBox.Name = "PathBox"
	pathBox.Parent = newKeyRow
	newKeyPathBox = pathBox

	local valueBox = Widgets.newTextBox("1", UDim2.new(0.34, -Style.GAP, 1, 0))
	valueBox.Name = "ValueBox"
	valueBox.Position = UDim2.fromScale(0.44, 0)
	valueBox.Parent = newKeyRow
	newKeyValueBox = valueBox

	local setButton = Widgets.newButton("Set", UDim2.fromScale(0.22, 1))
	setButton.Name = "SetButton"
	setButton.Position = UDim2.fromScale(0.78, 0)
	setButton.BackgroundColor3 = Style.ACCENT_COLOR
	setButton.Parent = newKeyRow

	setButton.Activated:Connect(onCreateClicked)
	noiseToggle.Activated:Connect(function()
		setShowNoise(not showNoise)
	end)

	-- Filter as you type. Rows are keyed by path and reused, so a keystroke
	-- costs the rows that actually appeared or disappeared, not a full rebuild.
	local searchChanged = search:GetPropertyChangedSignal("Text")
	table.insert(
		connections,
		searchChanged:Connect(function()
			searchText = string.lower(search.Text)
			DataTab.rebuildDataRows()
		end)
	)
end

function DataTab.cleanup()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	table.clear(dataRows)

	dataScroll = nil
	dataCountLabel = nil
	noiseToggleButton = nil
	newKeyPathBox = nil
	newKeyValueBox = nil
end

return DataTab
