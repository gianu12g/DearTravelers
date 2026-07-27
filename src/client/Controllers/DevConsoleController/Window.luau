--!strict
--[[
	The window rect (position + size, in pixels) and the drag/resize gesture
	that mutates it. This is the only piece of layout in the console that is
	state -- everything else inside the window is laid out relative to it.
]]

-- Window rect bounds. MIN is "every control still reachable"; MAX exists so a
-- 4K screen doesn't get a console the size of a wall.
local MIN_WINDOW_SIZE = Vector2.new(380, 320)
local MAX_WINDOW_SIZE = Vector2.new(900, 900)
local INITIAL_WINDOW_FRACTION = Vector2.new(0.3, 0.6)

local Window = {}

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

-- Set once buildUI creates them, cleared on cleanup. Held here rather than
-- read afresh each call because Window owns the rect math that needs them.
local screenGuiRef: ScreenGui? = nil
local rootRef: Frame? = nil

function Window.setFrames(gui: ScreenGui, frame: Frame)
	screenGuiRef = gui
	rootRef = frame
end

function Window.reset()
	dragMode = "None"
	dragTouch = nil
	screenGuiRef = nil
	rootRef = nil
end

function Window.getSize(): Vector2
	return windowSize
end

function Window.viewportSize(): Vector2
	local gui = screenGuiRef
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
	local frame = rootRef
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
function Window.clampWindow()
	local screen = Window.viewportSize()

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

--[[
	Opening rect: a fraction of the viewport (so it is proportionate on any
	screen) rather than an authored pixel size, centred, then clamped.
]]
function Window.initializeRect()
	local screen = Window.viewportSize()
	windowSize =
		Vector2.new(math.round(screen.X * INITIAL_WINDOW_FRACTION.X), math.round(screen.Y * INITIAL_WINDOW_FRACTION.Y))
	windowPosition = Vector2.new(math.round((screen.X - windowSize.X) / 2), math.round((screen.Y - windowSize.Y) / 2))
	Window.clampWindow()
end

function Window.isPointerPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

function Window.isPointerMove(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

function Window.beginDrag(mode: "Move" | "Resize", input: InputObject)
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
function Window.updateDrag(input: InputObject)
	if dragMode == "None" or not Window.isPointerMove(input) then
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
	Window.clampWindow()
end

function Window.endDrag(input: InputObject)
	if dragMode ~= "None" and Window.isPointerPress(input) then
		dragMode = "None"
		dragTouch = nil
	end
end

return Window
