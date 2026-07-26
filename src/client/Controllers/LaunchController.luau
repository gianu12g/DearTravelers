--!strict
--[[
	Connects the launch button to the authored LaunchTargetingUI and
	LaunchTargetMarkerUI instances in StarterGui. Targeting takes over the real
	Workspace.CurrentCamera, tweening it to a computed top-down overview pose
	while active and back to wherever the player's camera actually was on every
	exit path. The base ownership visuals now live in each base's NameLabel
	BillboardGui, so no duplicated viewport overlay is required.

	NameLabels use a raised world offset and half their authored size during
	normal play so they clear the forcefield domes without dominating the 3D
	view. During targeting they switch locally to their authored size and zero
	world offset: from the straight-down overview, raising a 3D point creates
	perspective parallax that pushes every label radially away from its base.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10
-- The overview camera height is computed to fit the map (see
-- resolveOverviewPose), clamped to at least FALLBACK_OVERVIEW_HEIGHT and
-- staying well under ~650 studs even on tall/portrait aspect ratios, so 2500
-- reaches the map plane from any on-screen click with generous margin.
local RAY_DISTANCE = 2500
local CAMERA_TAKEOVER_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CAMERA_RESTORE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Floor (and fallback, if the AABB comes out empty/degenerate) for the
-- computed overview height in resolveOverviewPose.
local FALLBACK_OVERVIEW_HEIGHT = 350
-- Fit margin applied to the computed overview height: 1.0 = map exactly
-- fills the tighter screen axis; raise to zoom out further. Hand-tuned in
-- Studio to put the camera at ~430 studs on a 16:9 screen at FOV 70.
local OVERVIEW_FIT_MARGIN = 1.325
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
local LAUNCH_COOLDOWN_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 95, 95)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 25, 25)),
})

type TargetSelection = {
	worldX: number,
	worldZ: number,
	screenPosition: Vector2,
	radiusDiameter: number,
}

local LaunchController = {}

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
local connectedCancelButton: TextButton? = nil
local cancelActivatedConnection: RBXScriptConnection? = nil
local connectedScreensFolder: Instance? = nil
local screensChildAddedConnection: RBXScriptConnection? = nil
local mapLayoutDescendantAddedConnection: RBXScriptConnection? = nil

local targeting = false
local awaitingServer = false
local playingAcceptedPlop = false
local pendingSelection: TargetSelection? = nil
local targetingGui: ScreenGui? = nil
local targetMarkerGui: ScreenGui? = nil
local targetIconHolder: Frame? = nil
local targetIcon: ImageLabel? = nil
local targetIconMotion: Motion.Handle? = nil
local targetDebugBox: Frame? = nil
local hintText: TextLabel? = nil
local hintRestPosition: UDim2? = nil
local hintMotion: Motion.Handle? = nil

-- Real-camera overview takeover (replaces the old ViewportFrame mini-map).
-- cameraHeld stays true for the whole time Workspace.CurrentCamera is ours --
-- from the moment takeOverCamera goes Scriptable until releaseCameraOverview's
-- restore tween actually COMPLETES, not merely until `targeting` turns false.
-- That gap is what lets a cancel-then-immediately-retarget re-take the camera
-- mid-restore without capturing the in-flight (already-overview-ish) pose as
-- "original".
local cameraHeld = false
local capturedCameraCFrame: CFrame? = nil
local capturedCameraFieldOfView: number? = nil
local capturedCameraType: Enum.CameraType? = nil
local cameraMotion: Motion.Handle? = nil
local overviewPoseWarned = false

-- AABB half-extents of Workspace.MapLayout's BaseParts (~7,300 of them), used
-- to fit the computed overview height in resolveOverviewPose. The map is
-- static, so this is computed once on first use and cached for the rest of
-- the client session.
local cachedMapHalfExtentX: number? = nil
local cachedMapHalfExtentZ: number? = nil
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

-- The 8 sign combinations for a box's local-space corners, used to build a
-- world-space AABB out of arbitrarily rotated parts in computeMapHalfExtents.
local CORNER_SIGNS = {
	Vector3.new(-1, -1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, 1, 1),
}

--[[
	Computes (and caches) the X/Z half-extents of the AABB of every BasePart
	descendant of mapLayout. The map (~7,300 parts) is static for the whole
	client session, so this walks the tree once and every later call just
	returns the cached values.
]]
local function computeMapHalfExtents(mapLayout: Instance): (number, number)
	if cachedMapHalfExtentX ~= nil and cachedMapHalfExtentZ ~= nil then
		return cachedMapHalfExtentX, cachedMapHalfExtentZ
	end

	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local foundPart = false
	for _, descendant in mapLayout:GetDescendants() do
		if descendant:IsA("BasePart") then
			foundPart = true
			local cframe = descendant.CFrame
			local halfSize = descendant.Size * 0.5
			for _, signs in CORNER_SIGNS do
				local corner = cframe:PointToWorldSpace(halfSize * signs)
				minX = math.min(minX, corner.X)
				maxX = math.max(maxX, corner.X)
				minZ = math.min(minZ, corner.Z)
				maxZ = math.max(maxZ, corner.Z)
			end
		end
	end

	local halfExtentX = if foundPart then (maxX - minX) / 2 else 0
	local halfExtentZ = if foundPart then (maxZ - minZ) / 2 else 0
	cachedMapHalfExtentX = halfExtentX
	cachedMapHalfExtentZ = halfExtentZ
	return halfExtentX, halfExtentZ
end

-- The BillboardGuis remain parented to their base parts; this local property
-- change does not replicate back to the server or affect another player's
-- camera. A per-label LaunchViewSize attribute, when present, is the source of
-- truth for its full launch-view size; otherwise its first observed Size is
-- cached. Normal play uses BASE_LABEL_GAMEPLAY_SCALE. GameplayWorldOffsetY may
-- override the geometry-derived normal height for art-direction tweaks.
local function setBaseLabelsLaunchMode(launchMode: boolean)
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

--[[
	Resolves the top-down overview camera pose WITHOUT mutating anything --
	unlike the old viewport implementation, this never creates or reparents a
	Camera.

	Precedence:
	1. LaunchOverviewCFrame/LaunchOverviewFieldOfView attributes on
	   LaunchTargetingUI -- a manual override for future art direction.
	2. A pose computed to fit Workspace.MapLayout under the live camera's
	   current FOV and aspect ratio, using the live camera's current FOV as
	   the returned FOV too (so the takeover tween never fights a menu
	   controller's own FieldOfView tween).
]]
local function resolveOverviewPose(overrideSource: Instance?): (CFrame?, number?)
	if overrideSource ~= nil then
		local overrideCFrame = overrideSource:GetAttribute("LaunchOverviewCFrame")
		local overrideFieldOfView = overrideSource:GetAttribute("LaunchOverviewFieldOfView")
		if typeof(overrideCFrame) == "CFrame" and typeof(overrideFieldOfView) == "number" then
			return overrideCFrame, overrideFieldOfView
		end
	end

	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local centerMap = if mapLayout ~= nil then mapLayout:FindFirstChild("CenterMap") else nil
	if mapLayout == nil or centerMap == nil or not centerMap:IsA("BasePart") then
		return nil, nil
	end

	local liveCamera = Workspace.CurrentCamera
	local fieldOfView = if liveCamera ~= nil then liveCamera.FieldOfView else 70
	local center = centerMap.Position

	local height = FALLBACK_OVERVIEW_HEIGHT
	if liveCamera ~= nil then
		local halfExtentX, halfExtentZ = computeMapHalfExtents(mapLayout)
		local halfTanV = math.tan(math.rad(fieldOfView) / 2)
		local aspect = liveCamera.ViewportSize.X / math.max(1, liveCamera.ViewportSize.Y)
		local halfTanH = halfTanV * aspect
		if halfExtentX > 0 and halfExtentZ > 0 and halfTanV > 0 and halfTanH > 0 then
			height = math.max(
				FALLBACK_OVERVIEW_HEIGHT,
				OVERVIEW_FIT_MARGIN * math.max(halfExtentZ / halfTanV, halfExtentX / halfTanH)
			)
		end
	end

	-- The explicit up vector is required: with a straight-down look direction
	-- the default up (0, 1, 0) is parallel to the look vector and produces a
	-- degenerate CFrame. (0, 0, -1) reproduces the screen orientation of the
	-- old authored pose (world -Z renders as screen up).
	return CFrame.lookAt(center + Vector3.new(0, height, 0), center, Vector3.new(0, 0, -1)), fieldOfView
end

--[[
	Takes Workspace.CurrentCamera over for the map overview. Capture-once: if
	we already hold the camera (cameraHeld), a prior restore is still in
	flight -- cancel it and re-tween from wherever the camera currently sits,
	but never re-capture, or the in-flight overview-ish pose would get stored
	as "original" and the real original would be lost for good.

	onPositioned (if given) fires exactly once, when the camera is considered
	"in position": on the takeover tween's onComplete along the normal path,
	or IMMEDIATELY on either degenerate early-return below, so a caller hiding
	something until the camera settles never strands it hidden forever. A
	cancel of the in-flight tween (re-takeover, or the caller giving up)
	suppresses onComplete via Motion's cancel -- callers must tolerate that.
]]
local function takeOverCamera(overrideSource: Instance?, onPositioned: (() -> ())?)
	local currentCamera = Workspace.CurrentCamera
	if currentCamera == nil then
		if onPositioned ~= nil then
			onPositioned()
		end
		return
	end

	local overviewCFrame, overviewFieldOfView = resolveOverviewPose(overrideSource)
	if overviewCFrame == nil or overviewFieldOfView == nil then
		if not overviewPoseWarned then
			overviewPoseWarned = true
			log.warn(
				"no launch map overview pose available (LaunchOverview* attributes and MapLayout.CenterMap are"
					.. " both missing) -- targeting will use the live camera as-is"
			)
		end
		if onPositioned ~= nil then
			onPositioned()
		end
		return
	end

	if cameraMotion ~= nil then
		cameraMotion.cancel()
		cameraMotion = nil
	end
	if not cameraHeld then
		cameraHeld = true
		capturedCameraCFrame = currentCamera.CFrame
		capturedCameraFieldOfView = currentCamera.FieldOfView
		capturedCameraType = currentCamera.CameraType
	end

	currentCamera.CameraType = Enum.CameraType.Scriptable

	-- Driven through Motion.value (a proxy NumberValue tween) instead of
	-- Motion.tween directly on the camera instance. TweenService cancels an
	-- instance's ENTIRE previous tween the moment a new tween shares any
	-- property with it -- so a menu/prompt tweening Camera.FieldOfView
	-- (UIKitController, MonetizationController) would silently kill a
	-- Motion.tween running here mid-flight, skip its onComplete, and strand
	-- the camera Scriptable forever. The proxy never touches the real
	-- camera's properties via TweenService, so it cannot collide.
	local startCFrame = currentCamera.CFrame
	local startFieldOfView = currentCamera.FieldOfView
	cameraMotion = Motion.value(0, 1, CAMERA_TAKEOVER_TWEEN, function(alpha)
		if currentCamera.Parent == nil then
			return
		end
		currentCamera.CFrame = startCFrame:Lerp(overviewCFrame, alpha)
		currentCamera.FieldOfView = startFieldOfView + (overviewFieldOfView - startFieldOfView) * alpha
	end, onPositioned)
end

--[[
	Tweens Workspace.CurrentCamera back to whatever it was before takeOverCamera
	touched it. CameraType only flips back to the captured type -- and
	cameraHeld only clears -- once the tween actually COMPLETES. Motion's
	:cancel() (used when takeOverCamera re-takes the camera mid-restore)
	suppresses onComplete, so an interrupted restore correctly leaves
	cameraHeld true and the captured values intact instead of losing them or
	leaving CameraType stuck Scriptable.
]]
local function releaseCameraOverview()
	if not cameraHeld then
		return
	end
	if cameraMotion ~= nil then
		cameraMotion.cancel()
		cameraMotion = nil
	end

	local currentCamera = Workspace.CurrentCamera
	local restoreCFrame = capturedCameraCFrame
	local restoreFieldOfView = capturedCameraFieldOfView
	local restoreCameraType = capturedCameraType
	if currentCamera == nil or restoreCFrame == nil or restoreFieldOfView == nil or restoreCameraType == nil then
		-- Nothing sane to restore to (camera gone, or an incomplete capture --
		-- should not happen since the three are always set together). Reset
		-- CameraType if we still can, and drop the held state either way so a
		-- future takeover captures fresh values instead of reusing stale ones.
		if currentCamera ~= nil and restoreCameraType ~= nil then
			currentCamera.CameraType = restoreCameraType
		end
		cameraHeld = false
		capturedCameraCFrame = nil
		capturedCameraFieldOfView = nil
		capturedCameraType = nil
		return
	end

	-- See takeOverCamera: driven through Motion.value's proxy NumberValue so a
	-- menu/prompt tweening Camera.FieldOfView elsewhere cannot supersede this
	-- restore and strand the camera Scriptable.
	local startCFrame = currentCamera.CFrame
	local startFieldOfView = currentCamera.FieldOfView

	local motion: Motion.Handle?
	motion = Motion.value(0, 1, CAMERA_RESTORE_TWEEN, function(alpha)
		if currentCamera.Parent == nil then
			return
		end
		currentCamera.CFrame = startCFrame:Lerp(restoreCFrame, alpha)
		currentCamera.FieldOfView = startFieldOfView + (restoreFieldOfView - startFieldOfView) * alpha
	end, function()
		if cameraMotion == motion then
			cameraMotion = nil
		end
		currentCamera.CameraType = restoreCameraType
		cameraHeld = false
		capturedCameraCFrame = nil
		capturedCameraFieldOfView = nil
		capturedCameraType = nil
	end)
	cameraMotion = motion
end

local function resolveTargetMarkerUi(): (ScreenGui?, Frame?, ImageLabel?, Frame?)
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

local function resolveTargetingUi(): ScreenGui?
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
			LaunchController.cancelTargeting()
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
	local hudGui = dropLaunchUi
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
	setBaseLabelsLaunchMode(false)
	releaseCameraOverview()
end

function LaunchController.cancelTargeting()
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

local function chooseTarget(screenPosition: Vector2)
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

local function updateLaunchCooldownDisplay()
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
	if targeting or player:GetAttribute("CarryingTier") == nil then
		return
	end
	if launchCooldownRemaining() > 0 then
		updateLaunchCooldownDisplay()
		return
	end

	local ui = dropLaunchUi
	if ui == nil or ui.Parent == nil then
		log.warn("DropLaunchUI is unavailable -- launch targeting skipped")
		return
	end

	local overlayGui = resolveTargetingUi()
	if overlayGui == nil then
		return
	end
	local markerGui, iconHolder, icon, debugBox = resolveTargetMarkerUi()
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

	targetMarkerGui = markerGui
	targetIconHolder = iconHolder
	targetIcon = icon
	targetDebugBox = debugBox
	targeting = true
	awaitingServer = false
	playingAcceptedPlop = false
	pendingSelection = nil
	setBaseLabelsLaunchMode(true)
	takeOverCamera(overlayGui, nil)
	setHint("Choose anywhere on the map")
	markerGui.Enabled = true
	overlayGui.Enabled = true

	-- Deferred one frame: this runs inside the launch button's own Activated
	-- handler, and disabling its ScreenGui synchronously can strand
	-- Buttons.luau's hover/press state machine (see src/client/UI/Buttons.luau
	-- MouseEnter/MouseButton1Down handling -- MouseLeave never fires once the
	-- gui is gone). Re-check targeting and ui.Parent after the defer -- a
	-- same-frame cancel must not hide the HUD permanently.
	task.defer(function()
		if not targeting or ui.Parent == nil then
			return
		end
		ui.Enabled = false
	end)
end

function LaunchController.beginTargeting()
	beginTargeting()
end

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
	launchButton = buttonInstance
	bindLaunchCooldownVisual(buttonInstance)
	updateLaunchCooldownDisplay()
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
	activatedConnection = button.Activated:Connect(LaunchController.beginTargeting)
	updateLaunchCooldownDisplay()
end

local function resetDropLaunchUiState()
	LaunchController.cancelTargeting()
	dropLaunchUi = nil
	launchButton = nil
	launchButtonLabel = nil
	launchButtonGradient = nil
	launchButtonIcon = nil
	readyLaunchGradient = nil
	task.spawn(bindLaunchButton)
end

local function resetLaunchTargetingUiState(child: ScreenGui?)
	LaunchController.cancelTargeting()
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
		local authoredGui = resolveTargetingUi()
		if authoredGui ~= nil then
			authoredGui.Enabled = false
		end
	end)
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
		resetLaunchTargetingUiState(child)
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

local function watchPlayerGui()
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
			resetLaunchTargetingUiState(
				if targetingUi ~= nil and targetingUi:IsA("ScreenGui") then targetingUi else nil
			)
			watchScreensFolder(child)
			return
		end
		if not child:IsA("ScreenGui") then
			return
		end
		if child.Name == "LaunchTargetMarkerUI" then
			LaunchController.cancelTargeting()
			targetMarkerGui = nil
			targetIconHolder = nil
			targetIcon = nil
			targetDebugBox = nil
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
		local authoredGui = resolveTargetingUi()
		if authoredGui ~= nil then
			authoredGui.Enabled = false
		end
	end)
	task.spawn(function()
		local markerGui = resolveTargetMarkerUi()
		if markerGui ~= nil then
			markerGui.Enabled = false
		end
	end)
	bindLaunchButton()
end

function LaunchController.Init()
	setBaseLabelsLaunchMode(false)
	task.spawn(function()
		local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
		if mapLayout == nil then
			return
		end

		local previousConnection = mapLayoutDescendantAddedConnection
		if previousConnection ~= nil then
			previousConnection:Disconnect()
		end
		mapLayoutDescendantAddedConnection = mapLayout.DescendantAdded:Connect(function(descendant)
			local parent = descendant.Parent
			local isNameLabel = descendant:IsA("BillboardGui") and descendant.Name == "NameLabel"
			local isForcefield = descendant:IsA("BasePart") and parent ~= nil and parent.Name == "BaseForcefields"
			if not isNameLabel and not isForcefield then
				return
			end

			task.defer(function()
				if mapLayout.Parent ~= nil then
					setBaseLabelsLaunchMode(targeting)
				end
			end)
		end)
		setBaseLabelsLaunchMode(targeting)
	end)

	Net.mergeLaunchResult.listen(function(data)
		if not targeting then
			return
		end
		local selection = pendingSelection
		pendingSelection = nil
		awaitingServer = false
		if data.ok then
			if selection == nil then
				LaunchController.cancelTargeting()
				return
			end
			setHint("Launching…")
			playingAcceptedPlop = true
			plopTargetIcon(selection, function()
				if not targeting or not playingAcceptedPlop then
					return
				end
				playingAcceptedPlop = false
				LaunchController.cancelTargeting()
			end)
		elseif player:GetAttribute("CarryingTier") == nil then
			LaunchController.cancelTargeting()
		else
			rejectHint(data.message)
		end
	end)

	local carryingChanged = player:GetAttributeChangedSignal("CarryingTier")
	carryingChanged:Connect(function()
		if player:GetAttribute("CarryingTier") == nil and not awaitingServer and not playingAcceptedPlop then
			LaunchController.cancelTargeting()
		end
		updateLaunchCooldownDisplay()
	end)
	local launchReadyChanged = player:GetAttributeChangedSignal("CarryingLaunchReadyAt")
	launchReadyChanged:Connect(updateLaunchCooldownDisplay)
	local radiusDebugChanged = player:GetAttributeChangedSignal(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE)
	radiusDebugChanged:Connect(function()
		if targeting then
			updateTargetDebugVisibility()
		end
	end)

	local cooldownDisplayAccumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		cooldownDisplayAccumulator += dt
		if cooldownDisplayAccumulator < 0.1 then
			return
		end
		cooldownDisplayAccumulator = 0
		updateLaunchCooldownDisplay()
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not targeting then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.UserInputType == Enum.UserInputType.MouseButton2 then
			LaunchController.cancelTargeting()
		elseif not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			chooseTarget(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)

	UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
		if targeting and not awaitingServer and not gameProcessed and #touchPositions > 0 then
			chooseTarget(touchPositions[1])
		end
	end)

	task.spawn(watchPlayerGui)
	log.info("ready (real-camera launch targeting)")
end

return LaunchController
