--!strict
--[[
	Connects the launch button to the authored LaunchTargetingUI and
	LaunchTargetMarkerUI instances in StarterGui. Map geometry and UI remain
	entirely authored. Roblox does not replicate Camera instances, so the
	controller creates only the ViewportFrame's local camera from authored
	attributes; it never builds, resizes, replaces, or clears MapPreview.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10
local RAY_DISTANCE = 5000
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

type AuthoredMapUi = {
	labels: { [string]: TextLabel },
	ownerAvatar: ImageLabel,
	ownerName: TextLabel,
	ownerNameOffset: UDim2,
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

local targeting = false
local awaitingServer = false
local playingAcceptedPlop = false
local pendingSelection: TargetSelection? = nil
local targetingGui: ScreenGui? = nil
local targetMarkerGui: ScreenGui? = nil
local overview: ViewportFrame? = nil
local overviewWorld: WorldModel? = nil
local overviewCamera: Camera? = nil
local targetIconHolder: Frame? = nil
local targetIcon: ImageLabel? = nil
local targetIconMotion: Motion.Handle? = nil
local targetDebugBox: Frame? = nil
local hintText: TextLabel? = nil
local hintRestPosition: UDim2? = nil
local hintMotion: Motion.Handle? = nil

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

local function resolveAuthoredMapUi(viewport: ViewportFrame): AuthoredMapUi?
	local labels: { [string]: TextLabel } = {}
	for _, text in { "CENTER", "BASE1", "BASE2", "BASE3", "BASE4", "BASE5", "BASE6", "BASE7", "BASE8" } do
		local instance = viewport:FindFirstChild(text .. "Label")
		if instance == nil or not instance:IsA("TextLabel") then
			log.warn(`LaunchTargetingUI.LaunchMapViewport.{text}Label is missing`)
			return nil
		end
		labels[text] = instance
	end

	local avatarInstance = viewport:FindFirstChild("BaseOwnerAvatar")
	if avatarInstance == nil or not avatarInstance:IsA("ImageLabel") then
		log.warn("LaunchTargetingUI.LaunchMapViewport.BaseOwnerAvatar is missing")
		return nil
	end
	local nameInstance = viewport:FindFirstChild("BaseOwnerName")
	if nameInstance == nil or not nameInstance:IsA("TextLabel") then
		log.warn("LaunchTargetingUI.LaunchMapViewport.BaseOwnerName is missing")
		return nil
	end

	return {
		labels = labels,
		ownerAvatar = avatarInstance,
		ownerName = nameInstance,
		ownerNameOffset = nameInstance.Position - avatarInstance.Position,
	}
end

local function resolveAuthoredOverview(viewport: ViewportFrame): (WorldModel?, Camera?)
	local worldInstance = viewport:FindFirstChild("MapPreview")
	if worldInstance == nil or not worldInstance:IsA("WorldModel") then
		log.warn("LaunchTargetingUI.LaunchMapViewport.MapPreview is missing")
		return nil, nil
	end

	local camera: Camera? = nil
	local cameraInstance = viewport:FindFirstChild("LaunchMapCamera")
	if cameraInstance ~= nil and cameraInstance:IsA("Camera") then
		camera = cameraInstance
	else
		local cameraCFrame = viewport:GetAttribute("LaunchCameraCFrame")
		local cameraFocus = viewport:GetAttribute("LaunchCameraFocus")
		local cameraFieldOfView = viewport:GetAttribute("LaunchCameraFieldOfView")
		if
			typeof(cameraCFrame) ~= "CFrame"
			or typeof(cameraFocus) ~= "CFrame"
			or typeof(cameraFieldOfView) ~= "number"
		then
			log.warn("LaunchTargetingUI.LaunchMapViewport camera attributes are missing")
			return nil, nil
		end

		camera = Instance.new("Camera")
		camera.Name = "LaunchMapCamera"
		camera.CFrame = cameraCFrame
		camera.Focus = cameraFocus
		camera.FieldOfView = cameraFieldOfView
		camera.Parent = viewport
	end

	viewport.CurrentCamera = camera
	return worldInstance, camera
end

local function updateAuthoredOwnership(authoredUi: AuthoredMapUi)
	authoredUi.ownerAvatar.Visible = false
	authoredUi.ownerName.Visible = false
	for text, label in authoredUi.labels do
		label.Text = text
		label.Visible = true
	end

	local assignedBase = player:GetAttribute("AssignedBase")
	if typeof(assignedBase) ~= "string" then
		return
	end
	local baseLabel = authoredUi.labels[string.upper(assignedBase)]
	if baseLabel == nil then
		log.warn(`LaunchTargetingUI has no authored label for {assignedBase}`)
		return
	end

	baseLabel.Visible = false
	authoredUi.ownerAvatar.Position = baseLabel.Position
	authoredUi.ownerAvatar.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
	authoredUi.ownerAvatar.Visible = true
	authoredUi.ownerName.Position = baseLabel.Position + authoredUi.ownerNameOffset
	authoredUi.ownerName.Text = player.DisplayName
	authoredUi.ownerName.Visible = true

	local stroke = authoredUi.ownerAvatar:FindFirstChildOfClass("UIStroke")
	if stroke ~= nil then
		stroke.Color = Color3.fromRGB(255, 232, 92)
	end
end

local function resolveTargetMarkerUi(): (ScreenGui?, Frame?, ImageLabel?, Frame?)
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

local function resolveTargetingUi(): (ScreenGui?, ViewportFrame?, AuthoredMapUi?)
	local playerGui = player:WaitForChild("PlayerGui")
	local uiInstance = playerGui:WaitForChild("LaunchTargetingUI", WAIT_TIMEOUT)
	if uiInstance == nil or not uiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.LaunchTargetingUI did not appear -- launch targeting disabled")
		return nil, nil, nil
	end

	local viewportInstance = uiInstance:FindFirstChild("LaunchMapViewport")
	if viewportInstance == nil or not viewportInstance:IsA("ViewportFrame") then
		log.warn("LaunchTargetingUI.LaunchMapViewport is missing")
		return nil, nil, nil
	end
	local authoredMapUi = resolveAuthoredMapUi(viewportInstance)
	if authoredMapUi == nil then
		return nil, nil, nil
	end

	local hintInstance = uiInstance:FindFirstChild("LaunchTargetingHint")
	local backgroundInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("BG") else nil
	local labelInstance = if backgroundInstance ~= nil then backgroundInstance:FindFirstChild("TextLabel") else nil
	local cancelInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("Cancel") else nil
	if labelInstance == nil or not labelInstance:IsA("TextLabel") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.BG.TextLabel is missing")
		return nil, nil, nil
	end
	if cancelInstance == nil or not cancelInstance:IsA("TextButton") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.Cancel is missing")
		return nil, nil, nil
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
	return uiInstance, viewportInstance, authoredMapUi
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
	cancelHintMotion()
	targetMarkerGui = nil
	overview = nil
	overviewWorld = nil
	overviewCamera = nil
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
	local viewport = overview
	local worldModel = overviewWorld
	local camera = overviewCamera
	if viewport == nil or worldModel == nil or camera == nil then
		return nil
	end

	local absolutePosition = viewport.AbsolutePosition
	local absoluteSize = viewport.AbsoluteSize
	if absoluteSize.X <= 0 or absoluteSize.Y <= 0 then
		return nil
	end
	local xScale = (screenPosition.X - absolutePosition.X) / absoluteSize.X
	local yScale = (screenPosition.Y - absolutePosition.Y) / absoluteSize.Y
	if xScale < 0 or xScale > 1 or yScale < 0 or yScale > 1 then
		return nil
	end

	local aspect = absoluteSize.X / absoluteSize.Y
	local tangent = math.tan(math.rad(camera.FieldOfView) / 2)
	local cameraDirection = Vector3.new((xScale * 2 - 1) * aspect * tangent, (1 - yScale * 2) * tangent, -1).Unit
	local worldDirection = camera.CFrame:VectorToWorldSpace(cameraDirection)
	local result = worldModel:Raycast(camera.CFrame.Position, worldDirection * RAY_DISTANCE)
	if result == nil then
		return nil
	end
	local resultCameraPoint = camera.CFrame:PointToObjectSpace(result.Position)
	local resultDepth = -resultCameraPoint.Z
	if resultDepth <= 0 then
		return nil
	end
	local radiusDiameter = (MergeConfig.LAUNCH_IMPACT_RADIUS * absoluteSize.Y) / (resultDepth * tangent)

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
	label.Text = if coolingDown then `{math.max(1, math.ceil(remaining))}` else readyLaunchText

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

	local overlayGui, authoredViewport, authoredMapUi = resolveTargetingUi()
	if overlayGui == nil or authoredViewport == nil or authoredMapUi == nil then
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

	local worldModel, camera = resolveAuthoredOverview(authoredViewport)
	if worldModel == nil or camera == nil then
		return
	end
	updateAuthoredOwnership(authoredMapUi)

	targetMarkerGui = markerGui
	overview = authoredViewport
	overviewWorld = worldModel
	overviewCamera = camera
	targetIconHolder = iconHolder
	targetIcon = icon
	targetDebugBox = debugBox
	targeting = true
	awaitingServer = false
	playingAcceptedPlop = false
	pendingSelection = nil
	setHint("Choose anywhere on the map")
	markerGui.Enabled = true
	overlayGui.Enabled = true
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
	local uiInstance = playerGui:WaitForChild("DropLaunchUI", WAIT_TIMEOUT)
	if uiInstance == nil or not uiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.DropLaunchUI did not appear -- launch control disabled")
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
	activatedConnection = button.Activated:Connect(beginTargeting)
	updateLaunchCooldownDisplay()
end

local function watchPlayerGui()
	local playerGui = player:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child)
		if not child:IsA("ScreenGui") then
			return
		end
		if child.Name == "DropLaunchUI" then
			LaunchController.cancelTargeting()
			dropLaunchUi = nil
			launchButton = nil
			launchButtonLabel = nil
			launchButtonGradient = nil
			launchButtonIcon = nil
			readyLaunchGradient = nil
			task.spawn(bindLaunchButton)
		elseif child.Name == "LaunchTargetingUI" then
			LaunchController.cancelTargeting()
			targetingGui = nil
			hintText = nil
			hintRestPosition = nil
			connectedCancelButton = nil
			if cancelActivatedConnection ~= nil then
				cancelActivatedConnection:Disconnect()
				cancelActivatedConnection = nil
			end
			child.Enabled = false
			task.spawn(function()
				local authoredGui = resolveTargetingUi()
				if authoredGui ~= nil then
					authoredGui.Enabled = false
				end
			end)
		elseif child.Name == "LaunchTargetMarkerUI" then
			LaunchController.cancelTargeting()
			targetMarkerGui = nil
			targetIconHolder = nil
			targetIcon = nil
			targetDebugBox = nil
			child.Enabled = false
		end
	end)

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
	log.info("ready (viewport launch targeting)")
end

return LaunchController
