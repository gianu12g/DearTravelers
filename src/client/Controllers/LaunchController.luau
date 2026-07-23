--!strict
--[[
	Turns DropLaunchUI.CarryActions.C.Launch into a full-screen ViewportFrame
	map. The live gameplay camera never moves: once a location is accepted, the
	overview disappears and the player is already back in their normal view to
	watch the squishy fly.

	The viewport contains a reduced-detail clone of the authored map. Each 3x3
	KeyPack is represented by one color/material-matched tile, reducing the live
	map's 7,200 key meshes to 800 overview tiles without replacing it with generic
	base rectangles. The camera keeps one world-aligned orientation for every
	player, regardless of which base they own. Preview geometry stays in original
	world coordinates, so screen clicks send the correct world X/Z point for
	MergeService to validate.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10
local TARGET_FOV = 25
local MAP_PADDING = 35
local RAY_DISTANCE = 5000
local VIEWPORT_Z_INDEX = 40
-- Orders the selected-target icon above its developer-only radius box inside
-- the dedicated marker gui. Beating every other developer ScreenGui is the
-- display order's job, not this ZIndex.
local TARGET_ICON_Z_INDEX = 1000
local TARGET_MARKER_DISPLAY_ORDER = 10000
local TARGET_ICON_ASSET = `rbxassetid://{Images.LaunchTarget}`
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
-- The instruction and cancel controls live in this strip instead of covering
-- the map. Keep this in pixels because the controls themselves have a fixed
-- pixel height and should reserve the same amount at every resolution.
local TARGETING_HEADER_HEIGHT = 88
local LAUNCH_COOLDOWN_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 95, 95)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 25, 25)),
})
local SCENERY_ROOT_NAMES = {
	Assets = true,
	Baseplate = true,
	Leaderboards = true,
	["Nature Asset Pack - Studs Style"] = true,
	SpawnLocation = true,
	["Studded fountain"] = true,
	StudParts = true,
}

type MapBounds = {
	minimum: Vector3,
	maximum: Vector3,
}

type TargetSelection = {
	worldX: number,
	worldZ: number,
	screenPosition: Vector2,
	radiusDiameter: number,
}

type MapLabel = {
	position: Vector3,
	text: string,
	owner: Player?,
	isLocalPlayerBase: boolean,
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

local function getMapLayout(): Instance?
	return Workspace:FindFirstChild("MapLayout")
end

local function radiusDebugEnabled(): boolean
	return player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
end

local function includePartBounds(minimum: Vector3, maximum: Vector3, part: BasePart): (Vector3, Vector3)
	local half = part.Size / 2
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
				minimum = Vector3.new(
					math.min(minimum.X, corner.X),
					math.min(minimum.Y, corner.Y),
					math.min(minimum.Z, corner.Z)
				)
				maximum = Vector3.new(
					math.max(maximum.X, corner.X),
					math.max(maximum.Y, corner.Y),
					math.max(maximum.Z, corner.Z)
				)
			end
		end
	end
	return minimum, maximum
end

local function calculateMapBounds(mapLayout: Instance): MapBounds?
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false

	local centerMap = mapLayout:FindFirstChild("CenterMap")
	if centerMap ~= nil and centerMap:IsA("BasePart") then
		found = true
		minimum, maximum = includePartBounds(minimum, maximum, centerMap)
	end

	local basesFolder = mapLayout:FindFirstChild("Bases")
	if basesFolder ~= nil then
		for _, child in basesFolder:GetChildren() do
			if child:IsA("BasePart") and string.match(child.Name, "^Base%d+$") ~= nil then
				found = true
				minimum, maximum = includePartBounds(minimum, maximum, child)
			end
		end
	end

	return if found then { minimum = minimum, maximum = maximum } else nil
end

local function createPreviewPart(source: BasePart, parent: Instance, name: string, transparency: number?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = source.Size
	part.CFrame = source.CFrame
	part.Color = source.Color
	part.Material = source.Material
	part.Transparency = transparency or source.Transparency
	part.Reflectance = source.Reflectance
	if source:IsA("Part") then
		part.Shape = source.Shape
		part.TopSurface = source.TopSurface
		part.BottomSurface = source.BottomSurface
		part.LeftSurface = source.LeftSurface
		part.RightSurface = source.RightSurface
		part.FrontSurface = source.FrontSurface
		part.BackSurface = source.BackSurface
	else
		part.Shape = Enum.PartType.Block
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function createMapLabel(
	parent: ViewportFrame,
	camera: Camera,
	position: Vector3,
	text: string,
	owner: Player?,
	isLocalPlayerBase: boolean
)
	local cameraPoint = camera.CFrame:PointToObjectSpace(position)
	local depth = -cameraPoint.Z
	if depth <= 0 then
		return
	end
	local size = parent.AbsoluteSize
	local aspect = if size.Y > 0 then size.X / size.Y else 16 / 9
	local tangent = math.tan(math.rad(camera.FieldOfView) / 2)
	local normalizedX = cameraPoint.X / (depth * tangent * aspect)
	local normalizedY = cameraPoint.Y / (depth * tangent)
	local xScale = (normalizedX + 1) / 2
	local yScale = (1 - normalizedY) / 2

	if owner ~= nil then
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "BaseOwnerAvatar"
		avatar.AnchorPoint = Vector2.new(0.5, 0.5)
		avatar.Position = UDim2.fromScale(xScale, yScale)
		avatar.Size = UDim2.fromOffset(62, 62)
		avatar.BackgroundColor3 = Color3.fromRGB(53, 42, 67)
		avatar.BackgroundTransparency = 0.04
		avatar.Image = `rbxthumb://type=AvatarHeadShot&id={owner.UserId}&w=150&h=150`
		avatar.ScaleType = Enum.ScaleType.Crop
		avatar.ZIndex = VIEWPORT_Z_INDEX + 1
		avatar.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = avatar

		local stroke = Instance.new("UIStroke")
		stroke.Color = if isLocalPlayerBase then Color3.fromRGB(255, 232, 92) else Color3.fromRGB(255, 244, 250)
		stroke.Thickness = 3
		stroke.Transparency = 0.04
		stroke.Parent = avatar

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "BaseOwnerName"
		nameLabel.AnchorPoint = Vector2.new(0.5, 0)
		nameLabel.Position = UDim2.new(xScale, 0, yScale, 34)
		nameLabel.Size = UDim2.fromOffset(116, 24)
		nameLabel.BackgroundTransparency = 1
		nameLabel.BorderSizePixel = 0
		nameLabel.Font = Enum.Font.FredokaOne
		nameLabel.Text = owner.DisplayName
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.TextScaled = true
		nameLabel.TextStrokeTransparency = 1
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.ZIndex = VIEWPORT_Z_INDEX + 2
		nameLabel.Parent = parent

		local nameStroke = Instance.new("UIStroke")
		nameStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		nameStroke.Color = Color3.new(0, 0, 0)
		nameStroke.Thickness = 2.5
		nameStroke.Transparency = 0
		nameStroke.Parent = nameLabel

		local namePadding = Instance.new("UIPadding")
		namePadding.PaddingLeft = UDim.new(0, 6)
		namePadding.PaddingRight = UDim.new(0, 6)
		namePadding.Parent = nameLabel

		return
	end

	local label = Instance.new("TextLabel")
	label.Name = text .. "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(xScale, yScale)
	label.Size = UDim2.fromOffset(96, 26)
	label.BackgroundColor3 = Color3.fromRGB(53, 42, 67)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(69, 42, 62)
	label.TextStrokeTransparency = 0.2
	label.ZIndex = VIEWPORT_Z_INDEX + 1
	label.Parent = parent
end

local function averageKeyPackColor(parts: { BasePart }): Color3
	local red = 0
	local green = 0
	local blue = 0
	for _, part in parts do
		red += part.Color.R
		green += part.Color.G
		blue += part.Color.B
	end
	local count = math.max(#parts, 1)
	return Color3.new(red / count, green / count, blue / count)
end

-- The authored bases use 100 KeyPack folders containing a 3x3 group each.
-- One overview tile per pack retains their real arrangement and average theme
-- color while keeping this transient viewport comfortably below 1,000 parts.
local function addKeycapPackPreviews(base: BasePart, worldModel: WorldModel)
	local keycaps = base:FindFirstChild("KeyCaps")
	if keycaps == nil then
		return
	end

	for _, pack in keycaps:GetChildren() do
		local keys: { BasePart } = {}
		for _, child in pack:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(keys, child)
			end
		end
		local reference = keys[1]
		if reference == nil then
			continue
		end

		local rotation = reference.CFrame.Rotation
		local minimum = Vector3.new(math.huge, math.huge, math.huge)
		local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, key in keys do
			local localPosition = rotation:PointToObjectSpace(key.Position)
			local halfSize = key.Size / 2
			minimum = Vector3.new(
				math.min(minimum.X, localPosition.X - halfSize.X),
				math.min(minimum.Y, localPosition.Y - halfSize.Y),
				math.min(minimum.Z, localPosition.Z - halfSize.Z)
			)
			maximum = Vector3.new(
				math.max(maximum.X, localPosition.X + halfSize.X),
				math.max(maximum.Y, localPosition.Y + halfSize.Y),
				math.max(maximum.Z, localPosition.Z + halfSize.Z)
			)
		end

		local localCenter = (minimum + maximum) / 2
		local preview = Instance.new("Part")
		preview.Name = "KeyPackPreview"
		preview.Size = maximum - minimum - Vector3.new(0.18, 0, 0.18)
		preview.CFrame = CFrame.new(rotation:PointToWorldSpace(localCenter)) * rotation
		preview.Color = averageKeyPackColor(keys)
		preview.Material = reference.Material
		preview.Transparency = reference.Transparency
		preview.Reflectance = reference.Reflectance
		preview.Anchored = true
		preview.CanCollide = false
		preview.CanTouch = false
		-- The targeting ray must land on the visible keycap surface rather
		-- than the lower base slab, or the cursor ring renders underneath it.
		preview.CanQuery = true
		preview.CastShadow = false
		preview.TopSurface = Enum.SurfaceType.Smooth
		preview.BottomSurface = Enum.SurfaceType.Smooth
		preview.Parent = worldModel
	end
end

-- Condensing each 3x3 pack leaves tiny visual seams between overview tiles.
-- A ray that lands in one of those seams would otherwise hit the base slab
-- below keycap height and bury the wide target ring under adjacent tiles.
local function addBaseTargetSurface(base: BasePart, worldModel: WorldModel)
	local highestY = base.Position.Y + base.Size.Y / 2
	local keycaps = base:FindFirstChild("KeyCaps")
	if keycaps ~= nil then
		for _, descendant in keycaps:GetDescendants() do
			if not descendant:IsA("BasePart") then
				continue
			end
			local cframe = descendant.CFrame
			local size = descendant.Size
			local verticalHalfExtent = math.abs(cframe.RightVector.Y) * size.X / 2
				+ math.abs(cframe.UpVector.Y) * size.Y / 2
				+ math.abs(cframe.LookVector.Y) * size.Z / 2
			highestY = math.max(highestY, descendant.Position.Y + verticalHalfExtent)
		end
	end

	local surface = Instance.new("Part")
	surface.Name = base.Name .. "TargetSurface"
	surface.Size = Vector3.new(base.Size.X, 0.08, base.Size.Z)
	surface.CFrame = CFrame.new(base.Position.X, highestY + 0.05, base.Position.Z) * base.CFrame.Rotation
	surface.Transparency = 1
	surface.Anchored = true
	surface.CanCollide = false
	surface.CanTouch = false
	surface.CanQuery = true
	surface.CastShadow = false
	surface.Parent = worldModel
end

local function cloneVisualPart(source: BasePart, parent: Instance, name: string, keepSurfaceGuis: boolean): BasePart
	local clone = source:Clone()
	for _, child in clone:GetChildren() do
		local keep = child:IsA("DataModelMesh")
			or child:IsA("SurfaceAppearance")
			or child:IsA("Decal")
			or child:IsA("Texture")
			or (keepSurfaceGuis and child:IsA("SurfaceGui"))
		if not keep then
			child:Destroy()
		end
	end
	clone.Name = name
	clone.CFrame = source.CFrame
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanTouch = false
	-- Visible scenery participates in preview-only raycasts so the cursor
	-- always rides above what the player sees. Only X/Z is sent to the server.
	clone.CanQuery = true
	clone.CastShadow = false
	clone.Parent = parent
	return clone
end

local function cloneSquishyPreview(source: BasePart, worldModel: WorldModel)
	cloneVisualPart(source, worldModel, "SquishyPreview", false)
end

local function addCurrentSquishyPreviews(basesFolder: Instance, worldModel: WorldModel)
	for _, base in basesFolder:GetChildren() do
		local objects = base:FindFirstChild("MergeObjects")
		if objects == nil then
			continue
		end
		for _, child in objects:GetChildren() do
			if not child:IsA("BasePart") or child.Name ~= "MergeObject" then
				continue
			end
			cloneSquishyPreview(child, worldModel)
		end
	end
end

-- MapLayout contains the targeting geometry, while the playable place keeps
-- grass, trees, fountain, signs, and other authored scenery in neighboring
-- Workspace roots. Clone their visible parts individually so scripts,
-- constraints, prompts, and nested models cannot run inside the WorldModel.
local function addWorldSceneryPreviews(bounds: MapBounds, worldModel: WorldModel)
	local horizontalPadding = MAP_PADDING * 2
	local function isInsideOverview(part: BasePart): boolean
		return part.Position.X >= bounds.minimum.X - horizontalPadding
			and part.Position.X <= bounds.maximum.X + horizontalPadding
			and part.Position.Z >= bounds.minimum.Z - horizontalPadding
			and part.Position.Z <= bounds.maximum.Z + horizontalPadding
	end

	for _, root in Workspace:GetChildren() do
		if SCENERY_ROOT_NAMES[root.Name] ~= true then
			continue
		end

		if root:IsA("BasePart") and root.Transparency < 1 and isInsideOverview(root) then
			cloneVisualPart(root, worldModel, root.Name .. "Preview", true)
		end
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Transparency < 1 and isInsideOverview(descendant) then
				cloneVisualPart(descendant, worldModel, descendant.Name .. "Preview", true)
			end
		end
	end
end

local function addPlayerBaseOutline(base: BasePart, worldModel: WorldModel)
	local color = Color3.fromRGB(255, 232, 92)
	local width = 1.5
	local height = base.Size.Y / 2 + 3
	local expandedX = base.Size.X + 8
	local expandedZ = base.Size.Z + 8
	local function edge(name: string, size: Vector3, offset: Vector3)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = base.CFrame * CFrame.new(offset)
		part.Color = color
		part.Material = Enum.Material.Neon
		part.Transparency = 0.1
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Parent = worldModel
	end

	edge("YourBaseTop", Vector3.new(expandedX, 0.35, width), Vector3.new(0, height, -expandedZ / 2))
	edge("YourBaseBottom", Vector3.new(expandedX, 0.35, width), Vector3.new(0, height, expandedZ / 2))
	edge("YourBaseLeft", Vector3.new(width, 0.35, expandedZ), Vector3.new(-expandedX / 2, height, 0))
	edge("YourBaseRight", Vector3.new(width, 0.35, expandedZ), Vector3.new(expandedX / 2, height, 0))
end

local function setOverviewCamera(camera: Camera, bounds: MapBounds, mapCenter: Vector3)
	-- Keep the authored map's north edge at the top for everyone. In particular,
	-- do not derive this from AssignedBase: base assignment must only change the
	-- ownership marker, never the player's view of the map.
	local screenUp = Vector3.new(0, 0, -1)
	local screenRight = screenUp:Cross(Vector3.yAxis).Unit
	local halfWidth = 0
	local halfDepth = 0
	for x = -1, 1, 2 do
		for z = -1, 1, 2 do
			local corner = Vector3.new(
				if x < 0 then bounds.minimum.X else bounds.maximum.X,
				mapCenter.Y,
				if z < 0 then bounds.minimum.Z else bounds.maximum.Z
			)
			local offset = corner - mapCenter
			halfWidth = math.max(halfWidth, math.abs(offset:Dot(screenRight)))
			halfDepth = math.max(halfDepth, math.abs(offset:Dot(screenUp)))
		end
	end
	halfWidth += MAP_PADDING
	halfDepth += MAP_PADDING
	local liveCamera = Workspace.CurrentCamera
	local viewportSize = if liveCamera ~= nil
		then Vector2.new(liveCamera.ViewportSize.X, math.max(1, liveCamera.ViewportSize.Y - TARGETING_HEADER_HEIGHT))
		else Vector2.new(16, 9)
	local aspect = if viewportSize.Y > 0 then viewportSize.X / viewportSize.Y else 16 / 9
	local verticalRadians = math.rad(TARGET_FOV)
	local horizontalRadians = 2 * math.atan(math.tan(verticalRadians / 2) * aspect)
	local heightForDepth = halfDepth / math.tan(verticalRadians / 2)
	local heightForWidth = halfWidth / math.tan(horizontalRadians / 2)
	local height = math.max(heightForDepth, heightForWidth, 80)
	local lookAt = Vector3.new(mapCenter.X, bounds.maximum.Y, mapCenter.Z)

	camera.FieldOfView = TARGET_FOV
	camera.CFrame = CFrame.lookAt(lookAt + Vector3.new(0, height, 0), lookAt, screenUp)
	camera.Focus = CFrame.new(lookAt)
end

local function createOverview(
	viewport: ViewportFrame,
	markerGui: ScreenGui,
	mapLayout: Instance,
	bounds: MapBounds
): (ViewportFrame, WorldModel, Camera, Frame, ImageLabel, Frame)
	viewport.CurrentCamera = nil
	for _, child in viewport:GetChildren() do
		child:Destroy()
	end

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "MapPreview"
	worldModel.Parent = viewport
	local labels: { MapLabel } = {}
	addWorldSceneryPreviews(bounds, worldModel)

	local centerMap = mapLayout:FindFirstChild("CenterMap")
	local mapCenter = (bounds.minimum + bounds.maximum) / 2
	if centerMap ~= nil and centerMap:IsA("BasePart") then
		createPreviewPart(centerMap, worldModel, "CenterMap")
		mapCenter = centerMap.Position
		table.insert(labels, {
			position = centerMap.Position,
			text = "CENTER",
			owner = nil,
			isLocalPlayerBase = false,
		})
	end

	local basesFolder = mapLayout:FindFirstChild("Bases")
	local playerBase: BasePart? = nil
	if basesFolder ~= nil then
		local assignedBase = player:GetAttribute("AssignedBase")
		if typeof(assignedBase) == "string" then
			local assigned = basesFolder:FindFirstChild(assignedBase)
			if assigned ~= nil and assigned:IsA("BasePart") then
				playerBase = assigned
			end
		end

		for _, child in basesFolder:GetChildren() do
			if not child:IsA("BasePart") or string.match(child.Name, "^Base%d+$") == nil then
				continue
			end
			createPreviewPart(child, worldModel, child.Name)
			addKeycapPackPreviews(child, worldModel)
			addBaseTargetSurface(child, worldModel)
			local isLocalPlayerBase = child == playerBase
			local owner: Player? = nil
			local ownerUserId = child:GetAttribute("OwnerUserId")
			if typeof(ownerUserId) == "number" then
				owner = Players:GetPlayerByUserId(ownerUserId)
			end
			-- AssignedBase reaches the local client independently from the base
			-- attribute. Preserve the local portrait if those replications land on
			-- adjacent frames while the targeting UI is being created.
			if isLocalPlayerBase then
				owner = player
			end
			table.insert(labels, {
				position = child.Position,
				text = string.upper(child.Name),
				owner = owner,
				isLocalPlayerBase = isLocalPlayerBase,
			})
		end
		addCurrentSquishyPreviews(basesFolder, worldModel)
		if playerBase ~= nil then
			addPlayerBaseOutline(playerBase, worldModel)
		end
	end

	-- This invisible floor is queryable but not rendered. It deliberately spans
	-- gaps between authored map parts so every point in the overview can launch.
	local targetPlane = Instance.new("Part")
	targetPlane.Name = "TargetPlane"
	targetPlane.Size = Vector3.new(bounds.maximum.X - bounds.minimum.X, 0.1, bounds.maximum.Z - bounds.minimum.Z)
	targetPlane.CFrame = CFrame.new(
		(bounds.minimum.X + bounds.maximum.X) / 2,
		bounds.minimum.Y - 0.1,
		(bounds.minimum.Z + bounds.maximum.Z) / 2
	)
	targetPlane.Transparency = 1
	targetPlane.Anchored = true
	targetPlane.CanCollide = false
	targetPlane.CanTouch = false
	targetPlane.CanQuery = true
	targetPlane.Parent = worldModel

	local camera = Instance.new("Camera")
	camera.Name = "LaunchMapCamera"
	camera.Parent = viewport
	setOverviewCamera(camera, bounds, mapCenter)
	viewport.CurrentCamera = camera
	for _, label in labels do
		createMapLabel(viewport, camera, label.position, label.text, label.owner, label.isLocalPlayerBase)
	end

	-- This marker is deliberately hidden until the player commits to a point.
	-- Keeping it in a top-most ScreenGui lets the icon land at the selected map
	-- position without clipping against the ViewportFrame's bounds.
	local iconHolder = Instance.new("Frame")
	iconHolder.Name = "LaunchTargetIconHolder"
	iconHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	-- The aspect constraint derives the height from this width-relative box.
	iconHolder.Size = UDim2.fromScale(TARGET_ICON_WIDTH_SCALE, 1)
	iconHolder.BackgroundTransparency = 1
	iconHolder.BorderSizePixel = 0
	iconHolder.Visible = false
	iconHolder.ZIndex = TARGET_ICON_Z_INDEX
	iconHolder.Parent = markerGui

	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.Name = "SquareAspect"
	iconAspect.AspectRatio = 1
	iconAspect.DominantAxis = Enum.DominantAxis.Width
	iconAspect.Parent = iconHolder

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.Image = TARGET_ICON_ASSET
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = TARGET_ICON_Z_INDEX
	icon.Parent = iconHolder

	-- A square centered on the committed point exposes the exact impact diameter.
	-- This is developer-only presentation: the authenticated dev console owns the
	-- toggle, while the shared radius remains server-owned gameplay configuration.
	local debugBox = Instance.new("Frame")
	debugBox.Name = "LaunchRadiusDebugBox"
	debugBox.AnchorPoint = Vector2.new(0.5, 0.5)
	debugBox.BackgroundTransparency = 1
	debugBox.BorderSizePixel = 0
	debugBox.Visible = false
	debugBox.ZIndex = TARGET_ICON_Z_INDEX - 1
	debugBox.Parent = markerGui

	local debugStroke = Instance.new("UIStroke")
	debugStroke.Color = Color3.fromRGB(88, 255, 238)
	debugStroke.Thickness = 2
	debugStroke.Transparency = 0.05
	debugStroke.Parent = debugBox

	local debugLabel = Instance.new("TextLabel")
	debugLabel.Name = "RadiusLabel"
	debugLabel.Position = UDim2.fromOffset(4, 4)
	debugLabel.Size = UDim2.fromOffset(116, 20)
	debugLabel.BackgroundColor3 = Color3.fromRGB(12, 27, 31)
	debugLabel.BackgroundTransparency = 0.15
	debugLabel.BorderSizePixel = 0
	debugLabel.Font = Enum.Font.Code
	debugLabel.Text = `RADIUS {MergeConfig.LAUNCH_IMPACT_RADIUS} STUDS`
	debugLabel.TextColor3 = Color3.fromRGB(184, 255, 248)
	debugLabel.TextSize = 12
	debugLabel.TextXAlignment = Enum.TextXAlignment.Left
	debugLabel.ZIndex = TARGET_ICON_Z_INDEX
	debugLabel.Parent = debugBox

	local debugLabelPadding = Instance.new("UIPadding")
	debugLabelPadding.PaddingLeft = UDim.new(0, 4)
	debugLabelPadding.Parent = debugLabel

	return viewport, worldModel, camera, iconHolder, icon, debugBox
end

local function createTargetMarkerGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "LaunchTargetMarkerUI"
	gui.DisplayOrder = TARGET_MARKER_DISPLAY_ORDER
	-- selectionAt works in inset space because input.Position and the viewport's
	-- AbsolutePosition both exclude the inset. This gui must use that same space.
	gui.IgnoreGuiInset = false
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
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

local function resolveTargetingUi(): (ScreenGui?, ViewportFrame?)
	local playerGui = player:WaitForChild("PlayerGui")
	local uiInstance = playerGui:WaitForChild("LaunchTargetingUI", WAIT_TIMEOUT)
	if uiInstance == nil or not uiInstance:IsA("ScreenGui") then
		log.warn("PlayerGui.LaunchTargetingUI did not appear -- launch targeting disabled")
		return nil, nil
	end

	local viewportInstance = uiInstance:FindFirstChild("LaunchMapViewport")
	if viewportInstance == nil or not viewportInstance:IsA("ViewportFrame") then
		log.warn("LaunchTargetingUI.LaunchMapViewport is missing")
		return nil, nil
	end

	local hintInstance = uiInstance:FindFirstChild("LaunchTargetingHint")
	local backgroundInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("BG") else nil
	local labelInstance = if backgroundInstance ~= nil then backgroundInstance:FindFirstChild("TextLabel") else nil
	local cancelInstance = if hintInstance ~= nil then hintInstance:FindFirstChild("Cancel") else nil
	if labelInstance == nil or not labelInstance:IsA("TextLabel") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.BG.TextLabel is missing")
		return nil, nil
	end
	if cancelInstance == nil or not cancelInstance:IsA("TextButton") then
		log.warn("LaunchTargetingUI.LaunchTargetingHint.Cancel is missing")
		return nil, nil
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
	return uiInstance, viewportInstance
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
		local viewport = gui:FindFirstChild("LaunchMapViewport")
		if viewport ~= nil and viewport:IsA("ViewportFrame") then
			viewport.CurrentCamera = nil
			for _, child in viewport:GetChildren() do
				child:Destroy()
			end
		end
	end
	if markerGui ~= nil then
		markerGui:Destroy()
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

	local mapLayout = getMapLayout()
	local ui = dropLaunchUi
	if mapLayout == nil or ui == nil or ui.Parent == nil then
		log.warn("MapLayout or DropLaunchUI is unavailable -- launch targeting skipped")
		return
	end
	local bounds = calculateMapBounds(mapLayout)
	if bounds == nil then
		log.warn("MapLayout has no usable overview parts -- launch targeting skipped")
		return
	end

	local overlayGui, authoredViewport = resolveTargetingUi()
	if overlayGui == nil or authoredViewport == nil then
		return
	end
	overlayGui.Enabled = false

	local markerGui = createTargetMarkerGui()
	targetMarkerGui = markerGui
	local viewport, worldModel, camera, iconHolder, icon, debugBox =
		createOverview(authoredViewport, markerGui, mapLayout, bounds)
	overview = viewport
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
		end
	end)

	task.spawn(function()
		local authoredGui = resolveTargetingUi()
		if authoredGui ~= nil then
			authoredGui.Enabled = false
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
