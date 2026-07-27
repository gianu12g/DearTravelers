--!strict
--[[
	Real-camera overview takeover for launch targeting. Takes
	Workspace.CurrentCamera over, tweening it to a computed top-down overview
	pose while active and back to wherever the player's camera actually was on
	every exit path.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.Parent.UI.Motion)

local log = Log.new("LaunchController")

local CAMERA_TAKEOVER_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CAMERA_RESTORE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Floor (and fallback, if the AABB comes out empty/degenerate) for the
-- computed overview height in resolveOverviewPose.
local FALLBACK_OVERVIEW_HEIGHT = 350
-- Fit margin applied to the computed overview height: 1.0 = map exactly
-- fills the tighter screen axis; raise to zoom out further. Hand-tuned in
-- Studio to put the camera at ~430 studs on a 16:9 screen at FOV 70.
local OVERVIEW_FIT_MARGIN = 1.325

local Camera = {}

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
function Camera.takeOverCamera(overrideSource: Instance?, onPositioned: (() -> ())?)
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
function Camera.releaseCameraOverview()
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

return Camera
