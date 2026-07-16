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

-- Transient motion factors, keyed by the same UIScale. Kept apart from .Scale so
-- that this module stays the only writer of that property: a transition and a
-- viewport change have to COMPOSE, and two systems assigning one property
-- compose by whoever ran last. That is how a menu ends up stuck at 0.92 because
-- the player resized the window while it was opening.
local multipliers: { [UIScale]: number } = {}

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
		uiScale.Scale = scale * (multipliers[uiScale] or 1)
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
		multipliers[uiScale] = nil
	end)

	uiScale.Scale = Scaling.compute(currentViewport()) * (multipliers[uiScale] or 1)
	return uiScale
end

--[[
	Multiplies a transient factor into the responsive scale -- an open
	transition, a hover pop, a screen shake. Pass 1 to clear it.

	Callers must not assign UIScale.Scale directly. This module owns it; the
	multiplier is how you get a say without racing a viewport change.
]]
function Scaling.setMultiplier(uiScale: UIScale, multiplier: number)
	multipliers[uiScale] = if multiplier == 1 then nil else multiplier
	uiScale.Scale = Scaling.compute(currentViewport()) * multiplier
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
