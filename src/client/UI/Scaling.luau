--!strict
--[[
	Global UI scaling off a reference resolution.

	Author every GUI at 1920x1080 in OFFSET, then let one UIScale per ScreenGui
	root do the rest. This is deliberately not per-element scale sizing:
	UDim2.fromScale does not scale text (you need TextScaled, which fights
	UITextSizeConstraint and gives inconsistent type sizes across panels), and
	padding, corners and strokes all drift independently of each other. One
	UIScale scales everything uniformly, so a panel looks identical at 1080p
	and 1440p.
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local REFERENCE = Vector2.new(1920, 1080)

-- Floor stops phone UI becoming unreadable; ceiling stops 4K rendering a
-- cartoonishly large HUD.
local MIN_SCALE = 0.55
local MAX_SCALE = 1.6

-- Phones are held closer but have far less angular area for a given scale, so
-- the raw ratio under-sizes touch targets below the ~44px minimum.
local TOUCH_MULTIPLIER = 1.15

local Scaling = {}

local tracked: { [UIScale]: true } = {}

function Scaling.compute(viewport: Vector2): number
	-- min() of both axes so content overflows on neither.
	local raw = math.min(viewport.X / REFERENCE.X, viewport.Y / REFERENCE.Y)

	if UserInputService.TouchEnabled then
		raw *= TOUCH_MULTIPLIER
	end

	return math.clamp(raw, MIN_SCALE, MAX_SCALE)
end

local function currentViewport(): Vector2
	local camera = Workspace.CurrentCamera
	return if camera then camera.ViewportSize else REFERENCE
end

local function applyAll()
	local scale = Scaling.compute(currentViewport())
	for uiScale in tracked do
		uiScale.Scale = scale
	end
end

--[[
	Attaches a UIScale to `root` and keeps it in sync with the viewport.
	Returns the UIScale so callers can inspect it; they rarely need to.
]]
function Scaling.attach(root: GuiObject): UIScale
	local existing = root:FindFirstChildOfClass("UIScale")
	local uiScale = existing or Instance.new("UIScale")
	uiScale.Parent = root

	tracked[uiScale] = true
	uiScale.Destroying:Connect(function()
		tracked[uiScale] = nil
	end)

	uiScale.Scale = Scaling.compute(currentViewport())
	return uiScale
end

function Scaling.getReference(): Vector2
	return REFERENCE
end

local function bindViewport()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyAll)
	applyAll()
end

bindViewport()
-- CurrentCamera can be replaced (spectating, cutscenes); rebind when it is.
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewport)

return Scaling
