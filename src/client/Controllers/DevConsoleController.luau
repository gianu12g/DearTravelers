--!strict
--[[
	The developer console. Built only when the server tells us we're a developer
	(Net.devAccess) -- see Services/DevService.luau, which owns that list and
	performs the server-side re-check that actually matters.

	Deliberately breaks UI-AND-MOTION.md's "Studio owns the GUIs" rule: this UI
	is built here, in code, rather than authored under StarterGui.Screens.
	Three reasons:

	  (a) A dev tool must not sit in StarterGui, which replicates to every
	      player whether or not they'll ever be allowed to open it.
	  (b) It must not be one of UIController's exclusive screens -- opening it
	      would close whatever the player actually has open (their HUD, a
	      menu), since UIController.open() closes other exclusive screens by
	      design.
	  (c) It should be versioned in git like the rest of the game, not
	      hand-authored in a Studio place file nobody diffs.

	Hiding the UI is NOT the security control. Rojo has no concept of "ship
	this script to some players" -- every client downloads this LocalScript
	regardless, so a non-developer could still fire Net.devSet by hand without
	ever seeing this icon. The only real gate is the re-check DevService does on
	every packet. The devAccess packet exists so non-developers don't pay for a
	UI they can never use, not to keep anyone out -- which is also why it is
	safe for the server to simply tell us the answer.

	THIS WINDOW IS SIZED IN PIXELS, and that is the second deliberate break with
	convention (screen UI in this project is Scale-based -- UI-AND-MOTION.md, and
	the Scale-based UIStroke conversion in commit c03f3d7). A window the
	developer drags and resizes has to be: the whole point of dragging a corner
	is to choose an absolute size, and Scale-sized rows inside it would make a
	bigger window show the same handful of taller rows instead of more rows,
	which is the opposite of why anyone resizes a console. Rows, chrome and text
	are therefore fixed pixel sizes, and only the window's own rect is state.
	Nothing here is authored against a target resolution: the initial rect is a
	fraction of the viewport, clamped, and re-clamped whenever the viewport
	changes, so the window cannot open (or be left) off-screen.

	Everything is grouped into four tabs so no single screen has to hold all of
	it: Actions (buttons that act on the target), Data (the generic editor over
	the target's whole profile), Players (who to target), Info (live readouts).
	The Data tab hides the fields nobody edits by hand -- owned-cosmetic arrays,
	the per-squishy rows, the purchase/code ledgers -- behind a toggle rather
	than dropping them, because the console is the only view of that data there
	is. The filtering is entirely local: DevService keeps sending the whole
	profile, which keeps that service policy-free about what a dev may look at.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Icon = require(ReplicatedStorage.Packages.TopbarPlus)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("DevConsoleController")

-- The panel ticks while it is open (only): the Info tab's readouts refresh on
-- every tick, a fresh profile snapshot is requested every SNAPSHOT_INTERVAL.
local TICK_INTERVAL = 0.5
local SNAPSHOT_INTERVAL = 2

local BACKGROUND_COLOR = Color3.fromRGB(24, 24, 28)
local CHROME_COLOR = Color3.fromRGB(32, 32, 38)
local FIELD_COLOR = Color3.fromRGB(40, 40, 46)
local BORDER_COLOR = Color3.fromRGB(62, 62, 72)
local ACCENT_COLOR = Color3.fromRGB(88, 140, 196)
local TEXT_COLOR = Color3.fromRGB(225, 225, 230)
local BRIGHT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local MUTED_TEXT_COLOR = Color3.fromRGB(170, 170, 178)
local OK_COLOR = Color3.fromRGB(90, 210, 130)
local ERROR_COLOR = Color3.fromRGB(230, 90, 90)
local WARN_COLOR = Color3.fromRGB(226, 170, 74)
local DANGER_COLOR = Color3.fromRGB(177, 70, 111)
local GRANT_COLOR = Color3.fromRGB(70, 130, 110)

-- Window rect bounds. MIN is "every control still reachable"; MAX exists so a
-- 4K screen doesn't get a console the size of a wall.
local MIN_WINDOW_SIZE = Vector2.new(380, 320)
local MAX_WINDOW_SIZE = Vector2.new(900, 900)
local INITIAL_WINDOW_FRACTION = Vector2.new(0.3, 0.6)

local TITLE_BAR_HEIGHT = 30
local TAB_STRIP_HEIGHT = 26
local STATUS_BAR_HEIGHT = 18
local GRIP_SIZE = 16
local PADDING = 8
local GAP = 6
local ROW_HEIGHT = 26
local PLAYER_ROW_HEIGHT = 34
local SECTION_HEADER_HEIGHT = 18
local SCROLLBAR_THICKNESS = 6
-- Rows leave the scrollbar its own gutter instead of sliding underneath it.
local SCROLL_ROW_INSET = SCROLLBAR_THICKNESS + 2

local TITLE_TEXT_SIZE = 15
local BODY_TEXT_SIZE = 13
local SMALL_TEXT_SIZE = 12

local TAB_ORDER = { "Actions", "Data", "Players", "Info" }

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
	"UISystem.PendingGift",
	"UISystem.FriendsReward.JoinedFriends",
}

-- Client-only WalkSpeed presets, cycled by the Actions tab's speed button. 16
-- is Roblox's default, so the cycle always returns to a normal character.
local WALK_SPEEDS = { 16, 40, 90 }

type SnapshotEntry = {
	path: { string },
	kind: string,
	value: string,
}

type DataRow = {
	frame: Frame,
	valueBox: TextBox,
	path: { string },
	kind: string,
}

type ButtonSpec = {
	text: string,
	color: Color3?,
	onClick: () -> (),
}

local player = Players.LocalPlayer

--[[
	Populated by Init()'s listeners; read and written by the UI, which may not
	exist yet when a packet first arrives -- every UI touch below goes through a
	nil-guarded helper rather than assuming these are non-nil.
]]
local screenGui: ScreenGui? = nil
local root: Frame? = nil
local statusLabel: TextLabel? = nil
local targetButton: TextButton? = nil
local icon: any = nil

local tabButtons: { [string]: TextButton } = {}
local tabPages: { [string]: Frame } = {}
local activeTab = TAB_ORDER[1]

local dataScroll: ScrollingFrame? = nil
local dataCountLabel: TextLabel? = nil
local noiseToggleButton: TextButton? = nil
local newKeyPathBox: TextBox? = nil
local newKeyValueBox: TextBox? = nil

local playersScroll: ScrollingFrame? = nil
local playersHeaderLabel: TextLabel? = nil

local infoValueLabels: { [string]: TextLabel } = {}

local radiusDebugButton: TextButton? = nil
local spawnTierButton: TextButton? = nil
local walkSpeedButton: TextButton? = nil

local dataRows: { [string]: DataRow } = {}
local latestEntries: { SnapshotEntry } = {}
local entryByPath: { [string]: SnapshotEntry } = {}
local searchText = ""
local showNoise = false

local currentTarget: Player = player
local walkSpeedIndex = 1

local refreshThread: thread? = nil
local frameConnection: RBXScriptConnection? = nil
local connections: { RBXScriptConnection } = {}

local frameCount = 0
local fpsSampledAt = os.clock()
local framesPerSecond = 0

-- Window rect, in pixels, and the only piece of layout that is state. Both are
-- authoritative: applyWindowRect writes them onto Root, never the other way.
local windowPosition = Vector2.zero
local windowSize = MIN_WINDOW_SIZE

-- Drag/resize gesture. `dragTouch` is only set for touch input, where a second
-- finger would otherwise steer a drag the first one started.
local dragMode: "None" | "Move" | "Resize" = "None"
local dragOrigin = Vector2.zero
local dragStartPosition = Vector2.zero
local dragStartSize = Vector2.zero
local dragTouch: InputObject? = nil

-- Assigned below; rebuildPlayerRows' click handlers need it before it is
-- defined, and it in turn needs them.
local setTarget: (newTarget: Player) -> ()

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------

-- Decorative corner rounding is a fixed pixel radius, like every other
-- dimension in this file.
local function withCorner(instance: GuiObject, radius: number): GuiObject
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return instance
end

local function newLabel(text: string, size: UDim2, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = size
	label.Font = Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = text
	return label
end

local function newButton(text: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.Size = size
	button.BackgroundColor3 = FIELD_COLOR
	button.Font = Enum.Font.Gotham
	button.TextSize = BODY_TEXT_SIZE
	button.TextColor3 = TEXT_COLOR
	button.TextTruncate = Enum.TextTruncate.AtEnd
	button.Text = text
	withCorner(button, 5)
	return button
end

local function newTextBox(placeholder: string, size: UDim2): TextBox
	local box = Instance.new("TextBox")
	box.Size = size
	box.BackgroundColor3 = FIELD_COLOR
	box.Font = Enum.Font.Gotham
	box.TextSize = BODY_TEXT_SIZE
	box.TextColor3 = TEXT_COLOR
	box.PlaceholderText = placeholder
	box.ClearTextOnFocus = false
	box.Text = ""
	withCorner(box, 5)
	return box
end

local function newScrollList(parent: Instance, name: string, position: UDim2, size: UDim2): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.Position = position
	scroll.Size = size
	scroll.BackgroundColor3 = CHROME_COLOR
	scroll.BackgroundTransparency = 0.35
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = SCROLLBAR_THICKNESS
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = parent
	withCorner(scroll, 5)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = scroll

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, GAP - 2)
	layout.Parent = scroll

	return scroll
end

local function addSectionHeader(page: ScrollingFrame, order: number, text: string)
	local label =
		newLabel(text, UDim2.new(1, -SCROLL_ROW_INSET, 0, SECTION_HEADER_HEIGHT), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	label.Name = `Header{order}`
	label.LayoutOrder = order
	label.Font = Enum.Font.GothamBold
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.Parent = page
end

--[[
	One row of equally sized buttons. Each cell gives back its share of the
	inter-cell gaps, so N cells plus N-1 gaps add up to exactly the row width at
	any window size -- no hand-tuned offsets that only work at one width.
]]
local function addButtonRow(page: ScrollingFrame, order: number, specs: { ButtonSpec }): { TextButton }
	local row = Instance.new("Frame")
	row.Name = `Row{order}`
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -SCROLL_ROW_INSET, 0, ROW_HEIGHT)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, GAP)
	layout.Parent = row

	local count = #specs
	local created: { TextButton } = {}

	for index, spec in specs do
		local button = newButton(spec.text, UDim2.new(1 / count, -GAP * (count - 1) / count, 1, 0))
		button.LayoutOrder = index
		if spec.color ~= nil then
			button.BackgroundColor3 = spec.color
		end
		button.Parent = row
		button.Activated:Connect(spec.onClick)
		table.insert(created, button)
	end

	row.Parent = page
	return created
end

local function addInfoRow(page: ScrollingFrame, order: number, name: string)
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -SCROLL_ROW_INSET, 0, ROW_HEIGHT - 6)
	row.Parent = page

	local key = newLabel(name, UDim2.fromScale(0.44, 1), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	key.Name = "Key"
	key.Parent = row

	local value = newLabel("--", UDim2.fromScale(0.56, 1), SMALL_TEXT_SIZE, TEXT_COLOR)
	value.Name = "Value"
	value.Position = UDim2.fromScale(0.44, 0)
	value.Font = Enum.Font.RobotoMono
	value.Parent = row

	infoValueLabels[name] = value
end

----------------------------------------------------------------------
-- Window rect: drag, resize, clamp
----------------------------------------------------------------------

local function viewportSize(): Vector2
	local gui = screenGui
	if gui ~= nil and gui.AbsoluteSize.X > 0 and gui.AbsoluteSize.Y > 0 then
		return gui.AbsoluteSize
	end

	local camera = workspace.CurrentCamera
	if camera ~= nil then
		return camera.ViewportSize
	end

	return Vector2.new(1280, 720)
end

local function applyWindowRect()
	local frame = root
	if frame == nil then
		return
	end
	frame.Position = UDim2.fromOffset(math.round(windowPosition.X), math.round(windowPosition.Y))
	frame.Size = UDim2.fromOffset(math.round(windowSize.X), math.round(windowSize.Y))
end

--[[
	Fits the rect inside the current viewport, then writes it out. Called after
	every drag step, every resize step, and whenever the viewport itself changes
	(rotating a phone, resizing a window, an emulated device) -- which is what
	makes "the console is off-screen and I can't reach its title bar" unreachable
	rather than merely unlikely.

	MIN wins over the viewport on purpose: on a screen narrower than MIN_WINDOW_
	SIZE a clipped-but-usable console beats one squeezed until its controls
	overlap.
]]
local function clampWindow()
	local screen = viewportSize()

	windowSize = Vector2.new(
		math.clamp(windowSize.X, MIN_WINDOW_SIZE.X, math.max(MIN_WINDOW_SIZE.X, math.min(MAX_WINDOW_SIZE.X, screen.X))),
		math.clamp(windowSize.Y, MIN_WINDOW_SIZE.Y, math.max(MIN_WINDOW_SIZE.Y, math.min(MAX_WINDOW_SIZE.Y, screen.Y)))
	)

	windowPosition = Vector2.new(
		math.clamp(windowPosition.X, 0, math.max(0, screen.X - windowSize.X)),
		math.clamp(windowPosition.Y, 0, math.max(0, screen.Y - windowSize.Y))
	)

	applyWindowRect()
end

local function isPointerPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function isPointerMove(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local function beginDrag(mode: "Move" | "Resize", input: InputObject)
	dragMode = mode
	dragOrigin = Vector2.new(input.Position.X, input.Position.Y)
	dragStartPosition = windowPosition
	dragStartSize = windowSize
	dragTouch = if input.UserInputType == Enum.UserInputType.Touch then input else nil
end

--[[
	Both gestures are driven by the DELTA from where the pointer went down, never
	by an absolute pointer position. That is not a style choice: mouse positions
	from InputObject are reported in a space whose origin depends on the GUI
	inset, while this window's own origin ignores it (IgnoreGuiInset), and a
	constant offset between the two cancels out of a subtraction but not out of
	an assignment. Deltas also make a resize that hits a clamp resume smoothly
	instead of jumping once the pointer comes back.
]]
local function updateDrag(input: InputObject)
	if dragMode == "None" or not isPointerMove(input) then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch and dragTouch ~= nil and input ~= dragTouch then
		return
	end

	local delta = Vector2.new(input.Position.X, input.Position.Y) - dragOrigin
	if dragMode == "Move" then
		windowPosition = dragStartPosition + delta
	else
		windowSize = dragStartSize + delta
	end
	clampWindow()
end

local function endDrag(input: InputObject)
	if dragMode ~= "None" and isPointerPress(input) then
		dragMode = "None"
		dragTouch = nil
	end
end

----------------------------------------------------------------------
-- Status line, snapshots, open/close
----------------------------------------------------------------------

local function dottedPath(path: { string }): string
	return table.concat(path, ".")
end

local function setStatus(ok: boolean, message: string)
	local label = statusLabel
	if label == nil then
		return
	end
	label.Text = message
	label.TextColor3 = if ok then OK_COLOR else ERROR_COLOR
end

local function setHint(message: string)
	local label = statusLabel
	if label == nil then
		return
	end
	label.Text = message
	label.TextColor3 = MUTED_TEXT_COLOR
end

local function requestSnapshot()
	Net.devRequestSnapshot.send({ targetPlayer = currentTarget })
end

-- Numeric value of a snapshot leaf, or nil when the snapshot hasn't arrived yet
-- (or the field isn't a number). Used by the affordances that need to know the
-- current value client-side -- only the spawn-tier clamp, since every other
-- adjustment sends a delta and lets the server do the arithmetic.
local function snapshotNumber(path: string): number?
	local entry = entryByPath[path]
	if entry == nil then
		return nil
	end
	return tonumber(entry.value)
end

local function snapshotText(path: string): string
	local entry = entryByPath[path]
	return if entry ~= nil then entry.value else "--"
end

--[[
	How many entries an array field has in the latest snapshot. Counts distinct
	indices rather than leaves so it reads the same answer off a table array
	(Merge.Squishies.4.Tier) as off a scalar one (Cosmetics.Owned.SquishyBeams.4).
]]
local function countArrayEntries(prefix: string): number
	local prefixWithDot = `{prefix}.`
	local depth = #string.split(prefix, ".")
	local seen: { [string]: boolean } = {}
	local count = 0

	for _, entry in latestEntries do
		if string.sub(dottedPath(entry.path), 1, #prefixWithDot) ~= prefixWithDot then
			continue
		end
		local index = entry.path[depth + 1]
		if index ~= nil and not seen[index] then
			seen[index] = true
			count += 1
		end
	end

	return count
end

----------------------------------------------------------------------
-- Data tab
----------------------------------------------------------------------

local function isNoisyPath(dotted: string): boolean
	for _, prefix in NOISY_PATH_PREFIXES do
		if dotted == prefix or string.sub(dotted, 1, #prefix + 1) == `{prefix}.` then
			return true
		end
	end
	return false
end

local function commitRow(row: DataRow, box: TextBox)
	Net.devSet.send({
		targetPlayer = currentTarget,
		path = row.path,
		kind = row.kind,
		value = box.Text,
	})
end

local function createDataRow(entry: SnapshotEntry, layoutOrder: number, parent: ScrollingFrame): DataRow
	local frame = Instance.new("Frame")
	frame.Name = dottedPath(entry.path)
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, -SCROLL_ROW_INSET, 0, ROW_HEIGHT - 4)
	frame.LayoutOrder = layoutOrder

	local label = newLabel(dottedPath(entry.path), UDim2.fromScale(0.62, 1), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	label.Name = "PathLabel"
	-- Truncating the FRONT keeps the leaf key visible, which is the half of a
	-- long dotted path that tells you which field you are looking at.
	label.TextTruncate = Enum.TextTruncate.SplitWord
	label.Parent = frame

	local box = newTextBox("", UDim2.new(0.38, -GAP, 1, 0))
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
	Rebuilds from `latestEntries`, reusing existing row instances keyed by dotted
	path rather than destroying and recreating everything. That's what makes the
	"don't stomp a focused box" rule below possible: a full destroy/recreate would
	blow away the TextBox the developer is mid-edit in, which is exactly the
	poll-fights-the-typist bug this has to avoid.

	Filtering happens here rather than at the packet, so toggling a filter costs
	no round trip and the row you were editing survives one.
]]
local function rebuildDataRows()
	local body = dataScroll
	if body == nil then
		return
	end

	local seen: { [string]: boolean } = {}
	local shown = 0
	local order = 0

	for _, entry in latestEntries do
		local key = dottedPath(entry.path)

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
		countLabel.Text = `{shown}/{#latestEntries}`
	end
end

local function setShowNoise(enabled: boolean)
	showNoise = enabled

	local button = noiseToggleButton
	if button ~= nil then
		button.Text = `Noise: {if enabled then "shown" else "hidden"}`
		button.BackgroundColor3 = if enabled then ACCENT_COLOR else FIELD_COLOR
	end

	rebuildDataRows()
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
	local pathBox = newKeyPathBox
	local valueBox = newKeyValueBox
	if pathBox == nil or valueBox == nil then
		return
	end

	local pathText = pathBox.Text
	if pathText == "" then
		setStatus(false, "enter a dotted path first")
		return
	end

	Net.devSet.send({
		targetPlayer = currentTarget,
		path = string.split(pathText, "."),
		kind = inferKind(valueBox.Text),
		value = valueBox.Text,
	})
end

----------------------------------------------------------------------
-- Players tab
----------------------------------------------------------------------

--[[
	Rebuilt fresh on every open, every roster change and every target change -- a
	cached roster goes stale the moment anyone joins or leaves while the panel is
	up, which is precisely when a dev console gets used.
]]
local function rebuildPlayerRows()
	local list = playersScroll
	if list == nil then
		return
	end

	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local roster = Players:GetPlayers()

	local header = playersHeaderLabel
	if header ~= nil then
		header.Text = `{#roster} in server -- click a row to target them`
	end

	for index, candidate in roster do
		local isTarget = candidate == currentTarget

		local row = newButton("", UDim2.new(1, -SCROLL_ROW_INSET, 0, PLAYER_ROW_HEIGHT))
		row.Name = candidate.Name
		row.LayoutOrder = index
		row.BackgroundColor3 = if isTarget then ACCENT_COLOR else FIELD_COLOR
		row.Parent = list

		-- rbxthumb is resolved by the engine from the id alone, so this needs no
		-- yielding GetUserThumbnailAsync call and no request of our own.
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.AnchorPoint = Vector2.new(0, 0.5)
		avatar.Position = UDim2.new(0, 4, 0.5, 0)
		avatar.Size = UDim2.fromOffset(PLAYER_ROW_HEIGHT - 8, PLAYER_ROW_HEIGHT - 8)
		avatar.BackgroundColor3 = CHROME_COLOR
		avatar.BorderSizePixel = 0
		avatar.Image = `rbxthumb://type=AvatarHeadShot&id={candidate.UserId}&w=48&h=48`
		avatar.Parent = row
		withCorner(avatar, 4)

		local name = newLabel(
			candidate.Name,
			UDim2.new(1, -(PLAYER_ROW_HEIGHT + 90), 0, 15),
			BODY_TEXT_SIZE,
			if isTarget then BRIGHT_TEXT_COLOR else TEXT_COLOR
		)
		name.Name = "PlayerName"
		name.Position = UDim2.fromOffset(PLAYER_ROW_HEIGHT, 3)
		name.Font = Enum.Font.GothamBold
		name.Parent = row

		local detail = `UserId {candidate.UserId}`
		if candidate == player then
			detail = `{detail}  (you)`
		end

		local subtitle =
			newLabel(detail, UDim2.new(1, -(PLAYER_ROW_HEIGHT + 90), 0, 13), SMALL_TEXT_SIZE - 1, MUTED_TEXT_COLOR)
		subtitle.Name = "PlayerDetail"
		subtitle.Position = UDim2.fromOffset(PLAYER_ROW_HEIGHT, 17)
		subtitle.Parent = row

		if isTarget then
			local badge =
				newLabel("TARGET", UDim2.fromOffset(80, PLAYER_ROW_HEIGHT), SMALL_TEXT_SIZE - 1, BRIGHT_TEXT_COLOR)
			badge.Name = "TargetBadge"
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.fromScale(1, 0)
			badge.Font = Enum.Font.GothamBold
			badge.TextXAlignment = Enum.TextXAlignment.Right
			badge.Parent = row
		end

		row.Activated:Connect(function()
			setTarget(candidate)
		end)
	end
end

----------------------------------------------------------------------
-- Info tab
----------------------------------------------------------------------

local function setInfo(name: string, value: string)
	local label = infoValueLabels[name]
	if label ~= nil then
		label.Text = value
	end
end

local function updateInfo()
	if activeTab ~= "Info" then
		-- Nothing to see: skip the work rather than formatting strings nobody is
		-- looking at, every tick, for as long as the panel stays open.
		return
	end

	local now = os.clock()
	local elapsed = now - fpsSampledAt
	if elapsed >= 0.4 then
		framesPerSecond = frameCount / elapsed
		frameCount = 0
		fpsSampledAt = now
	end

	local screen = viewportSize()

	setInfo("FPS", `{math.round(framesPerSecond)}`)
	setInfo("Ping", `{math.round(player:GetNetworkPing() * 1000)} ms`)
	setInfo("Viewport", `{math.round(screen.X)} x {math.round(screen.Y)}`)
	setInfo("Window", `{math.round(windowSize.X)} x {math.round(windowSize.Y)}`)
	setInfo("Place / Job", `{game.PlaceId} / {if game.JobId == "" then "(studio)" else game.JobId}`)
	setInfo("Players", `{#Players:GetPlayers()}`)
	setInfo("Me", `{player.Name} ({player.UserId})`)
	setInfo("Target", `{currentTarget.Name} ({currentTarget.UserId})`)

	local assignedBase = currentTarget:GetAttribute("AssignedBase")
	local queuePosition = currentTarget:GetAttribute("BaseQueuePosition")
	setInfo(
		"Target base",
		if typeof(assignedBase) == "string"
			then assignedBase :: string
			elseif typeof(queuePosition) == "number" then `(queued #{queuePosition})`
			else "(none)"
	)

	setInfo("Coins", snapshotText("Coins"))
	setInfo("Level / XP", `{snapshotText("Level")} / {snapshotText("Experience")}`)
	setInfo("Spawn tier", snapshotText("Merge.SpawnLevel"))
	setInfo("Squishies", `{countArrayEntries("Merge.Squishies")} / {MergeConfig.MAX_OBJECTS}`)
	setInfo("Spins", snapshotText("UISystem.Spins"))
	setInfo("Keycap theme", snapshotText("Cosmetics.KeycapThemeId"))
	setInfo("Squishy beam", snapshotText("Cosmetics.SquishyBeamId"))
	setInfo("Merge pop", snapshotText("Cosmetics.MergePopId"))
	setInfo(
		"Cosmetics owned",
		`{countArrayEntries("Cosmetics.Owned.KeycapThemes")} keycaps, {countArrayEntries("Cosmetics.Owned.SquishyBeams")} beams, {countArrayEntries(
			"Cosmetics.Owned.MergePops"
		)} merge pops`
	)
	setInfo("Data version", snapshotText("Version"))
end

----------------------------------------------------------------------
-- Tabs and target
----------------------------------------------------------------------

local function selectTab(name: string)
	activeTab = name

	for tabName, page in tabPages do
		page.Visible = tabName == name
	end

	for tabName, button in tabButtons do
		local isActive = tabName == name
		button.BackgroundColor3 = if isActive then ACCENT_COLOR else FIELD_COLOR
		button.TextColor3 = if isActive then BRIGHT_TEXT_COLOR else MUTED_TEXT_COLOR
	end

	if name == "Players" then
		rebuildPlayerRows()
	elseif name == "Info" then
		updateInfo()
	end
end

local function refreshTargetButton()
	local button = targetButton
	if button == nil then
		return
	end

	local isSelf = currentTarget == player
	button.Text = `Target: {currentTarget.Name}`
	-- Amber when it isn't you: every server-side action on this panel writes to
	-- the TARGET's profile, and doing that to a real player by accident is the
	-- one mistake a god-mode console makes expensive.
	button.BackgroundColor3 = if isSelf then FIELD_COLOR else WARN_COLOR
	button.TextColor3 = if isSelf then TEXT_COLOR else BACKGROUND_COLOR
end

setTarget = function(newTarget: Player)
	currentTarget = newTarget
	refreshTargetButton()

	--[[
		Clear immediately rather than waiting for the fresh snapshot -- showing
		the OLD target's rows under the NEW target's label for even one frame is
		exactly the kind of mixup a god-mode console can't afford.
	]]
	for key, row in dataRows do
		row.frame:Destroy()
		dataRows[key] = nil
	end
	latestEntries = {}
	entryByPath = {}
	rebuildDataRows()
	rebuildPlayerRows()
	updateInfo()

	setHint(`targeting {newTarget.Name}`)
	requestSnapshot()
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------

local function sendAdd(path: { string }, amount: number)
	Net.devAdd.send({ targetPlayer = currentTarget, path = path, amount = amount })
end

local function onZeroCoinsClicked()
	Net.devSet.send({ targetPlayer = currentTarget, path = { "Coins" }, kind = "number", value = "0" })
end

local function refreshSpawnTierButton()
	local button = spawnTierButton
	if button == nil then
		return
	end

	local tier = snapshotNumber("Merge.SpawnLevel")
	if tier == nil then
		button.Text = "Spawn tier: --"
		return
	end

	local clamped = math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
	local tierDef = MergeConfig.Tiers[clamped]
	button.Text = `Tier {clamped}: {if tierDef ~= nil then tierDef.Name else "?"}`
end

--[[
	The one adjustment that has to know the current value client-side, because
	the range it clamps to (1..MAX_TIER) is a client-side fact and devAdd only
	bounds magnitude. A stale snapshot can overshoot by one; MergeService
	sanitizes SpawnLevel on read, and the next click corrects it.
]]
local function nudgeSpawnTier(delta: number)
	local tier = snapshotNumber("Merge.SpawnLevel")
	if tier == nil then
		setStatus(false, "no snapshot yet -- try again in a moment")
		return
	end

	local wanted = math.clamp(math.floor(tier) + delta, 1, MergeConfig.MAX_TIER)
	if wanted == tier then
		setStatus(false, if delta > 0 then `already at tier {MergeConfig.MAX_TIER}` else "already at tier 1")
		return
	end

	sendAdd({ "Merge", "SpawnLevel" }, wanted - tier)
end

local function onSpawnSquishiesClicked(count: number)
	Net.devSpawnSquishies.send({ targetPlayer = currentTarget, count = count })
end

local function onClearSquishiesClicked()
	Net.devClearSquishies.send({ targetPlayer = currentTarget })
end

local function onDamageSquishiesClicked()
	Net.devDamageSquishies.send({ targetPlayer = currentTarget })
end

local function onGrantAllCosmeticsClicked()
	Net.devGrantAllCosmetics.send({ targetPlayer = currentTarget })
end

local function updateRadiusDebugButton()
	local button = radiusDebugButton
	if button == nil then
		return
	end

	local enabled = player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
	button.Text = `Blast radius bounds: {if enabled then "ON" else "OFF"}  (R={MergeConfig.LAUNCH_IMPACT_RADIUS})`
	button.BackgroundColor3 = if enabled then GRANT_COLOR else FIELD_COLOR
end

local function onRadiusDebugClicked()
	local enabled = player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
	player:SetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE, not enabled)
	updateRadiusDebugButton()
end

--[[
	The three actions below are LOCAL and always act on this client's own
	character, never on the target. They work without a packet because a client
	already owns its own character: its CFrame and its Humanoid's properties
	replicate outward from here. Pointing them at another player would be a
	server action, and a different feature.
]]
local function localHumanoid(): Humanoid?
	local character = player.Character
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function onTeleportToTargetClicked()
	if currentTarget == player then
		setStatus(false, "you are the target -- pick someone else first")
		return
	end

	local character = player.Character
	local targetCharacter = currentTarget.Character
	if character == nil or targetCharacter == nil then
		setStatus(false, "one of you has no character right now")
		return
	end

	local pivot = targetCharacter.PrimaryPart
	if pivot == nil then
		setStatus(false, `{currentTarget.Name} has no root part yet`)
		return
	end

	-- Beside them, not inside them: a shared pivot spawns the two characters
	-- clipped together and physics resolves it by launching one.
	character:PivotTo(pivot.CFrame * CFrame.new(0, 0, 5))
	setStatus(true, `teleported to {currentTarget.Name}`)
end

local function onRespawnClicked()
	local humanoid = localHumanoid()
	if humanoid == nil then
		setStatus(false, "no character to respawn")
		return
	end
	humanoid.Health = 0
	setStatus(true, "killed your character -- respawning")
end

local function refreshWalkSpeedButton()
	local button = walkSpeedButton
	if button == nil then
		return
	end
	local speed = WALK_SPEEDS[walkSpeedIndex]
	button.Text = `My speed: {speed}`
	button.BackgroundColor3 = if walkSpeedIndex == 1 then FIELD_COLOR else GRANT_COLOR
end

local function onWalkSpeedClicked()
	walkSpeedIndex = walkSpeedIndex % #WALK_SPEEDS + 1
	refreshWalkSpeedButton()

	local humanoid = localHumanoid()
	if humanoid == nil then
		setStatus(false, "no character -- speed applies on your next spawn")
		return
	end

	humanoid.WalkSpeed = WALK_SPEEDS[walkSpeedIndex]
	setStatus(true, `walkspeed {WALK_SPEEDS[walkSpeedIndex]}`)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

local function stopRefreshLoop()
	if refreshThread ~= nil then
		task.cancel(refreshThread)
		refreshThread = nil
	end

	local connection = frameConnection
	if connection ~= nil then
		connection:Disconnect()
		frameConnection = nil
	end
end

-- Only while the panel is open, per spec -- cancelled on close and on destroy
-- so it can never outlive the UI it's refreshing.
local function startRefreshLoop()
	stopRefreshLoop()

	frameCount = 0
	fpsSampledAt = os.clock()
	frameConnection = RunService.RenderStepped:Connect(function()
		frameCount += 1
	end)

	refreshThread = task.spawn(function()
		local sinceSnapshot = 0
		while true do
			task.wait(TICK_INTERVAL)
			sinceSnapshot += TICK_INTERVAL
			updateInfo()
			if sinceSnapshot >= SNAPSHOT_INTERVAL then
				sinceSnapshot = 0
				requestSnapshot()
			end
		end
	end)
end

local function open()
	local gui = screenGui
	if gui == nil then
		return
	end

	gui.Enabled = true
	clampWindow()
	rebuildPlayerRows()
	refreshSpawnTierButton()
	updateRadiusDebugButton()
	requestSnapshot()
	startRefreshLoop()
end

local function close()
	local gui = screenGui
	if gui == nil then
		return
	end
	gui.Enabled = false
	stopRefreshLoop()
end

local function cleanup()
	stopRefreshLoop()
	dragMode = "None"
	dragTouch = nil

	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	table.clear(dataRows)
	table.clear(tabButtons)
	table.clear(tabPages)
	table.clear(infoValueLabels)

	--[[
		Cleared here as well as by setAccess: whichever path destroyed the GUI,
		screenGui must not be left pointing at a destroyed instance, or open() and
		close() would silently operate on it and setAccess(true) would never
		rebuild.
	]]
	screenGui = nil
	root = nil
	statusLabel = nil
	targetButton = nil
	dataScroll = nil
	dataCountLabel = nil
	noiseToggleButton = nil
	newKeyPathBox = nil
	newKeyValueBox = nil
	playersScroll = nil
	playersHeaderLabel = nil
	radiusDebugButton = nil
	spawnTierButton = nil
	walkSpeedButton = nil

	player:SetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE, nil)

	local topbarIcon = icon
	if topbarIcon ~= nil then
		topbarIcon:destroy()
		icon = nil
	end
end

----------------------------------------------------------------------
-- Build
----------------------------------------------------------------------

local function buildTitleBar(parent: Frame): TextButton
	--[[
		A TextButton, not a Frame: a Frame only receives MouseButton1 input once
		it is made Active, and a borderless button with AutoButtonColor off is the
		same thing without that trap. Its children (the two buttons below) sink
		their own clicks, so pressing them never starts a drag.
	]]
	local bar = Instance.new("TextButton")
	bar.Name = "TitleBar"
	bar.Size = UDim2.new(1, 0, 0, TITLE_BAR_HEIGHT)
	bar.BackgroundColor3 = CHROME_COLOR
	bar.BorderSizePixel = 0
	bar.AutoButtonColor = false
	bar.Text = ""
	bar.Parent = parent
	-- No corner of its own: Root's UICorner already masks its descendants, so a
	-- second radius here would only notch the bar's own bottom edge.

	local title = newLabel("Developer Console", UDim2.fromScale(0.4, 1), TITLE_TEXT_SIZE, TEXT_COLOR)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(PADDING, 0)
	title.Font = Enum.Font.GothamBold
	title.Parent = bar

	local closeButton = newButton("X", UDim2.fromOffset(TITLE_BAR_HEIGHT - 10, TITLE_BAR_HEIGHT - 10))
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0.5)
	closeButton.Position = UDim2.new(1, -5, 0.5, 0)
	closeButton.BackgroundColor3 = DANGER_COLOR
	closeButton.Parent = bar

	local target = newButton("Target: --", UDim2.fromOffset(150, TITLE_BAR_HEIGHT - 10))
	target.Name = "TargetButton"
	target.AnchorPoint = Vector2.new(1, 0.5)
	target.Position = UDim2.new(1, -(TITLE_BAR_HEIGHT + 2), 0.5, 0)
	target.TextSize = SMALL_TEXT_SIZE
	target.Parent = bar
	targetButton = target

	-- The picker IS the Players tab. One list, always live, no floating overlay
	-- to land behind another element or swallow its own clicks.
	target.Activated:Connect(function()
		selectTab("Players")
	end)

	closeButton.Activated:Connect(function()
		local topbarIcon = icon
		if topbarIcon ~= nil then
			topbarIcon:deselect()
		else
			close()
		end
	end)

	return bar
end

local function buildTabStrip(parent: Frame)
	local strip = Instance.new("Frame")
	strip.Name = "TabStrip"
	strip.Position = UDim2.fromOffset(PADDING, TITLE_BAR_HEIGHT + 2)
	strip.Size = UDim2.new(1, -2 * PADDING, 0, TAB_STRIP_HEIGHT - 4)
	strip.BackgroundTransparency = 1
	strip.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = strip

	local count = #TAB_ORDER
	for index, name in TAB_ORDER do
		local button = newButton(name, UDim2.new(1 / count, -4 * (count - 1) / count, 1, 0))
		button.Name = `{name}Tab`
		button.LayoutOrder = index
		button.TextSize = SMALL_TEXT_SIZE
		button.Parent = strip
		tabButtons[name] = button

		button.Activated:Connect(function()
			selectTab(name)
		end)
	end
end

local function newPage(parent: Frame, name: string): Frame
	local page = Instance.new("Frame")
	page.Name = `{name}Page`
	page.BackgroundTransparency = 1
	page.Size = UDim2.fromScale(1, 1)
	page.Visible = false
	page.Parent = parent
	tabPages[name] = page
	return page
end

local function buildActionsPage(parent: Frame)
	local page = newPage(parent, "Actions")
	local list = newScrollList(page, "ActionsList", UDim2.new(), UDim2.fromScale(1, 1))

	addSectionHeader(list, 1, "TARGET ECONOMY  (writes the target's profile)")
	addButtonRow(list, 2, {
		{
			text = "+1K coins",
			onClick = function()
				sendAdd({ "Coins" }, 1000)
			end,
		},
		{
			text = "+10K",
			onClick = function()
				sendAdd({ "Coins" }, 10000)
			end,
		},
		{
			text = "+100K",
			onClick = function()
				sendAdd({ "Coins" }, 100000)
			end,
		},
		{
			text = "+1M",
			onClick = function()
				sendAdd({ "Coins" }, 1000000)
			end,
		},
	})
	addButtonRow(list, 3, {
		{ text = "Coins -> 0", color = DANGER_COLOR, onClick = onZeroCoinsClicked },
		{
			text = "+1 level",
			onClick = function()
				sendAdd({ "Level" }, 1)
			end,
		},
		{
			text = "+1K XP",
			onClick = function()
				sendAdd({ "Experience" }, 1000)
			end,
		},
		{
			text = "+5 spins",
			onClick = function()
				sendAdd({ "UISystem", "Spins" }, 5)
			end,
		},
	})

	addSectionHeader(list, 4, "TARGET SQUISHIES")
	addButtonRow(list, 5, {
		{
			text = "Spawn 1",
			onClick = function()
				onSpawnSquishiesClicked(1)
			end,
		},
		{
			text = "Spawn 5",
			onClick = function()
				onSpawnSquishiesClicked(5)
			end,
		},
		{
			text = "Fill pad",
			onClick = function()
				onSpawnSquishiesClicked(MergeConfig.MAX_OBJECTS)
			end,
		},
		{ text = "Clear all", color = DANGER_COLOR, onClick = onClearSquishiesClicked },
	})
	local tierRow = addButtonRow(list, 6, {
		{
			text = "- tier",
			onClick = function()
				nudgeSpawnTier(-1)
			end,
		},
		{ text = "Spawn tier: --", onClick = refreshSpawnTierButton },
		{
			text = "+ tier",
			onClick = function()
				nudgeSpawnTier(1)
			end,
		},
	})
	spawnTierButton = tierRow[2]
	refreshSpawnTierButton()

	addButtonRow(list, 7, {
		{ text = "Damage all squishies  -25% max HP", color = DANGER_COLOR, onClick = onDamageSquishiesClicked },
	})

	addSectionHeader(list, 8, "TARGET COSMETICS")
	addButtonRow(list, 9, {
		{ text = "Grant all cosmetics", color = ACCENT_COLOR, onClick = onGrantAllCosmeticsClicked },
	})

	addSectionHeader(list, 10, "LOCAL DEBUG  (affects YOU, never the target)")
	local radiusRow = addButtonRow(list, 11, {
		{ text = "Blast radius bounds: OFF", onClick = onRadiusDebugClicked },
	})
	radiusDebugButton = radiusRow[1]
	updateRadiusDebugButton()

	local localRow = addButtonRow(list, 12, {
		{ text = "Teleport to target", onClick = onTeleportToTargetClicked },
		{ text = "Respawn me", onClick = onRespawnClicked },
		{ text = "My speed: 16", onClick = onWalkSpeedClicked },
	})
	walkSpeedButton = localRow[3]
	refreshWalkSpeedButton()
end

local function buildDataPage(parent: Frame)
	local page = newPage(parent, "Data")

	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	toolbar.BackgroundTransparency = 1
	toolbar.Parent = page

	local search = newTextBox("filter by path, e.g. coins", UDim2.new(0.52, -GAP, 1, 0))
	search.Name = "SearchBox"
	search.Parent = toolbar

	local noiseToggle = newButton("Noise: hidden", UDim2.new(0.32, -GAP, 1, 0))
	noiseToggle.Name = "NoiseToggle"
	noiseToggle.Position = UDim2.fromScale(0.52, 0)
	noiseToggle.TextSize = SMALL_TEXT_SIZE
	noiseToggle.Parent = toolbar
	noiseToggleButton = noiseToggle

	local count = newLabel("0/0", UDim2.fromScale(0.16, 1), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	count.Name = "CountLabel"
	count.Position = UDim2.fromScale(0.84, 0)
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Parent = toolbar
	dataCountLabel = count

	-- The scroll list owns the middle: toolbar above, new-key row below, both
	-- fixed height, so it takes whatever the window's current height leaves.
	local list = newScrollList(
		page,
		"DataList",
		UDim2.fromOffset(0, ROW_HEIGHT + GAP),
		UDim2.new(1, 0, 1, -(2 * ROW_HEIGHT + 2 * GAP))
	)
	dataScroll = list

	local newKeyRow = Instance.new("Frame")
	newKeyRow.Name = "NewKeyRow"
	newKeyRow.AnchorPoint = Vector2.new(0, 1)
	newKeyRow.Position = UDim2.fromScale(0, 1)
	newKeyRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	newKeyRow.BackgroundTransparency = 1
	newKeyRow.Parent = page

	local pathBox = newTextBox("Inventory.Sword", UDim2.new(0.44, -GAP, 1, 0))
	pathBox.Name = "PathBox"
	pathBox.Parent = newKeyRow
	newKeyPathBox = pathBox

	local valueBox = newTextBox("1", UDim2.new(0.34, -GAP, 1, 0))
	valueBox.Name = "ValueBox"
	valueBox.Position = UDim2.fromScale(0.44, 0)
	valueBox.Parent = newKeyRow
	newKeyValueBox = valueBox

	local setButton = newButton("Set", UDim2.fromScale(0.22, 1))
	setButton.Name = "SetButton"
	setButton.Position = UDim2.fromScale(0.78, 0)
	setButton.BackgroundColor3 = ACCENT_COLOR
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
			rebuildDataRows()
		end)
	)
end

local function buildPlayersPage(parent: Frame)
	local page = newPage(parent, "Players")

	local header = newLabel("--", UDim2.new(1, 0, 0, SECTION_HEADER_HEIGHT), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	header.Name = "PlayersHeader"
	header.Font = Enum.Font.GothamBold
	header.Parent = page
	playersHeaderLabel = header

	playersScroll = newScrollList(
		page,
		"PlayersList",
		UDim2.fromOffset(0, SECTION_HEADER_HEIGHT + 4),
		UDim2.new(1, 0, 1, -(SECTION_HEADER_HEIGHT + 4))
	)
end

local function buildInfoPage(parent: Frame)
	local page = newPage(parent, "Info")
	local list = newScrollList(page, "InfoList", UDim2.new(), UDim2.fromScale(1, 1))

	local order = 0
	local function section(title: string)
		order += 1
		addSectionHeader(list, order, title)
	end
	local function field(name: string)
		order += 1
		addInfoRow(list, order, name)
	end

	section("CLIENT")
	field("FPS")
	field("Ping")
	field("Viewport")
	field("Window")

	section("SESSION")
	field("Place / Job")
	field("Players")
	field("Me")

	section("TARGET")
	field("Target")
	field("Target base")
	field("Coins")
	field("Level / XP")
	field("Spawn tier")
	field("Squishies")
	field("Spins")
	field("Keycap theme")
	field("Squishy beam")
	field("Merge pop")
	field("Cosmetics owned")
	field("Data version")
end

local function buildStatusBar(parent: Frame)
	local status =
		newLabel("", UDim2.new(1, -(2 * PADDING + GRIP_SIZE), 0, STATUS_BAR_HEIGHT), SMALL_TEXT_SIZE, MUTED_TEXT_COLOR)
	status.Name = "StatusLabel"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, PADDING, 1, -3)
	status.Parent = parent
	statusLabel = status
end

local function buildResizeGrip(parent: Frame): TextButton
	local grip = Instance.new("TextButton")
	grip.Name = "ResizeGrip"
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Position = UDim2.new(1, -2, 1, -2)
	grip.Size = UDim2.fromOffset(GRIP_SIZE, GRIP_SIZE)
	grip.BackgroundColor3 = FIELD_COLOR
	grip.BorderSizePixel = 0
	grip.AutoButtonColor = false
	grip.Font = Enum.Font.GothamBold
	grip.TextSize = SMALL_TEXT_SIZE
	grip.TextColor3 = MUTED_TEXT_COLOR
	-- Two nested corners read as a grip at this size; a diagonal-lines image
	-- would need an asset for something a glyph already says.
	grip.Text = "//"
	grip.Parent = parent
	withCorner(grip, 4)
	return grip
end

--[[
	Everything below is built once, only for developers (see setAccess). Nothing
	here yields, so it's fine to run at the end of Start after the rank check
	already has.
]]
local function buildUI()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "DevConsole"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Enabled = false
	screenGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.BackgroundColor3 = BACKGROUND_COLOR
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = gui
	withCorner(frame, 8)
	root = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = BORDER_COLOR
	stroke.Thickness = 1
	stroke.Parent = frame

	local titleBar = buildTitleBar(frame)
	buildTabStrip(frame)

	local pageArea = Instance.new("Frame")
	pageArea.Name = "PageArea"
	pageArea.Position = UDim2.fromOffset(PADDING, TITLE_BAR_HEIGHT + TAB_STRIP_HEIGHT + 2)
	pageArea.Size =
		UDim2.new(1, -2 * PADDING, 1, -(TITLE_BAR_HEIGHT + TAB_STRIP_HEIGHT + STATUS_BAR_HEIGHT + PADDING + 4))
	pageArea.BackgroundTransparency = 1
	pageArea.Parent = frame

	buildActionsPage(pageArea)
	buildDataPage(pageArea)
	buildPlayersPage(pageArea)
	buildInfoPage(pageArea)

	buildStatusBar(frame)
	local grip = buildResizeGrip(frame)

	-- Opening rect: a fraction of the viewport (so it is proportionate on any
	-- screen) rather than an authored pixel size, centred, then clamped.
	local screen = viewportSize()
	windowSize =
		Vector2.new(math.round(screen.X * INITIAL_WINDOW_FRACTION.X), math.round(screen.Y * INITIAL_WINDOW_FRACTION.Y))
	windowPosition = Vector2.new(math.round((screen.X - windowSize.X) / 2), math.round((screen.Y - windowSize.Y) / 2))
	clampWindow()

	titleBar.InputBegan:Connect(function(input: InputObject)
		if isPointerPress(input) then
			beginDrag("Move", input)
		end
	end)

	grip.InputBegan:Connect(function(input: InputObject)
		if isPointerPress(input) then
			beginDrag("Resize", input)
		end
	end)

	--[[
		The move/end half listens on UserInputService, not on the handles: a
		pointer dragged quickly leaves the 30px title bar long before the drag
		is over, and a handle-local InputChanged would simply stop firing --
		the window would stick to the cursor's last position over the bar and
		never learn the button was released.
	]]
	table.insert(connections, UserInputService.InputChanged:Connect(updateDrag))
	table.insert(connections, UserInputService.InputEnded:Connect(endDrag))

	local sizeChanged = gui:GetPropertyChangedSignal("AbsoluteSize")
	table.insert(connections, sizeChanged:Connect(clampWindow))

	table.insert(
		connections,
		Players.PlayerAdded:Connect(function()
			rebuildPlayerRows()
			updateInfo()
		end)
	)

	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(leaving: Player)
			if leaving == player then
				return
			end
			if leaving == currentTarget then
				-- Every packet this panel sends would be rejected from here on
				-- ("target is not in this server"), so fall back to ourselves rather
				-- than leaving a target that can only fail.
				setTarget(player)
				setStatus(false, `{leaving.Name} left -- target reset to you`)
				return
			end
			rebuildPlayerRows()
			updateInfo()
		end)
	)

	refreshTargetButton()
	selectTab("Actions")
	setHint("drag the title bar to move, the corner to resize")

	gui.Destroying:Connect(cleanup)
	gui.Parent = playerGui

	local topbarIcon = Icon.new()
	topbarIcon:setLabel("Dev")
	topbarIcon:setCaption("Developer Console")
	topbarIcon:align("Right")
	topbarIcon:bindToggleKey(Enum.KeyCode.F4)
	topbarIcon:bindEvent("selected", open)
	topbarIcon:bindEvent("deselected", close)
	icon = topbarIcon
end

--[[
	The server told us whether we're a developer. We never work this out
	ourselves any more: the list lives in a ConfigService config, and
	ConfigService is server-only -- calling it from a client script errors.

	Idempotent on purpose. The server re-sends this to everyone on every config
	change, so the common case is being told the same answer we already have.
]]
local function setAccess(allowed: boolean)
	if allowed then
		if screenGui == nil then
			buildUI()
			log.info("ready")
		end
		return
	end

	--[[
		Revoked mid-session -- removed from the list, config republished. Tear the
		console down rather than leave a UI whose every command the server now
		rejects. Purely cosmetic, like the rest of this check: authority is the
		server's and DevService re-checks it per packet.
	]]
	local gui = screenGui
	if gui ~= nil then
		screenGui = nil
		gui:Destroy()
	end
	cleanup()
end

local DevConsoleController = {}

function DevConsoleController.Init()
	--[[
		Registered in Init, not Start. The server sends devAccess as soon as it
		sees us join, and a listener that does not exist yet misses it
		permanently and silently -- the same trap DataController.luau documents
		for Replica.OnNew, and the reason Init and Start are separate phases.
	]]
	Net.devAccess.listen(function(data)
		setAccess(data.allowed)
	end)

	Net.devResult.listen(function(data)
		setStatus(data.ok, data.message)
		if data.ok then
			requestSnapshot()
		end
	end)

	Net.devSnapshot.listen(function(data)
		if data.targetPlayer ~= currentTarget then
			-- Late reply for a target we've since switched away from -- a repaint
			-- here would show the wrong player's data under the CURRENT target's
			-- label.
			return
		end

		latestEntries = data.entries

		entryByPath = {}
		for _, entry in latestEntries do
			entryByPath[dottedPath(entry.path)] = entry
		end

		rebuildDataRows()
		refreshSpawnTierButton()
		updateInfo()
	end)
end

--[[
	Ask the server whether we're a developer. The console is then built by
	setAccess() when devAccess comes back.

	Asking here rather than waiting to be told is deliberate. The server also
	pushes devAccess when it sees us join, but that push races us: a RemoteEvent
	fired at a client whose listener does not exist yet is dropped, not queued,
	so a fresh joiner could silently never get a console. By Start(), Init() has
	registered the listener, so the reply cannot be lost.
]]
function DevConsoleController.Start()
	Net.devRequestAccess.send()
end

return DevConsoleController
