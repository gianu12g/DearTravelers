--!strict
--[[
	Clones the one physical Workspace.DefaultLaunchTrail model onto a launched
	squishy. The authored TrailEmitter part is a scale reference: TopAttachment
	and BottomAttachment keep the same normalized positions when applied to
	different squishy sizes. Trail and optional ParticleEmitter properties are copied as-is,
	so the Workspace model is the only cosmetic source of truth.
]]

local SOURCE_EMITTER_NAME = "TrailEmitter"
local SOURCE_ATTACHMENT_0_NAME = "TopAttachment"
local SOURCE_ATTACHMENT_1_NAME = "BottomAttachment"
local ATTACHMENT_0_NAME = "LaunchTrailTopAttachment"
local ATTACHMENT_1_NAME = "LaunchTrailBottomAttachment"

local LaunchTrailRuntime = {}

local function destroyIfAttachment(instance: Instance?)
	if instance ~= nil and instance:IsA("Attachment") then
		instance:Destroy()
	end
end

function LaunchTrailRuntime.destroy(attachment0: Attachment?, attachment1: Attachment?)
	destroyIfAttachment(attachment0)
	destroyIfAttachment(attachment1)
end

function LaunchTrailRuntime.destroyExisting(part: BasePart)
	destroyIfAttachment(part:FindFirstChild(ATTACHMENT_0_NAME))
	destroyIfAttachment(part:FindFirstChild(ATTACHMENT_1_NAME))
end

local function findSourceAttachment(emitter: BasePart, name: string): Attachment?
	local instance = emitter:FindFirstChild(name)
	return if instance ~= nil and instance:IsA("Attachment") then instance else nil
end

local function scaledPosition(position: Vector3, sourceSize: Vector3, targetSize: Vector3): Vector3
	return Vector3.new(
		position.X * targetSize.X / math.max(sourceSize.X, 0.001),
		position.Y * targetSize.Y / math.max(sourceSize.Y, 0.001),
		position.Z * targetSize.Z / math.max(sourceSize.Z, 0.001)
	)
end

local function createRuntimeAttachment(
	source: Attachment,
	sourceEmitter: BasePart,
	targetPart: BasePart,
	name: string
): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = CFrame.new(scaledPosition(source.Position, sourceEmitter.Size, targetPart.Size))
		* source.CFrame.Rotation
	attachment.Parent = targetPart
	return attachment
end

function LaunchTrailRuntime.attach(part: BasePart, template: Model): (Attachment?, Attachment?)
	LaunchTrailRuntime.destroyExisting(part)

	local sourceEmitter = template:FindFirstChild(SOURCE_EMITTER_NAME, true)
	if sourceEmitter == nil or not sourceEmitter:IsA("BasePart") then
		return nil, nil
	end
	local sourceAttachment0 = findSourceAttachment(sourceEmitter, SOURCE_ATTACHMENT_0_NAME)
	local sourceAttachment1 = findSourceAttachment(sourceEmitter, SOURCE_ATTACHMENT_1_NAME)
	if sourceAttachment0 == nil or sourceAttachment1 == nil then
		return nil, nil
	end

	local attachment0 = createRuntimeAttachment(sourceAttachment0, sourceEmitter, part, ATTACHMENT_0_NAME)
	local attachment1 = createRuntimeAttachment(sourceAttachment1, sourceEmitter, part, ATTACHMENT_1_NAME)

	local trailCount = 0
	for _, visualTemplate in sourceEmitter:GetDescendants() do
		if visualTemplate:IsA("Trail") then
			local trail = visualTemplate:Clone()
			trail.Attachment0 = attachment0
			trail.Attachment1 = attachment1
			trail.Enabled = true
			trail.Parent = attachment0
			trailCount += 1
		elseif visualTemplate:IsA("ParticleEmitter") then
			local emitter = visualTemplate:Clone()
			emitter.Enabled = true
			emitter.Parent = if visualTemplate:IsDescendantOf(sourceAttachment0) then attachment0 else attachment1
		end
	end

	if trailCount == 0 then
		LaunchTrailRuntime.destroy(attachment0, attachment1)
		return nil, nil
	end

	return attachment0, attachment1
end

return LaunchTrailRuntime
