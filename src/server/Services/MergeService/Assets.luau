--!strict
--[[
	Boot-time discovery of the merge map layout, its bases, and every launch/
	merge cosmetic template, plus read-only accessors over that discovered
	state. Populated once by Assets.load() (called from init.Start()) and
	read-only afterwards -- every other sibling that needs a base, a map
	bound, or a template goes through the accessors below rather than holding
	its own copy, so this is the single owner of all of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Types = require(script.Parent.Types)

local log = Log.new("MergeService")

-- Same tolerance and bound as BaseService: a base whose pieces never stream
-- in must not hang Start() (and therefore every player join) forever.
local WAIT_TIMEOUT = 10

-- Populated once during Start(); read-only afterwards.
local bases: { [string]: Types.BaseRecord } = {}
local launchMapLayout: Instance? = nil
local launchBaseplate: BasePart? = nil
local launchMapBounds: Types.LaunchMapBounds? = nil
local launchFallbackSurfaceY = 0
local defaultLaunchBeamTemplate: Model? = nil
local launchBeamTemplates: { [string]: Model } = {}
local launchExplosionTemplate: Attachment? = nil
local launchGroundHitTemplate: BasePart? = nil
local mergePopTemplateIds: { [string]: true } = {}

local Assets = {}

local function calculateLaunchMapBounds(mapLayout: Instance): Types.LaunchMapBounds?
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false

	for _, descendant in mapLayout:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		found = true
		local half = descendant.Size / 2
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = descendant.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
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

	if not found then
		return nil
	end
	return {
		minX = minimum.X,
		maxX = maximum.X,
		minY = minimum.Y,
		maxY = maximum.Y,
		minZ = minimum.Z,
		maxZ = maximum.Z,
	}
end

function Assets.resolveLaunchTarget(worldX: number, worldZ: number, squishyHalfSize: number): Vector3?
	local mapLayout = launchMapLayout
	local baseplate = launchBaseplate
	local bounds = launchMapBounds
	if
		mapLayout == nil
		or baseplate == nil
		or bounds == nil
		or not Types.isFiniteNumber(worldX)
		or not Types.isFiniteNumber(worldZ)
	then
		return nil
	end

	local localPoint = baseplate.CFrame:PointToObjectSpace(Vector3.new(worldX, baseplate.Position.Y, worldZ))
	if math.abs(localPoint.X) > baseplate.Size.X / 2 or math.abs(localPoint.Z) > baseplate.Size.Z / 2 then
		return nil
	end

	local baseplateTop = baseplate.Position.Y + baseplate.Size.Y / 2
	local baseplateBottom = baseplate.Position.Y - baseplate.Size.Y / 2
	local rayHeight = math.max(bounds.maxY, baseplateTop) + 50
	local rayBottom = math.min(bounds.minY, baseplateBottom) - 50
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapLayout, baseplate }
	params.IgnoreWater = false
	local result = Workspace:Raycast(
		Vector3.new(worldX, rayHeight, worldZ),
		Vector3.new(0, rayBottom - rayHeight, 0),
		params
	)
	local surfaceY = if result ~= nil then result.Position.Y else launchFallbackSurfaceY
	return Vector3.new(worldX, surfaceY + squishyHalfSize, worldZ)
end

local function isMergePopTemplate(template: Instance): boolean
	if not template:IsA("BasePart") and not template:IsA("Model") then
		return false
	end
	if not template:IsA("BasePart") and template:FindFirstChildWhichIsA("BasePart", true) == nil then
		return false
	end
	return template:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
end

function Assets.getBase(baseName: string): Types.BaseRecord?
	return bases[baseName]
end

function Assets.getLaunchBeamTemplate(cosmeticId: string): Model?
	return launchBeamTemplates[cosmeticId]
end

function Assets.getDefaultLaunchBeamTemplate(): Model?
	return defaultLaunchBeamTemplate
end

function Assets.getLaunchExplosionTemplate(): Attachment?
	return launchExplosionTemplate
end

function Assets.getLaunchGroundHitTemplate(): BasePart?
	return launchGroundHitTemplate
end

function Assets.isMergePopTemplateId(cosmeticId: string): boolean
	return mergePopTemplateIds[cosmeticId] == true
end

--[[
	Discovers the map layout, every base's SpawnArea, and every launch/merge
	cosmetic template. Called once from init.Start(). Returns the number of
	usable bases found, or nil if the map/bases could not be found at all --
	either way MergeService is disabled and init.Start() must not proceed to
	wire Players/Heartbeat.
]]
function Assets.load(): number?
	table.clear(launchBeamTemplates)
	table.clear(mergePopTemplateIds)
	local launchBeamsFolder = ReplicatedStorage.Assets.VFX.LaunchBeams
	for _, entry in CosmeticsCatalog.SquishyBeams do
		local candidate = launchBeamsFolder:FindFirstChild(entry.Id)
		if candidate ~= nil and candidate:IsA("Model") and candidate:FindFirstChildWhichIsA("Beam", true) ~= nil then
			launchBeamTemplates[entry.Id] = candidate
		else
			log.warn(`Assets.VFX.LaunchBeams.{entry.Id} is missing or malformed -- cosmetic unavailable`)
		end
	end

	defaultLaunchBeamTemplate = launchBeamTemplates[MergeConfig.DEFAULT_LAUNCH_BEAM_MODEL_NAME]
	if defaultLaunchBeamTemplate == nil then
		log.warn(
			`Assets.VFX.LaunchBeams.{MergeConfig.DEFAULT_LAUNCH_BEAM_MODEL_NAME} is unavailable -- falling`
				.. ` launches have no beams`
		)
	end

	local explosionTemplate =
		ReplicatedStorage.Assets.VFX.LaunchExplosion:FindFirstChild(MergeConfig.LAUNCH_EXPLOSION_TEMPLATE_NAME)
	if
		explosionTemplate ~= nil
		and explosionTemplate:IsA("Attachment")
		and explosionTemplate:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
	then
		launchExplosionTemplate = explosionTemplate
	else
		log.warn(
			`Assets.VFX.LaunchExplosion.{MergeConfig.LAUNCH_EXPLOSION_TEMPLATE_NAME} is missing or malformed --`
				.. ` launch landings have no impact burst`
		)
	end

	local groundHitTemplate =
		ReplicatedStorage.Assets.VFX.LaunchExplosion:FindFirstChild(MergeConfig.LAUNCH_GROUND_HIT_TEMPLATE_NAME)
	if
		groundHitTemplate ~= nil
		and groundHitTemplate:IsA("BasePart")
		and groundHitTemplate:FindFirstChildWhichIsA("ParticleEmitter", true) ~= nil
	then
		launchGroundHitTemplate = groundHitTemplate
	else
		log.warn(
			`Assets.VFX.LaunchExplosion.{MergeConfig.LAUNCH_GROUND_HIT_TEMPLATE_NAME} is missing or malformed --`
				.. ` launch landings have no ground hit`
		)
	end

	local mergeVfxFolder = ReplicatedStorage.Assets.VFX.Merge
	for _, entry in CosmeticsCatalog.MergePops do
		local candidate = mergeVfxFolder:FindFirstChild(entry.Id)
		if candidate ~= nil and isMergePopTemplate(candidate) then
			mergePopTemplateIds[entry.Id] = true
		else
			log.warn(`Assets.VFX.Merge.{entry.Id} is missing or malformed -- Merge Pop cosmetic unavailable`)
		end
	end

	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- MergeService disabled")
		return nil
	end
	launchMapLayout = mapLayout

	local baseplateInstance = Workspace:WaitForChild("Baseplate", WAIT_TIMEOUT)
	if baseplateInstance == nil or not baseplateInstance:IsA("BasePart") then
		launchBaseplate = nil
		log.error("Workspace.Baseplate is missing or not a BasePart -- launch targeting disabled")
	else
		launchBaseplate = baseplateInstance
		launchFallbackSurfaceY = baseplateInstance.Position.Y + baseplateInstance.Size.Y / 2
	end

	launchMapBounds = calculateLaunchMapBounds(mapLayout)
	if launchMapBounds == nil then
		log.warn("MapLayout has no BaseParts -- launch targeting disabled")
	end

	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- MergeService disabled")
		return nil
	end

	local baseCount = 0
	for _, part in basesFolder:GetChildren() do
		if string.match(part.Name, "^Base%d+$") == nil then
			continue
		end
		local baseName = part.Name
		if not part:IsA("BasePart") then
			log.warn(`Bases.{baseName} is not a BasePart -- excluded from merge spawning`)
			continue
		end
		local basePart: BasePart = part

		local spawnAreaInstance = basePart:FindFirstChild("SpawnArea")
		if spawnAreaInstance == nil or not spawnAreaInstance:IsA("BasePart") then
			log.warn(`{baseName}.SpawnArea is missing or not a BasePart -- excluded from merge spawning`)
			continue
		end
		local spawnArea: BasePart = spawnAreaInstance

		bases[baseName] = { part = basePart, spawnArea = spawnArea }
		baseCount += 1
	end

	if baseCount == 0 then
		log.error("no base has a usable SpawnArea -- MergeService disabled")
		return nil
	end

	return baseCount
end

return Assets
