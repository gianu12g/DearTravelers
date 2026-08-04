--!strict
--[[
	Scale/beam bookkeeping for one in-flight LaunchState. Every function here
	is a pure function of the `launch: LaunchState` it is handed -- no
	module-level state -- so both Launch (the orchestration) and Damage (a
	mid-flight kill) can call these without depending on each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local LaunchBeamRuntime = require(ReplicatedStorage.Shared.LaunchBeamRuntime)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local Types = require(script.Parent.Types)

local log = Log.new("MergeService")

local LaunchEffects = {}

function LaunchEffects.destroyLaunchBeams(launch: Types.LaunchState)
	local handle = launch.beams
	launch.beams = nil
	LaunchBeamRuntime.destroy(handle)
end

--[[
	Attaches the falling-beam cone to a launch that is about to start
	descending. This runs at the top of the fall rather than at the drop
	teleport, so the beams do not sit under the projectile through the spawn
	squish.

	The anchor is the artwork's own beam attachment, replayed against the
	already-scaled projectile: MergeObjectVisuals hands back an offset from the
	visual's bottom-center, and attach guarantees that bottom-center is the
	root's bottom plane. The offset is scaled with the projectile because the
	whole visual is -- the attachment marks a spot on the model, and that spot
	is launch.sizeMultiplier further from center once the model is giant.
	The beam geometry itself is left at its authored size: it is art-directed
	against a launch-scaled squishy, not against the pad-sized one.

	Silently does nothing for a tier whose artwork has no beam attachment yet --
	that tier just launches without beams.

	`tier` arrives already sanitized from runLaunch; sanitizeTier itself is
	declared further down this file and is not in scope here.
]]
function LaunchEffects.attachLaunchBeams(launch: Types.LaunchState, tier: number)
	local template = launch.beamTemplate
	if template == nil or launch.part.Parent == nil then
		return
	end

	local anchorOffset = MergeObjectVisuals.getBeamAnchorOffset(tier)
	if anchorOffset == nil then
		return
	end
	local bottomCenter = Vector3.new(0, -launch.part.Size.Y / 2, 0)
	local localAnchor = bottomCenter + anchorOffset * launch.sizeMultiplier

	local ok, err = xpcall(function()
		launch.beams = LaunchBeamRuntime.attach(launch.part, template, localAnchor)
	end, debug.traceback)

	if not ok then
		LaunchEffects.destroyLaunchBeams(launch)
		log.warn(`launch beams could not be attached: {err}`)
	end
end

--[[
	Scales `launch.part` (already teleported to dropStart by launchCarried)
	and every cosmetic child up by `launch.sizeMultiplier` -- this tier's own
	LaunchSize override, or the MergeConfig default -- so the dropped squishy
	reads as a looming threat over the landing base.
	Records every original value on `launch.scale` first so restoreLaunchScale
	can undo this exactly later, no matter what the spawn/impact squash
	animations do to these same Size/C0/StudsOffsetWorldSpace values while the launch
	plays out.
]]
function LaunchEffects.applyLaunchScale(launch: Types.LaunchState)
	local part = launch.part
	local multiplier = launch.sizeMultiplier

	local visuals: { Types.LaunchVisualScale } = {}
	local visualRoot = part:FindFirstChild("Visual")
	if visualRoot ~= nil then
		local candidates = if visualRoot:IsA("BasePart") then { visualRoot } else visualRoot:GetDescendants()
		for _, candidate in candidates do
			if not candidate:IsA("BasePart") then
				continue
			end
			local weld = candidate:FindFirstChild("VisualWeld")
			if weld == nil or not weld:IsA("Weld") then
				continue
			end
			table.insert(visuals, {
				part = candidate,
				weld = weld,
				size = candidate.Size,
				c0 = weld.C0,
				transparency = candidate.Transparency,
			})
		end
	end

	local rawIncomeLabel = part:FindFirstChild("IncomeLabel")
	local incomeLabel: BillboardGui? = if rawIncomeLabel ~= nil and rawIncomeLabel:IsA("BillboardGui")
		then rawIncomeLabel
		else nil
	local incomeLabelOffset: Vector3? = if incomeLabel ~= nil then incomeLabel.StudsOffsetWorldSpace else nil
	local incomeLabelEnabled: boolean? = if incomeLabel ~= nil then incomeLabel.Enabled else nil

	launch.scale = {
		rootSize = part.Size,
		rootTransparency = part.Transparency,
		visuals = visuals,
		incomeLabel = incomeLabel,
		incomeLabelOffset = incomeLabelOffset,
		incomeLabelEnabled = incomeLabelEnabled,
	}

	part.Size = part.Size * multiplier
	for _, state in visuals do
		if state.part.Parent ~= nil and state.weld.Parent ~= nil then
			state.part.Size = state.size * multiplier
			state.weld.C0 = CFrame.new(state.c0.Position * multiplier) * state.c0.Rotation
		end
	end
	if incomeLabel ~= nil and incomeLabelOffset ~= nil then
		incomeLabel.StudsOffsetWorldSpace = incomeLabelOffset * multiplier
	end
end

--[[
	Restores every value applyLaunchScale recorded, straight from that
	baseline -- not from wherever a squash animation left things -- so this is
	safe to call after a normal landing, a cancelled launch, or a squishy that
	died mid-flight, regardless of which squash phase (if any) was running
	when the launch ended. Every write is guarded by Parent ~= nil since the
	part or its cosmetic children may already be gone by the time this runs.
]]
function LaunchEffects.restoreLaunchScale(launch: Types.LaunchState)
	local scale = launch.scale
	if scale == nil then
		return
	end

	local part = launch.part
	if part.Parent ~= nil then
		part.Size = scale.rootSize
		part.Transparency = scale.rootTransparency
	end
	for _, state in scale.visuals do
		if state.part.Parent ~= nil and state.weld.Parent ~= nil then
			state.part.Size = state.size
			state.weld.C0 = state.c0
			state.part.Transparency = state.transparency
		end
	end

	local incomeLabel = scale.incomeLabel
	local offset = scale.incomeLabelOffset
	local enabled = scale.incomeLabelEnabled
	if incomeLabel ~= nil and incomeLabel.Parent ~= nil then
		if offset ~= nil then
			incomeLabel.StudsOffsetWorldSpace = offset
		end
		if enabled ~= nil then
			incomeLabel.Enabled = enabled
		end
	end
end

-- Hides only the temporary projectile clone's presentation. Its root and
-- launch state stay alive until finishLaunch restores the captured scale and
-- destroys the clone; the real owned squishy never leaves the player's hand.
function LaunchEffects.hideLaunchVisual(launch: Types.LaunchState)
	local scale = launch.scale
	if scale == nil then
		return
	end

	local part = launch.part
	if part.Parent ~= nil then
		part.Transparency = 1
	end
	for _, state in scale.visuals do
		if state.part.Parent ~= nil then
			state.part.Transparency = 1
		end
	end

	local incomeLabel = scale.incomeLabel
	if incomeLabel ~= nil and incomeLabel.Parent ~= nil then
		incomeLabel.Enabled = false
	end
end

return LaunchEffects
