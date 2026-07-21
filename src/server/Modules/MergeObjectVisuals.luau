--!strict
--[[
	Attaches replaceable per-tier artwork to MergeService's authoritative
	MergeObject root Parts.

	Templates live in ServerStorage.MergeObjectModels and are named Tier1,
	Tier2, ... TierN. They may be Models or BaseParts. The gameplay root keeps
	pickup, carrying, merging, persistence, and placement independent from the
	artwork, while every visual BasePart is made non-interactive and welded to
	the root.

	Models should have a PrimaryPart whose orientation represents their intended
	forward/up axes. The visual's bounding box is centered horizontally and its
	bottom is aligned with the bottom of the gameplay root. If a template is
	missing or invalid, attach returns false and MergeService leaves its current
	colored cube visible as a safe fallback.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("MergeObjectVisuals")

local TEMPLATE_FOLDER_NAME = "MergeObjectModels"
local TEMPLATE_PREFIX = "Tier"
local VISUAL_NAME = "Visual"
local WELD_NAME = "VisualWeld"
local ROTATION_X_ATTRIBUTE = "RotationX"
local ROTATION_Y_ATTRIBUTE = "RotationY"
local ROTATION_Z_ATTRIBUTE = "RotationZ"
local CARRY_ROTATION_X_ATTRIBUTE = "CarryRotationX"
local CARRY_ROTATION_Y_ATTRIBUTE = "CarryRotationY"
local CARRY_ROTATION_Z_ATTRIBUTE = "CarryRotationZ"
local MUSH_SOUND_ID_ATTRIBUTE = "MushSoundId"
local MUSH_SOUND_VOLUME_ATTRIBUTE = "MushSoundVolume"
local MUSH_DIRECTION_ATTRIBUTE = "MushDirection"

local MUSH_DIRECTIONS: { [string]: string } = {
	top = "Top",
	bottom = "Bottom",
	left = "Left",
	right = "Right",
	front = "Front",
	back = "Back",
}

local warned: { [string]: boolean } = {}

local MergeObjectVisuals = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	log.warn(message)
end

local function templateForTier(tier: number): Instance?
	local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER_NAME)
	if folder == nil or not folder:IsA("Folder") then
		warnOnce("folder", `ServerStorage.{TEMPLATE_FOLDER_NAME} is missing -- using fallback merge cubes`)
		return nil
	end

	local templateName = TEMPLATE_PREFIX .. tostring(tier)
	local template = folder:FindFirstChild(templateName)
	if template == nil then
		warnOnce(templateName, `{folder:GetFullName()}.{templateName} is missing -- tier {tier} uses its fallback cube`)
		return nil
	end
	if not template:IsA("Model") and not template:IsA("BasePart") then
		warnOnce(
			templateName,
			`{template:GetFullName()} must be a Model or BasePart, got {template.ClassName} -- tier {tier} uses its fallback cube`
		)
		return nil
	end

	return template
end

local function collectParts(visual: Instance): { BasePart }
	if visual:IsA("BasePart") then
		return { visual }
	end

	local parts: { BasePart } = {}
	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function stripScripts(visual: Instance)
	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
		end
	end
end

local function rotationAttribute(template: Instance, attributeName: string): number
	local value = template:GetAttribute(attributeName)
	if value == nil then
		return 0
	end
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		warnOnce(
			template.Name .. ":" .. attributeName,
			`{template:GetFullName()}.{attributeName} must be a finite number of degrees -- using 0`
		)
		return 0
	end
	return value
end

local function getLocalBounds(root: BasePart, parts: { BasePart }): (Vector3, Vector3)
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)

	for _, part in parts do
		local half = part.Size / 2
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local worldCorner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
					local corner = root.CFrame:PointToObjectSpace(worldCorner)
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
	end

	return minimum, maximum
end

local function pivotVisual(visual: Instance, target: CFrame)
	if visual:IsA("Model") then
		visual:PivotTo(target)
	else
		(visual :: BasePart).CFrame = target
	end
end

local function alignVisual(visual: Instance, template: Instance, root: BasePart, parts: { BasePart })
	local reference: CFrame
	local visualPivot: CFrame

	if visual:IsA("Model") then
		if visual.PrimaryPart == nil then
			visual.PrimaryPart = parts[1]
			warnOnce(
				visual.Name .. ":PrimaryPart",
				`{TEMPLATE_FOLDER_NAME}.{visual.Name} has no PrimaryPart -- using {parts[1].Name}; set one to make orientation explicit`
			)
		end
		reference = (visual.PrimaryPart :: BasePart).CFrame
		visualPivot = visual:GetPivot()
	else
		local part = visual :: BasePart
		reference = part.CFrame
		visualPivot = part.CFrame
	end

	local rotation = CFrame.Angles(
		math.rad(rotationAttribute(template, ROTATION_X_ATTRIBUTE)),
		math.rad(rotationAttribute(template, ROTATION_Y_ATTRIBUTE)),
		math.rad(rotationAttribute(template, ROTATION_Z_ATTRIBUTE))
	)
	local targetReference = CFrame.new(root.Position) * root.CFrame.Rotation * rotation
	pivotVisual(visual, targetReference * reference:Inverse() * visualPivot)

	-- Recompute bounds after rotation. Center X/Z over the gameplay root and
	-- place the lowest rotated corner on the root's bottom plane, so a 90°
	-- correction around X or Z cannot leave a long model floating or buried.
	local minimum, maximum = getLocalBounds(root, parts)
	local localTranslation =
		Vector3.new(-(minimum.X + maximum.X) / 2, -root.Size.Y / 2 - minimum.Y, -(minimum.Z + maximum.Z) / 2)
	local worldTranslation = root.CFrame:VectorToWorldSpace(localTranslation)
	local currentPivot = if visual:IsA("Model") then visual:GetPivot() else (visual :: BasePart).CFrame
	pivotVisual(visual, CFrame.new(worldTranslation) * currentPivot)
end

function MergeObjectVisuals.attach(root: BasePart, tier: number): boolean
	local template = templateForTier(tier)
	if template == nil then
		return false
	end

	local visual = template:Clone()
	visual.Name = VISUAL_NAME
	stripScripts(visual)

	local parts = collectParts(visual)
	if #parts == 0 then
		warnOnce(
			template.Name .. ":empty",
			`{template:GetFullName()} has no BaseParts -- tier {tier} uses its fallback cube`
		)
		visual:Destroy()
		return false
	end

	visual.Parent = root
	alignVisual(visual, template, root, parts)

	for _, part in parts do
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true

		local weld = Instance.new("Weld")
		weld.Name = WELD_NAME
		weld.Part0 = root
		weld.Part1 = part
		weld.C0 = root.CFrame:ToObjectSpace(part.CFrame)
		weld.C1 = CFrame.new()
		weld.Parent = part
	end

	root:SetAttribute("VisualTemplate", template.Name)
	return true
end

function MergeObjectVisuals.getCarryRotation(tier: number): CFrame
	local template = templateForTier(tier)
	if template == nil then
		return CFrame.new()
	end

	return CFrame.Angles(
		math.rad(rotationAttribute(template, CARRY_ROTATION_X_ATTRIBUTE)),
		math.rad(rotationAttribute(template, CARRY_ROTATION_Y_ATTRIBUTE)),
		math.rad(rotationAttribute(template, CARRY_ROTATION_Z_ATTRIBUTE))
	)
end

function MergeObjectVisuals.getMushSound(tier: number): (string, number)
	local template = templateForTier(tier)
	if template == nil then
		return "", 0.5
	end

	local rawId = template:GetAttribute(MUSH_SOUND_ID_ATTRIBUTE)
	local soundId = ""
	if rawId ~= nil then
		if type(rawId) ~= "string" then
			warnOnce(
				template.Name .. ":" .. MUSH_SOUND_ID_ATTRIBUTE,
				`{template:GetFullName()}.{MUSH_SOUND_ID_ATTRIBUTE} must be a string asset ID -- Mush will be silent`
			)
		elseif rawId == "" then
			soundId = ""
		else
			local digits = string.match(rawId, "^%d+$") or string.match(rawId, "^rbxassetid://(%d+)$")
			if digits == nil then
				warnOnce(
					template.Name .. ":" .. MUSH_SOUND_ID_ATTRIBUTE,
					`{template:GetFullName()}.{MUSH_SOUND_ID_ATTRIBUTE} must contain digits or rbxassetid://digits -- Mush will be silent`
				)
			else
				soundId = "rbxassetid://" .. digits
			end
		end
	end

	local rawVolume = template:GetAttribute(MUSH_SOUND_VOLUME_ATTRIBUTE)
	local volume = if type(rawVolume) == "number"
			and rawVolume == rawVolume
			and rawVolume ~= math.huge
			and rawVolume ~= -math.huge
		then math.clamp(rawVolume, 0, 10)
		else 0.5

	return soundId, volume
end

function MergeObjectVisuals.getMushDirection(tier: number): string
	local template = templateForTier(tier)
	if template == nil then
		return "Top"
	end

	local rawDirection = template:GetAttribute(MUSH_DIRECTION_ATTRIBUTE)
	if type(rawDirection) == "string" then
		local direction = MUSH_DIRECTIONS[string.lower(rawDirection)]
		if direction ~= nil then
			return direction
		end
	end

	if rawDirection ~= nil then
		warnOnce(
			template.Name .. ":" .. MUSH_DIRECTION_ATTRIBUTE,
			`{template:GetFullName()}.{MUSH_DIRECTION_ATTRIBUTE} must be Top, Bottom, Left, Right, Front, or Back -- using Top`
		)
	end
	return "Top"
end

return MergeObjectVisuals
