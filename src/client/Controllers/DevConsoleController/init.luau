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

	This module is split under DevConsoleController/: Style (colors/sizes),
	Widgets (stateless factories), Window (the drag/resize rect), Snapshot (the
	latest devSnapshot + read accessors), and one file per tab (ActionsTab,
	DataTab, PlayersTab, InfoTab). This file stays the thin orchestrator: it
	owns the chrome (title bar, tab strip, status bar, resize grip), the tab
	switch and the current target, and wires the tabs together via each one's
	`setup(deps)`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Icon = require(ReplicatedStorage.Packages.TopbarPlus)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local ActionsTab = require(script.ActionsTab)
local DataTab = require(script.DataTab)
local InfoTab = require(script.InfoTab)
local PlayersTab = require(script.PlayersTab)
local Snapshot = require(script.Snapshot)
local Style = require(script.Style)
local Widgets = require(script.Widgets)
local Window = require(script.Window)

local log = Log.new("DevConsoleController")

-- The panel ticks while it is open (only): the Info tab's readouts refresh on
-- every tick, a fresh profile snapshot is requested every SNAPSHOT_INTERVAL.
local TICK_INTERVAL = 0.5
local SNAPSHOT_INTERVAL = 2

local TAB_ORDER = { "Actions", "Data", "Players", "Info" }

local player = Players.LocalPlayer

--[[
	Populated by Init()'s listeners; read and written by the UI, which may not
	exist yet when a packet first arrives -- every UI touch below goes through a
	nil-guarded helper rather than assuming these are non-nil.
]]
local screenGui: ScreenGui? = nil
local statusLabel: TextLabel? = nil
local targetButton: TextButton? = nil
local icon: any = nil

local tabButtons: { [string]: TextButton } = {}
local tabPages: { [string]: Frame } = {}
local activeTab = TAB_ORDER[1]

local currentTarget: Player = player

local refreshThread: thread? = nil
local connections: { RBXScriptConnection } = {}

local function getTarget(): Player
	return currentTarget
end

local function getActiveTab(): string
	return activeTab
end

-- Handed to every tab's setup() so a tab's build() can create its page without
-- any tab owning the tabPages table itself.
local function registerPage(name: string, page: Frame)
	tabPages[name] = page
end

----------------------------------------------------------------------
-- Status line, open/close
----------------------------------------------------------------------

local function setStatus(ok: boolean, message: string)
	local label = statusLabel
	if label == nil then
		return
	end
	label.Text = message
	label.TextColor3 = if ok then Style.OK_COLOR else Style.ERROR_COLOR
end

local function setHint(message: string)
	local label = statusLabel
	if label == nil then
		return
	end
	label.Text = message
	label.TextColor3 = Style.MUTED_TEXT_COLOR
end

local function requestSnapshot()
	Net.devRequestSnapshot.send({ targetPlayer = currentTarget })
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
		button.BackgroundColor3 = if isActive then Style.ACCENT_COLOR else Style.FIELD_COLOR
		button.TextColor3 = if isActive then Style.BRIGHT_TEXT_COLOR else Style.MUTED_TEXT_COLOR
	end

	if name == "Players" then
		PlayersTab.rebuildPlayerRows()
	elseif name == "Info" then
		InfoTab.updateInfo()
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
	button.BackgroundColor3 = if isSelf then Style.FIELD_COLOR else Style.WARN_COLOR
	button.TextColor3 = if isSelf then Style.TEXT_COLOR else Style.BACKGROUND_COLOR
end

local function setTarget(newTarget: Player)
	currentTarget = newTarget
	refreshTargetButton()

	--[[
		Clear immediately rather than waiting for the fresh snapshot -- showing
		the OLD target's rows under the NEW target's label for even one frame is
		exactly the kind of mixup a god-mode console can't afford.
	]]
	DataTab.clearRows()
	Snapshot.clear()
	DataTab.rebuildDataRows()
	PlayersTab.rebuildPlayerRows()
	InfoTab.updateInfo()

	setHint(`targeting {newTarget.Name}`)
	requestSnapshot()
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

local function stopRefreshLoop()
	if refreshThread ~= nil then
		task.cancel(refreshThread)
		refreshThread = nil
	end
	InfoTab.stopSampling()
end

-- Only while the panel is open, per spec -- cancelled on close and on destroy
-- so it can never outlive the UI it's refreshing.
local function startRefreshLoop()
	stopRefreshLoop()

	InfoTab.startSampling()

	refreshThread = task.spawn(function()
		local sinceSnapshot = 0
		while true do
			task.wait(TICK_INTERVAL)
			sinceSnapshot += TICK_INTERVAL
			InfoTab.updateInfo()
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
	Window.clampWindow()
	PlayersTab.rebuildPlayerRows()
	ActionsTab.refreshSpawnTierButton()
	ActionsTab.updateRadiusDebugButton()
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
	Window.reset()

	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	table.clear(tabButtons)
	table.clear(tabPages)

	DataTab.cleanup()
	PlayersTab.cleanup()
	InfoTab.cleanup()
	ActionsTab.cleanup()

	--[[
		Cleared here as well as by setAccess: whichever path destroyed the GUI,
		screenGui must not be left pointing at a destroyed instance, or open() and
		close() would silently operate on it and setAccess(true) would never
		rebuild.
	]]
	screenGui = nil
	statusLabel = nil
	targetButton = nil

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
	bar.Size = UDim2.new(1, 0, 0, Style.TITLE_BAR_HEIGHT)
	bar.BackgroundColor3 = Style.CHROME_COLOR
	bar.BorderSizePixel = 0
	bar.AutoButtonColor = false
	bar.Text = ""
	bar.Parent = parent
	-- No corner of its own: Root's UICorner already masks its descendants, so a
	-- second radius here would only notch the bar's own bottom edge.

	local title =
		Widgets.newLabel("Developer Console", UDim2.fromScale(0.4, 1), Style.TITLE_TEXT_SIZE, Style.TEXT_COLOR)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(Style.PADDING, 0)
	title.Font = Enum.Font.GothamBold
	title.Parent = bar

	local closeButton =
		Widgets.newButton("X", UDim2.fromOffset(Style.TITLE_BAR_HEIGHT - 10, Style.TITLE_BAR_HEIGHT - 10))
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0.5)
	closeButton.Position = UDim2.new(1, -5, 0.5, 0)
	closeButton.BackgroundColor3 = Style.DANGER_COLOR
	closeButton.Parent = bar

	local target = Widgets.newButton("Target: --", UDim2.fromOffset(150, Style.TITLE_BAR_HEIGHT - 10))
	target.Name = "TargetButton"
	target.AnchorPoint = Vector2.new(1, 0.5)
	target.Position = UDim2.new(1, -(Style.TITLE_BAR_HEIGHT + 2), 0.5, 0)
	target.TextSize = Style.SMALL_TEXT_SIZE
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
	strip.Position = UDim2.fromOffset(Style.PADDING, Style.TITLE_BAR_HEIGHT + 2)
	strip.Size = UDim2.new(1, -2 * Style.PADDING, 0, Style.TAB_STRIP_HEIGHT - 4)
	strip.BackgroundTransparency = 1
	strip.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = strip

	local count = #TAB_ORDER
	for index, name in TAB_ORDER do
		local button = Widgets.newButton(name, UDim2.new(1 / count, -4 * (count - 1) / count, 1, 0))
		button.Name = `{name}Tab`
		button.LayoutOrder = index
		button.TextSize = Style.SMALL_TEXT_SIZE
		button.Parent = strip
		tabButtons[name] = button

		button.Activated:Connect(function()
			selectTab(name)
		end)
	end
end

local function buildStatusBar(parent: Frame)
	local status = Widgets.newLabel(
		"",
		UDim2.new(1, -(2 * Style.PADDING + Style.GRIP_SIZE), 0, Style.STATUS_BAR_HEIGHT),
		Style.SMALL_TEXT_SIZE,
		Style.MUTED_TEXT_COLOR
	)
	status.Name = "StatusLabel"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, Style.PADDING, 1, -3)
	status.Parent = parent
	statusLabel = status
end

local function buildResizeGrip(parent: Frame): TextButton
	local grip = Instance.new("TextButton")
	grip.Name = "ResizeGrip"
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Position = UDim2.new(1, -2, 1, -2)
	grip.Size = UDim2.fromOffset(Style.GRIP_SIZE, Style.GRIP_SIZE)
	grip.BackgroundColor3 = Style.FIELD_COLOR
	grip.BorderSizePixel = 0
	grip.AutoButtonColor = false
	grip.Font = Enum.Font.GothamBold
	grip.TextSize = Style.SMALL_TEXT_SIZE
	grip.TextColor3 = Style.MUTED_TEXT_COLOR
	-- Two nested corners read as a grip at this size; a diagonal-lines image
	-- would need an asset for something a glyph already says.
	grip.Text = "//"
	grip.Parent = parent
	Widgets.withCorner(grip, 4)
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
	frame.BackgroundColor3 = Style.BACKGROUND_COLOR
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = gui
	Widgets.withCorner(frame, 8)

	Window.setFrames(gui, frame)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Style.BORDER_COLOR
	stroke.Thickness = 1
	stroke.Parent = frame

	local titleBar = buildTitleBar(frame)
	buildTabStrip(frame)

	local pageArea = Instance.new("Frame")
	pageArea.Name = "PageArea"
	pageArea.Position = UDim2.fromOffset(Style.PADDING, Style.TITLE_BAR_HEIGHT + Style.TAB_STRIP_HEIGHT + 2)
	pageArea.Size = UDim2.new(
		1,
		-2 * Style.PADDING,
		1,
		-(Style.TITLE_BAR_HEIGHT + Style.TAB_STRIP_HEIGHT + Style.STATUS_BAR_HEIGHT + Style.PADDING + 4)
	)
	pageArea.BackgroundTransparency = 1
	pageArea.Parent = frame

	ActionsTab.build(pageArea)
	DataTab.build(pageArea)
	PlayersTab.build(pageArea)
	InfoTab.build(pageArea)

	buildStatusBar(frame)
	local grip = buildResizeGrip(frame)

	-- Opening rect: a fraction of the viewport (so it is proportionate on any
	-- screen) rather than an authored pixel size, centred, then clamped.
	Window.initializeRect()

	titleBar.InputBegan:Connect(function(input: InputObject)
		if Window.isPointerPress(input) then
			Window.beginDrag("Move", input)
		end
	end)

	grip.InputBegan:Connect(function(input: InputObject)
		if Window.isPointerPress(input) then
			Window.beginDrag("Resize", input)
		end
	end)

	--[[
		The move/end half listens on UserInputService, not on the handles: a
		pointer dragged quickly leaves the 30px title bar long before the drag
		is over, and a handle-local InputChanged would simply stop firing --
		the window would stick to the cursor's last position over the bar and
		never learn the button was released.
	]]
	table.insert(connections, UserInputService.InputChanged:Connect(Window.updateDrag))
	table.insert(connections, UserInputService.InputEnded:Connect(Window.endDrag))

	local sizeChanged = gui:GetPropertyChangedSignal("AbsoluteSize")
	table.insert(connections, sizeChanged:Connect(Window.clampWindow))

	table.insert(
		connections,
		Players.PlayerAdded:Connect(function()
			PlayersTab.rebuildPlayerRows()
			InfoTab.updateInfo()
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
			PlayersTab.rebuildPlayerRows()
			InfoTab.updateInfo()
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
	DataTab.setup({
		getTarget = getTarget,
		setStatus = setStatus,
		registerPage = registerPage,
	})
	ActionsTab.setup({
		getTarget = getTarget,
		setStatus = setStatus,
		registerPage = registerPage,
	})
	PlayersTab.setup({
		getTarget = getTarget,
		setTarget = setTarget,
		registerPage = registerPage,
	})
	InfoTab.setup({
		getTarget = getTarget,
		getActiveTab = getActiveTab,
		registerPage = registerPage,
	})

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

		Snapshot.setEntries(data.entries)

		DataTab.rebuildDataRows()
		ActionsTab.refreshSpawnTierButton()
		InfoTab.updateInfo()
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
