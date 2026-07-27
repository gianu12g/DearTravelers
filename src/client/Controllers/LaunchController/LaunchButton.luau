--!strict
--[[
	Owns the DropLaunchUI HUD: resolving the C.Launch button, its cooldown
	visuals, and the PlayerGui/Screens re-clone watching that keeps both this
	button and Targeting's UI wired up across a full PlayerGui respawn.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local Targeting = require(script.Parent.Targeting)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10
local LAUNCH_COOLDOWN_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 95, 95)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 25, 25)),
})

local LaunchButton = {}

local dropLaunchUi: ScreenGui? = nil
local launchButton: TextButton? = nil
local launchButtonLabel: TextLabel? = nil
local launchButtonGradient: UIGradient? = nil
local launchButtonIcon: ImageLabel? = nil
local readyLaunchText = "LAUNCH"
local readyLaunchGradient: ColorSequence? = nil
local readyLaunchIconTransparency = 0
local connectedButton: TextButton? = nil
local activatedConnection: RBXScriptConnection? = nil
local connectedScreensFolder: Instance? = nil
local screensChildAddedConnection: RBXScriptConnection? = nil

local function launchCooldownRemaining(): number
	local readyAt = player:GetAttribute("CarryingLaunchReadyAt")
	if typeof(readyAt) ~= "number" then
		return 0
	end
	return math.max(0, readyAt - Workspace:GetServerTimeNow())
end

local function bindLaunchCooldownVisual(button: TextButton)
	-- Remove the first-pass overlay if this controller is hot-reloaded in an
	-- existing client. Cooldown now reuses the authored button art instead.
	local oldOverlay = button:FindFirstChild("LaunchCooldownOverlay")
	if oldOverlay ~= nil then
		oldOverlay:Destroy()
	end

	local label = button:FindFirstChild("TextLabel")
	local gradient = button:FindFirstChildOfClass("UIGradient")
	local icon = button:FindFirstChild("Icon")
	if label == nil or not label:IsA("TextLabel") then
		log.warn(`{button:GetFullName()} has no authored TextLabel -- cooldown copy unavailable`)
		launchButtonLabel = nil
		return
	end

	launchButtonLabel = label
	readyLaunchText = label.Text
	launchButtonGradient = if gradient ~= nil and gradient:IsA("UIGradient") then gradient else nil
	readyLaunchGradient = if gradient ~= nil and gradient:IsA("UIGradient") then gradient.Color else nil
	launchButtonIcon = if icon ~= nil and icon:IsA("ImageLabel") then icon else nil
	readyLaunchIconTransparency = if icon ~= nil and icon:IsA("ImageLabel") then icon.ImageTransparency else 0
end

function LaunchButton.updateLaunchCooldownDisplay()
	local button = launchButton
	local label = launchButtonLabel
	if button == nil or button.Parent == nil or label == nil or label.Parent == nil then
		return
	end

	local remaining = launchCooldownRemaining()
	local coolingDown = player:GetAttribute("CarryingTier") ~= nil and remaining > 0
	button.Active = not coolingDown
	button.Selectable = not coolingDown
	label.Text = if coolingDown then Format.FormatCountdown(remaining) else readyLaunchText

	local gradient = launchButtonGradient
	local readyGradient = readyLaunchGradient
	if gradient ~= nil and gradient.Parent ~= nil and readyGradient ~= nil then
		gradient.Color = if coolingDown then LAUNCH_COOLDOWN_GRADIENT else readyGradient
	end
	local icon = launchButtonIcon
	if icon ~= nil and icon.Parent ~= nil then
		icon.ImageTransparency = if coolingDown
			then math.max(readyLaunchIconTransparency, 0.62)
			else readyLaunchIconTransparency
	end
end

local function beginTargeting()
	if Targeting.isTargeting() or player:GetAttribute("CarryingTier") == nil then
		return
	end
	if launchCooldownRemaining() > 0 then
		LaunchButton.updateLaunchCooldownDisplay()
		return
	end

	local ui = dropLaunchUi
	if ui == nil or ui.Parent == nil then
		log.warn("DropLaunchUI is unavailable -- launch targeting skipped")
		return
	end

	local overlayGui = Targeting.resolveTargetingUi()
	if overlayGui == nil then
		return
	end
	local markerGui, iconHolder, icon, debugBox = Targeting.resolveTargetMarkerUi()
	if markerGui == nil or iconHolder == nil or icon == nil or debugBox == nil then
		return
	end
	overlayGui.Enabled = false
	markerGui.Enabled = false
	iconHolder.Visible = false
	debugBox.Visible = false
	-- Any legacy opaque backdrop remains retired; the ownership images and
	-- names now render through the bases' BillboardGuis in the real 3D map.
	local overlayBackground = overlayGui:FindFirstChild("BG")
	if overlayBackground ~= nil and overlayBackground:IsA("Frame") then
		overlayBackground.Visible = false
	end

	Targeting.beginTargetingSession(overlayGui, markerGui, iconHolder, icon, debugBox)
	markerGui.Enabled = true
	overlayGui.Enabled = true

	-- Deferred one frame: this runs inside the launch button's own Activated
	-- handler, and disabling its ScreenGui synchronously can strand
	-- Buttons.luau's hover/press state machine (see src/client/UI/Buttons.luau
	-- MouseEnter/MouseButton1Down handling -- MouseLeave never fires once the
	-- gui is gone). Re-check targeting and ui.Parent after the defer -- a
	-- same-frame cancel must not hide the HUD permanently.
	task.defer(function()
		if not Targeting.isTargeting() or ui.Parent == nil then
			return
		end
		ui.Enabled = false
	end)
end

LaunchButton.beginTargeting = beginTargeting

local function resolveUi(): TextButton?
	local cachedUi = dropLaunchUi
	local cachedButton = launchButton
	if cachedUi ~= nil and cachedUi.Parent ~= nil and cachedButton ~= nil and cachedButton.Parent ~= nil then
		if launchButtonLabel == nil or launchButtonLabel.Parent == nil then
			bindLaunchCooldownVisual(cachedButton)
		end
		return cachedButton
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local screensInstance = playerGui:WaitForChild("Screens", WAIT_TIMEOUT)
	if screensInstance == nil then
		log.warn("PlayerGui.Screens did not appear -- launch control disabled")
		return nil
	end
	local uiInstance = screensInstance:WaitForChild("DropLaunchUI", WAIT_TIMEOUT)
	if uiInstance == nil or not uiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.Screens.DropLaunchUI did not appear -- launch control disabled")
		return nil
	end
	local actionsInstance = uiInstance:WaitForChild("CarryActions", WAIT_TIMEOUT)
	if actionsInstance == nil or not actionsInstance:IsA("Frame") then
		log.warn("DropLaunchUI.CarryActions did not appear -- launch control disabled")
		return nil
	end
	local buttonInstance = actionsInstance:WaitForChild("C.Launch", WAIT_TIMEOUT)
	if buttonInstance == nil or not buttonInstance:IsA("TextButton") then
		log.warn("DropLaunchUI.CarryActions.C.Launch did not appear -- launch control disabled")
		return nil
	end

	dropLaunchUi = uiInstance
	Targeting.setLaunchHudGui(uiInstance)
	launchButton = buttonInstance
	bindLaunchCooldownVisual(buttonInstance)
	LaunchButton.updateLaunchCooldownDisplay()
	return buttonInstance
end

local function bindLaunchButton()
	local button = resolveUi()
	if button == nil then
		return
	end
	if not CollectionService:HasTag(button, "UIButton") then
		CollectionService:AddTag(button, "UIButton")
	end
	if connectedButton == button then
		return
	end
	if activatedConnection ~= nil then
		activatedConnection:Disconnect()
	end

	connectedButton = button
	activatedConnection = button.Activated:Connect(beginTargeting)
	LaunchButton.updateLaunchCooldownDisplay()
end

local function resetDropLaunchUiState()
	Targeting.cancelTargeting()
	dropLaunchUi = nil
	Targeting.setLaunchHudGui(nil)
	launchButton = nil
	launchButtonLabel = nil
	launchButtonGradient = nil
	launchButtonIcon = nil
	readyLaunchGradient = nil
	task.spawn(bindLaunchButton)
end

-- Catches DropLaunchUI/LaunchTargetingUI being re-cloned directly inside an
-- already-connected Screens folder without the whole PlayerGui resetting
-- (e.g. some future system re-adding just one of them). The whole-PlayerGui
-- respawn case is handled separately in watchPlayerGui below, since there
-- Screens arrives with both ScreenGuis already parented -- their own
-- ChildAdded on the folder fires (if it fires at all) before this connection
-- could ever be made.
local function onScreensChildAdded(child: Instance)
	if not child:IsA("ScreenGui") then
		return
	end
	if child.Name == "DropLaunchUI" then
		resetDropLaunchUiState()
	elseif child.Name == "LaunchTargetingUI" then
		Targeting.resetLaunchTargetingUiState(child)
	end
end

local function watchScreensFolder(folder: Instance)
	if connectedScreensFolder == folder then
		return
	end
	if screensChildAddedConnection ~= nil then
		screensChildAddedConnection:Disconnect()
	end
	connectedScreensFolder = folder
	screensChildAddedConnection = folder.ChildAdded:Connect(onScreensChildAdded)
end

function LaunchButton.watchPlayerGui()
	local playerGui = player:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Screens" then
			-- ResetPlayerGuiOnSpawn re-clones the whole PlayerGui at once, so
			-- Screens arrives here as a single unit with LaunchTargetingUI and
			-- DropLaunchUI already parented inside it -- reset both directly
			-- instead of waiting for a ChildAdded on the folder that already
			-- fired (if at all) before watchScreensFolder below could connect.
			resetDropLaunchUiState()
			local targetingUi = child:FindFirstChild("LaunchTargetingUI")
			Targeting.resetLaunchTargetingUiState(
				if targetingUi ~= nil and targetingUi:IsA("ScreenGui") then targetingUi else nil
			)
			watchScreensFolder(child)
			return
		end
		if not child:IsA("ScreenGui") then
			return
		end
		if child.Name == "LaunchTargetMarkerUI" then
			Targeting.resetTargetMarkerUiCache()
			child.Enabled = false
		end
	end)

	-- Screens can already exist by the time this connects (the common case,
	-- since resolveTargetingUi/resolveUi below already WaitForChild it) or
	-- can still be on its way in on a slow first boot -- the ChildAdded
	-- connection above catches the late-arrival case, and this catches the
	-- already-there case, so individual re-clones inside it are watched from
	-- here on regardless of which race won.
	local existingScreens = playerGui:FindFirstChild("Screens")
	if existingScreens ~= nil then
		watchScreensFolder(existingScreens)
	end

	task.spawn(function()
		local authoredGui = Targeting.resolveTargetingUi()
		if authoredGui ~= nil then
			authoredGui.Enabled = false
		end
	end)
	task.spawn(function()
		local markerGui = Targeting.resolveTargetMarkerUi()
		if markerGui ~= nil then
			markerGui.Enabled = false
		end
	end)
	bindLaunchButton()
end

return LaunchButton
