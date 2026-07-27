--!strict
--[[
	Owns the launch-targeting state machine: the LaunchTargetingUI/
	LaunchTargetMarkerUI instances, the base ownership NameLabel launch-mode
	visuals, target selection, and the request/response round trip through
	Net.mergeLaunchRequest / Net.mergeLaunchResult.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Camera = require(script.Parent.Camera)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Motion = require(script.Parent.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10
-- The overview camera height is computed to fit the map (see
-- resolveOverviewPose), clamped to at least FALLBACK_OVERVIEW_HEIGHT and
-- staying well under ~650 studs even on tall/portrait aspect ratios, so 2500
-- reaches the map plane from any on-screen click with generous margin.
local RAY_DISTANCE = 2500
local BASE_LABEL_FORCEFIELD_PADDING = 6
local BASE_LABEL_GAMEPLAY_SCALE = 0.5
local TARGET_ICON_WIDTH_SCALE = 0.056
local TARGET_ICON_DROP_DISTANCE = 46
local TARGET_ICON_START_SCALE = 0.3
local TARGET_ICON_START_ROTATION = -12
local HINT_ERROR_COLOR = Color3.fromRGB(230, 0, 0)
-- The hint label is TextScaled, and scaling it (UIScale or Size) re-fits the
-- text at integer font sizes -- a 10% pulse renders only ~4 discrete sizes and
-- looks steppy. Animate Position instead: it never re-lays-out text, so the
-- reject cue renders smoothly at render cadence.
local HINT_REJECT_HOP_OFFSET = 7
local HINT_REJECT_HOP = TweenInfo.new(0.13, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true)

export type TargetSelection = {
	worldX: number,
	worldZ: number,
	screenPosition: Vector2,
	radiusDiameter: number,
}

-- Mirrors the struct declared for Net.mergeLaunchResult (see src/shared/Net.luau)
-- -- Net does not export a named type for it, and .listen's callback parameter
-- can only be inferred inline, not through a standalone module function.
type LaunchResult = {
	ok: boolean,
	message: string,
}

local Targeting = {}

local targetingGui: ScreenGui? = nil
local connectedCancelButton: TextButton? = nil
local cancelActivatedConnection: RBXScriptConnection? = nil

-- Mirrors LaunchButton's dropLaunchUi (the DropLaunchUI HUD), pushed in by
-- LaunchButton.setLaunchHudGui whenever it resolves or clears its own copy.
-- Targeting only needs it to re-show the HUD once a targeting session ends;
-- LaunchButton remains the single owner that resolves/clears the instance.
local launchHudGui: ScreenGui? = nil

local targeting = false
local awaitingServer = false
local playingAcceptedPlop = false
local pendingSelection: TargetSelection? = nil
local targetMarkerGui: ScreenGui? = nil
local targetIconHolder: Frame? = nil
local targetIcon: ImageLabel? = nil
local targetIconMotion: Motion.Handle? = nil
local targetDebugBox: Frame? = nil
local hintText: TextLabel? = nil
local hintRestPosition: UDim2? = nil
local hintMotion: Motion.Handle? = nil

local baseLabelLaunchSizes: { [BillboardGui]: UDim2 } = {}

local function radiusDebugEnabled(): boolean
	return player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
end

local function cancelHintMotion()
	local motion = hintMotion
	hintMotion = nil
	if motion ~= nil then
		motion.cancel()
	end
	local label = hintText
	local rest = hintRestPosition
	if label ~= nil and label.Parent ~= nil and rest ~= nil then
		label.Position = rest
	end
end

-- The BillboardGuis remain parented to their base parts; this local property
-- change does not replicate back to the server or affect another player's
-- camera. A per-label LaunchViewSize attribute, when present, is the source of
-- truth for its full launch-view size; otherwise its first observed Size is
-- cached. Normal play uses BASE_LABEL_GAMEPLAY_SCALE. GameplayWorldOffsetY may
-- override the geometry-derived normal height for art-direction tweaks.
function Targeting.setBaseLabelsLaunchMode(launchMode: boolean)
	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local basesFolder = if mapLayout ~= nil then mapLayout:FindFirstChild("Bases") else nil
	local forcefieldsFolder = if mapLayout ~= nil then mapLayout:FindFirstChild("BaseForcefields") else nil
	if basesFolder == nil then
		return
	end

	for _, baseInstance in basesFolder:GetChildren() do
		if not baseInstance:IsA("BasePart") then
			continue
		end
		local nameLabel = baseInstance:FindFirstChild("NameLabel")
		if nameLabel == nil or not nameLabel:IsA("BillboardGui") then
			continue
		end

		local configuredLaunchSize = nameLabel:GetAttribute("LaunchViewSize")
		local launchSize = if typeof(configuredLaunchSize) == "UDim2" then configuredLaunchSize else nil
		launchSize = launchSize or baseLabelLaunchSizes[nameLabel]
		if launchSize == nil then
			launchSize = nameLabel.Size
			baseLabelLaunchSizes[nameLabel] = launchSize
		end

		if launchMode then
			nameLabel.Size = launchSize
			nameLabel.StudsOffsetWorldSpace = Vector3.zero
			continue
		end

		nameLabel.Size = UDim2.new(
			launchSize.X.Scale * BASE_LABEL_GAMEPLAY_SCALE,
			launchSize.X.Offset * BASE_LABEL_GAMEPLAY_SCALE,
			launchSize.Y.Scale * BASE_LABEL_GAMEPLAY_SCALE,
			launchSize.Y.Offset * BASE_LABEL_GAMEPLAY_SCALE
		)
		local configuredOffset = nameLabel:GetAttribute("GameplayWorldOffsetY")
		local offsetY = if typeof(configuredOffset) == "number" then configuredOffset else nil
		if offsetY == nil and forcefieldsFolder ~= nil then
			local forcefield = forcefieldsFolder:FindFirstChild(baseInstance.Name .. "Forcefield")
			if forcefield ~= nil and forcefield:IsA("BasePart") then
				offsetY = forcefield.Position.Y
					+ forcefield.Size.Y / 2
					- baseInstance.Position.Y
					+ BASE_LABEL_FORCEFIELD_PADDING
			end
		end
		nameLabel.StudsOffsetWorldSpace = Vector3.new(0, offsetY or 0, 0)
	end
end

function Targeting.resolveTargetMarkerUi(): (ScreenGui?, Frame?, ImageLabel?, Frame?)
	-- LaunchTargetMarkerUI stays a direct PlayerGui child -- unlike
	-- LaunchTargetingUI/DropLaunchUI, it was never moved under Screens.
	local playerGui = player:WaitForChild("PlayerGui")
	local guiInstance = playerGui:WaitForChild("LaunchTargetMarkerUI", WAIT_TIMEOUT)
	if guiInstance == nil or not guiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.LaunchTargetMarkerUI did not appear -- launch targeting disabled")
		return nil, nil, nil, nil
	end

	local iconHolderInstance = guiInstance:FindFirstChild("LaunchTargetIconHolder")
	local iconInstance = if iconHolderInstance ~= nil then iconHolderInstance:FindFirstChild("Icon") else nil
	local debugBoxInstance = guiInstance:FindFirstChild("LaunchRadiusDebugBox")
	if iconHolderInstance == nil or not iconHolderInstance:IsA("Frame") then
		log.warn("LaunchTargetMarkerUI.LaunchTargetIconHolder is missing")
		return nil, nil, nil, nil
	end
	if iconInstance == nil or not iconInstance:IsA("ImageLabel") then
		log.warn("LaunchTargetMarkerUI.LaunchTargetIconHolder.Icon is missing")
		return nil, nil, nil, nil
	end
	if debugBoxInstance == nil or not debugBoxInstance:IsA("Frame") then
		log.warn("LaunchTargetMarkerUI.LaunchRadiusDebugBox is missing")
		return nil, nil, nil, nil
	end

	return guiInstance, iconHolderInstance, iconInstance, debugBoxInstance
end

function Targeting.resolveTargetingUi(): ScreenGui?
	local playerGui = player:WaitForChild("PlayerGui")
	local screensInstance = playerGui:WaitForChild("Screens", WAIT_TIMEOUT)
	if screensInstance == nil then
		log.warn("PlayerGui.Screens did not appear -- launch targeting disabled")
		return nil
	end
	local uiInstance = screensInstance:WaitForChild("LaunchTargetingUI", WAIT_TIMEOUT)
	if uiInstance == nil or not uiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.Screens.LaunchTargetingUI did not appear -- launch targeting disabled")
		return nil
	end

	local hintInstance = uiInstance:FindFirstChild("LaunchTargetingHint")
	local backgroundInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("BG") else nil
	local labelInstance = if backgroundInstance ~= nil then backgroundInstance:FindFirstChild("TextLabel") else nil
	local cancelInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("Cancel") else nil
	if labelInstance == nil or not labelInstance:IsA("TextLabel") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.BG.TextLabel is missing")
		return nil
	end
	if cancelInstance == nil or not cancelInstance:IsA("TextButton") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.Cancel is missing")
		return nil
	end

	if hintText ~= labelInstance then
		cancelHintMotion()
	end
	-- Remove the UIScale pulse left by a previous version of this controller
	-- if it is hot-reloaded into an already-running client. The reject cue now
	-- animates Position instead.
	local oldScale = labelInstance:FindFirstChild("RejectScale")
	if oldScale ~= nil then
		oldScale:Destroy()
	end
	targetingGui = uiInstance
	hintText = labelInstance
	hintRestPosition = labelInstance.Position
	if connectedCancelButton ~= cancelInstance then
		if cancelActivatedConnection ~= nil then
			cancelActivatedConnection:Disconnect()
		end
		connectedCancelButton = cancelInstance
		cancelActivatedConnection = cancelInstance.Activated:Connect(function()
			Targeting.cancelTargeting()
		end)
	end
	return uiInstance
end

local function setHint(message: string, isError: boolean?)
	cancelHintMotion()
	local label = hintText
	if label == nil or label.Parent == nil then
		return
	end
	label.Text = message
	label.TextColor3 = if isError then HINT_ERROR_COLOR else Color3.new(1, 1, 1)
end

local function rejectHint(message: string)
	setHint(message, true)
	local label = hintText
	local rest = hintRestPosition
	if label == nil or label.Parent == nil or rest == nil then
		return
	end

	local hopMotion: Motion.Handle?
	hopMotion = Motion.tween(
		label,
		{ Position = rest - UDim2.fromOffset(0, HINT_REJECT_HOP_OFFSET) },
		HINT_REJECT_HOP,
		function()
			if hintMotion == hopMotion then
				hintMotion = nil
			end
		end
	)
	hintMotion = hopMotion
end

local function destroyTargetingVisuals()
	local gui = targetingGui
	local markerGui = targetMarkerGui
	local iconMotion = targetIconMotion
	local hudGui = launchHudGui
	cancelHintMotion()
	targetMarkerGui = nil
	targetIconHolder = nil
	targetIcon = nil
	targetIconMotion = nil
	targetDebugBox = nil
	if iconMotion ~= nil then
		iconMotion.cancel()
	end
	if gui ~= nil and gui.Parent ~= nil then
		gui.Enabled = false
	end
	if markerGui ~= nil and markerGui.Parent ~= nil then
		markerGui.Enabled = false
	end
	if hudGui ~= nil and hudGui.Parent ~= nil then
		hudGui.Enabled = true
	end
	Targeting.setBaseLabelsLaunchMode(false)
	Camera.releaseCameraOverview()
end

-- Called by LaunchButton whenever it resolves or clears its own dropLaunchUi
-- reference, so destroyTargetingVisuals can re-show the HUD without Targeting
-- and LaunchButton requiring each other.
function Targeting.setLaunchHudGui(ui: ScreenGui?)
	launchHudGui = ui
end

function Targeting.cancelTargeting()
	if not targeting then
		return
	end
	targeting = false
	awaitingServer = false
	playingAcceptedPlop = false
	pendingSelection = nil
	destroyTargetingVisuals()
end

local function selectionAt(screenPosition: Vector2): TargetSelection?
	local camera = Workspace.CurrentCamera
	local mapLayout = Workspace:FindFirstChild("MapLayout")
	if camera == nil or mapLayout == nil then
		return nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { mapLayout }

	local unitRay = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * RAY_DISTANCE, raycastParams)
	if result == nil then
		return nil
	end
	local resultCameraPoint = camera.CFrame:PointToObjectSpace(result.Position)
	local resultDepth = -resultCameraPoint.Z
	if resultDepth <= 0 then
		return nil
	end
	local tangent = math.tan(math.rad(camera.FieldOfView) / 2)
	local radiusDiameter = (MergeConfig.LAUNCH_IMPACT_RADIUS * camera.ViewportSize.Y) / (resultDepth * tangent)

	return {
		worldX = result.Position.X,
		worldZ = result.Position.Z,
		screenPosition = screenPosition,
		radiusDiameter = radiusDiameter,
	}
end

local function updateTargetDebugVisibility()
	local iconHolder = targetIconHolder
	local debugBox = targetDebugBox
	if iconHolder == nil or debugBox == nil then
		return
	end
	debugBox.Visible = iconHolder.Visible and radiusDebugEnabled()
end

local function plopTargetIcon(selection: TargetSelection, onComplete: () -> ())
	local iconHolder = targetIconHolder
	local icon = targetIcon
	local debugBox = targetDebugBox
	if iconHolder == nil or icon == nil or debugBox == nil then
		onComplete()
		return
	end

	local oldMotion = targetIconMotion
	if oldMotion ~= nil then
		oldMotion.cancel()
	end

	local position = selection.screenPosition
	iconHolder.Visible = true
	debugBox.Position = UDim2.fromOffset(position.X, position.Y)
	debugBox.Size = UDim2.fromOffset(selection.radiusDiameter, selection.radiusDiameter)
	updateTargetDebugVisibility()

	local motion: Motion.Handle?
	motion = Motion.value(0, 1, "pop", function(alpha)
		if iconHolder.Parent == nil or icon.Parent == nil then
			return
		end
		local scale = TARGET_ICON_START_SCALE + (1 - TARGET_ICON_START_SCALE) * alpha
		iconHolder.Position = UDim2.fromOffset(position.X, position.Y - TARGET_ICON_DROP_DISTANCE * (1 - alpha))
		iconHolder.Size = UDim2.fromScale(TARGET_ICON_WIDTH_SCALE * scale, scale)
		iconHolder.Rotation = TARGET_ICON_START_ROTATION * (1 - alpha)
		icon.ImageTransparency = 1 - math.clamp(alpha * 2, 0, 1)
	end, function()
		if targetIconMotion == motion then
			targetIconMotion = nil
		end
		onComplete()
	end)
	targetIconMotion = motion
end

function Targeting.chooseTarget(screenPosition: Vector2)
	if not targeting or awaitingServer or playingAcceptedPlop then
		return
	end

	local selection = selectionAt(screenPosition)
	if selection == nil then
		rejectHint("Choose a point inside the map")
		return
	end

	awaitingServer = true
	pendingSelection = selection
	Net.mergeLaunchRequest.send({
		worldX = selection.worldX,
		worldZ = selection.worldZ,
	})
end

function Targeting.isTargeting(): boolean
	return targeting
end

function Targeting.isAwaitingServer(): boolean
	return awaitingServer
end

--[[
	Enters targeting mode once LaunchButton has resolved and prepared the
	overlay/marker GUIs. Called from LaunchButton.beginTargeting -- kept here
	because it mutates Targeting's private state (targeting, targetMarkerGui,
	etc.).
]]
function Targeting.beginTargetingSession(
	overlayGui: ScreenGui,
	markerGui: ScreenGui,
	iconHolder: Frame,
	icon: ImageLabel,
	debugBox: Frame
)
	targetMarkerGui = markerGui
	targetIconHolder = iconHolder
	targetIcon = icon
	targetDebugBox = debugBox
	targeting = true
	awaitingServer = false
	playingAcceptedPlop = false
	pendingSelection = nil
	Targeting.setBaseLabelsLaunchMode(true)
	Camera.takeOverCamera(overlayGui, nil)
	setHint("Choose anywhere on the map")
end

-- Catches DropLaunchUI/LaunchTargetingUI being re-cloned directly inside an
-- already-connected Screens folder without the whole PlayerGui resetting
-- (e.g. some future system re-adding just one of them). The whole-PlayerGui
-- respawn case is handled separately in watchPlayerGui (see LaunchButton),
-- since there Screens arrives with both ScreenGuis already parented -- their
-- own ChildAdded on the folder fires (if it fires at all) before this
-- connection could ever be made.
function Targeting.resetLaunchTargetingUiState(child: ScreenGui?)
	Targeting.cancelTargeting()
	targetingGui = nil
	hintText = nil
	hintRestPosition = nil
	connectedCancelButton = nil
	if cancelActivatedConnection ~= nil then
		cancelActivatedConnection:Disconnect()
		cancelActivatedConnection = nil
	end
	if child ~= nil then
		child.Enabled = false
	end
	task.spawn(function()
		local authoredGui = Targeting.resolveTargetingUi()
		if authoredGui ~= nil then
			authoredGui.Enabled = false
		end
	end)
end

-- Handles LaunchTargetMarkerUI being re-cloned directly inside PlayerGui
-- (see LaunchButton.watchPlayerGui).
function Targeting.resetTargetMarkerUiCache()
	Targeting.cancelTargeting()
	targetMarkerGui = nil
	targetIconHolder = nil
	targetIcon = nil
	targetDebugBox = nil
end

function Targeting.refreshDebugVisibility()
	if targeting then
		updateTargetDebugVisibility()
	end
end

function Targeting.handleCarryingTierChanged()
	if player:GetAttribute("CarryingTier") == nil and not awaitingServer and not playingAcceptedPlop then
		Targeting.cancelTargeting()
	end
end

function Targeting.handleLaunchResult(data: LaunchResult)
	if not targeting then
		return
	end
	local selection = pendingSelection
	pendingSelection = nil
	awaitingServer = false
	if data.ok then
		if selection == nil then
			Targeting.cancelTargeting()
			return
		end
		setHint("Launching…")
		playingAcceptedPlop = true
		plopTargetIcon(selection, function()
			if not targeting or not playingAcceptedPlop then
				return
			end
			playingAcceptedPlop = false
			Targeting.cancelTargeting()
		end)
	elseif player:GetAttribute("CarryingTier") == nil then
		Targeting.cancelTargeting()
	else
		rejectHint(data.message)
	end
end

return Targeting
