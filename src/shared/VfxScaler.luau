--!strict
--[[
	Scales every emitter under an instance by a multiplier, so one authored VFX
	can be reused at any size instead of being duplicated per scale.

	Emitter size lives in a different shape on every class -- a NumberSequence on
	ParticleEmitter/Trail, plain numbers on Beam/Fire/Smoke -- and a NumberSequence
	carries an envelope alongside each value that has to scale with it, or a
	scaled-up emitter keeps its original jitter and reads as flat. This module is
	the one place that knows all of that.

	The multiplier is RELATIVE, applied to whatever the emitter currently holds,
	so calls compose (2 then 0.5 is identity) and `1 / m` undoes `m`. Two caveats
	on that round trip:

	  - Roblox silently clamps some of these (Fire.Size to 2..30, Smoke.Size to
	    0.1..100, Beam widths to >= 0). Scaling past a clamp loses the original,
	    and scaling back returns the clamped value, not the authored one.
	  - Nothing is cached, so a template is only safe to scale in place if
	    nothing else scaled it first. Prefer scaling a fresh clone.

	Default pass is size only. Motion and offsets are opt-in because they are
	what a caller usually does NOT want when it just needs a bigger burst: with
	`motion`, particles travel proportionally farther (a true geometric scale);
	with `offsets`, attachment positions move, which will also drag anything else
	welded or beamed to those attachments.

		local VfxScaler = require(ReplicatedStorage.Shared.VfxScaler)

		local effect = template:Clone()
		VfxScaler.scale(effect, 2)                        -- twice as big
		VfxScaler.scale(effect, 0.5, { motion = true })   -- half, particles slow to match
]]

local VfxScaler = {}

export type Options = {
	-- Speed, Acceleration, and Beam/Trail texture length: makes particles cover
	-- proportionally more ground so the whole effect scales, not just its marks.
	motion: boolean?,
	-- Attachment.Position and Beam curve handles: the emitters' layout in space.
	offsets: boolean?,
	-- Range on any PointLight/SpotLight/SurfaceLight riding along with the VFX.
	lights: boolean?,
}

--[[
	Rebuilds `sequence` with every value and envelope multiplied.

	The envelope has to scale too: it is the +/- random spread around the value
	in the same units, so leaving it fixed makes a scaled-up emitter proportionally
	less varied and a scaled-down one proportionally noisier.
]]
function VfxScaler.scaleSequence(sequence: NumberSequence, multiplier: number): NumberSequence
	local keypoints: { NumberSequenceKeypoint } = {}
	for index, keypoint in sequence.Keypoints do
		keypoints[index] =
			NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * multiplier, keypoint.Envelope * multiplier)
	end
	return NumberSequence.new(keypoints)
end

local function scaleEmitter(instance: Instance, multiplier: number, options: Options): boolean
	if instance:IsA("ParticleEmitter") then
		instance.Size = VfxScaler.scaleSequence(instance.Size, multiplier)
		if options.motion then
			local speed = instance.Speed
			instance.Speed = NumberRange.new(speed.Min * multiplier, speed.Max * multiplier)
			instance.Acceleration *= multiplier
		end
		return true
	elseif instance:IsA("Trail") then
		instance.WidthScale = VfxScaler.scaleSequence(instance.WidthScale, multiplier)
		-- Stretch fits the texture to the trail, so TextureLength is ignored and
		-- scaling it would only surprise whoever reads the property later.
		if options.motion and instance.TextureMode ~= Enum.TextureMode.Stretch then
			instance.TextureLength *= multiplier
		end
		return true
	elseif instance:IsA("Beam") then
		instance.Width0 *= multiplier
		instance.Width1 *= multiplier
		if options.motion and instance.TextureMode ~= Enum.TextureMode.Stretch then
			instance.TextureLength *= multiplier
		end
		if options.offsets then
			-- Curve handles are stud offsets from the attachments; they have to
			-- move with them or a scaled beam straightens out.
			instance.CurveSize0 *= multiplier
			instance.CurveSize1 *= multiplier
		end
		return true
	elseif instance:IsA("Fire") then
		instance.Size *= multiplier
		return true
	elseif instance:IsA("Smoke") then
		instance.Size *= multiplier
		if options.motion then
			instance.RiseVelocity *= multiplier
		end
		return true
	elseif instance:IsA("Explosion") then
		instance.BlastRadius *= multiplier
		return true
	elseif options.lights and instance:IsA("Light") then
		if instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
			instance.Range *= multiplier
		end
		return true
	end
	return false
end

local EMPTY_OPTIONS: Options = {}

--[[
	Scales `root` and every descendant emitter by `multiplier`, returning how many
	instances were touched -- 0 means the tree held no emitters at all, which is
	usually a wrong-instance bug rather than a no-op worth ignoring.

	`root` itself is scaled when it is an emitter, so a bare ParticleEmitter is a
	valid argument, not just a Model or Attachment holding one.

	Errors on a multiplier that is not a positive finite number: NaN and inf
	propagate into a NumberSequence as unrecoverable garbage, and a negative or
	zero size is silently clamped, so both would fail far from the call site.
]]
function VfxScaler.scale(root: Instance, multiplier: number, options: Options?): number
	-- `multiplier ~= multiplier` is the NaN test: a plain `<= 0` check passes NaN
	-- straight through.
	if multiplier ~= multiplier or multiplier <= 0 or multiplier == math.huge then
		error(`[VfxScaler] multiplier must be a positive finite number, got {multiplier}`, 2)
	end

	local resolved = options or EMPTY_OPTIONS
	local count = 0

	if scaleEmitter(root, multiplier, resolved) then
		count += 1
	end

	for _, descendant in root:GetDescendants() do
		if scaleEmitter(descendant, multiplier, resolved) then
			count += 1
		end
	end

	if resolved.offsets then
		-- Separate pass: attachments are not emitters, but every emitter's
		-- position in the effect hangs off them, so scaling their local offsets
		-- is what actually spreads a VFX out rather than just fattening it.
		-- Deliberately not counted -- the return value is an emitter count.
		if root:IsA("Attachment") then
			root.Position *= multiplier
		end
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("Attachment") then
				descendant.Position *= multiplier
			end
		end
	end

	return count
end

return VfxScaler
