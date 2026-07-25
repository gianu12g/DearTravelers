--!strict
--[[
	Clones the selected Assets.VFX.LaunchBeams model onto a launched squishy
	for the duration of its fall, fading the beams up from fully transparent
	to their authored Transparency.

	The authored model is a pure template: its Attachments sit under plain
	Folders, where they have no world CFrame and draw nothing. This module
	reparents every one of them onto a single invisible holder Part welded to
	the squishy, which is what actually makes the Beams render. Each Beam's
	Attachment0/Attachment1 are instance references, and cloning the whole model
	in one go preserves them, so the pairing survives the reparent without this
	module ever matching attachments up itself -- which it could not do anyway,
	since every one of them is named "Attachment".
]]

local RunService = game:GetService("RunService")

local HOLDER_NAME = "LaunchBeamAnchor"
local HOLDER_WELD_NAME = "LaunchBeamWeld"

type BeamState = {
	beam: Beam,
	-- The authored Transparency, kept because fading rebuilds the sequence from
	-- it every frame rather than from the beam's current (already faded) value.
	transparency: NumberSequence,
}

export type Handle = {
	holder: BasePart,
	beams: { BeamState },
	cancelled: boolean,
}

local LaunchBeamRuntime = {}

--[[
	Rebuilds `sequence` scaled toward fully transparent: alpha 0 puts every
	keypoint at 1 (invisible), alpha 1 returns the authored sequence verbatim.
	Envelopes scale with alpha so a faded keypoint can never push value +
	envelope outside [0, 1] and be rejected.
]]
local function fadedSequence(sequence: NumberSequence, alpha: number): NumberSequence
	local keypoints: { NumberSequenceKeypoint } = {}
	for index, keypoint in sequence.Keypoints do
		keypoints[index] =
			NumberSequenceKeypoint.new(keypoint.Time, 1 + (keypoint.Value - 1) * alpha, keypoint.Envelope * alpha)
	end
	return NumberSequence.new(keypoints)
end

local function setFade(beams: { BeamState }, alpha: number)
	for _, state in beams do
		if state.beam.Parent ~= nil then
			state.beam.Transparency = fadedSequence(state.transparency, alpha)
		end
	end
end

--[[
	Attaches a fresh clone of `template` to `root`, anchored at `anchorOffset`
	in root-local space, and starts it fully transparent -- call fadeIn to bring
	it up. The weld carries no rotation of its own, so the beams point along the
	root's axes (world up, for a launch: nothing rotates the projectile).

	Beams render with whatever Color/Texture the artwork itself authored -- the
	beam is the standalone launch cosmetic, not tinted from anything else.

	Returns nil, having cleaned up after itself, when the template contains no
	Beams.
]]
function LaunchBeamRuntime.attach(root: BasePart, template: Model, anchorOffset: Vector3): Handle?
	local model = template:Clone()

	local beams: { BeamState } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Beam") then
			table.insert(beams, { beam = descendant, transparency = descendant.Transparency })
		end
	end
	if #beams == 0 then
		model:Destroy()
		return nil
	end

	local holder = Instance.new("Part")
	holder.Name = HOLDER_NAME
	holder.Size = Vector3.one
	holder.Transparency = 1
	holder.CastShadow = false
	holder.Anchored = false
	holder.Massless = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CFrame = root.CFrame * CFrame.new(anchorOffset)

	-- GetDescendants returns a snapshot, so reparenting while walking it is
	-- safe. Every Beam rides along as a child of its own Attachment0.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") then
			descendant.Parent = holder
		end
	end
	model:Destroy()

	setFade(beams, 0)
	holder.Parent = root

	local weld = Instance.new("Weld")
	weld.Name = HOLDER_WELD_NAME
	weld.Part0 = root
	weld.Part1 = holder
	weld.C0 = CFrame.new(anchorOffset)
	weld.C1 = CFrame.new()
	weld.Parent = holder

	return {
		holder = holder,
		beams = beams,
		cancelled = false,
	}
end

--[[
	Yields for `duration`, easing the beams from fully transparent up to their
	authored Transparency. Bails the moment the handle is destroyed, leaving the
	beams wherever the fade got to, so a squishy that dies mid-flight cannot
	strand a fade running against a destroyed holder.
]]
function LaunchBeamRuntime.fadeIn(handle: Handle, duration: number)
	if handle.cancelled or handle.holder.Parent == nil then
		return
	end
	if duration <= 0 then
		setFade(handle.beams, 1)
		return
	end

	local elapsed = 0
	while elapsed < duration do
		local delta = RunService.Heartbeat:Wait()
		if handle.cancelled or handle.holder.Parent == nil then
			return
		end
		elapsed += delta
		setFade(handle.beams, math.clamp(elapsed / duration, 0, 1))
	end
end

function LaunchBeamRuntime.destroy(handle: Handle?)
	if handle == nil then
		return
	end
	handle.cancelled = true
	if handle.holder.Parent ~= nil then
		handle.holder:Destroy()
	end
end

return LaunchBeamRuntime
