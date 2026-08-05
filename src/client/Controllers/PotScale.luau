--!strict
--[[
	Tiny piece of state shared between SquishyPotController (writer) and
	MushController (reader) so the pot swell and the mush squash can both move
	the same VisualWeld C0/Size values without fighting over who owns them.

	SquishyPotController publishes the live-eased pot scale for every root it
	tracks, every time that scale changes -- including while a squash is
	running (see its header). MushController reads it every frame a squash is
	active and composes it with the squash's own alpha (see MushController's
	composeWeld), instead of freezing the pot at whatever it was when the
	squash session started.

	Not a *Controller/*Service -- Loader.isLifecycleModule ignores plain
	modules like this one, so it is required directly by both callers instead
	of participating in Init/Start.
]]

local PotScale = {}

local applied: { [BasePart]: number } = {}

--[[
	The pot swell always grows up from the pad the squishy sits on, never from
	centre -- see SquishyPotController.captureRoot. Defined once here, rather
	than copied, so both controllers compose around the identical anchor.
]]
function PotScale.anchorFor(root: BasePart): Vector3
	return Vector3.new(0, -root.Size.Y / 2, 0)
end

function PotScale.set(root: BasePart, scale: number)
	applied[root] = scale
end

function PotScale.clear(root: BasePart)
	applied[root] = nil
end

-- Defaults to 1 (authored size, no swell) for any root SquishyPotController
-- has not published a value for yet.
function PotScale.get(root: BasePart): number
	return applied[root] or 1
end

return PotScale
