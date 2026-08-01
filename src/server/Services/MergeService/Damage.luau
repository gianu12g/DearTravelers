--!strict
--[[
	Public damage/inventory API: the read-only Squishies snapshot, the shared
	transactional damage path both the dev console and real launch combat
	route through, and the dev-console spawn/clear entry points. Forwarded
	onto the MergeService table by init.luau -- see that file's own note.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.Parent.DataService)
local LaunchEffects = require(script.Parent.LaunchEffects)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Spawning = require(script.Parent.Spawning)
local StatusUI = require(script.Parent.StatusUI)
local Types = require(script.Parent.Types)
local Vfx = require(script.Parent.Vfx)

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
	carries: { [Player]: Types.CarryState },
	activeLaunches: { [Player]: Types.LaunchState },
}

-- Set once by Damage.setup(), called from init.Init(). See Spawning.luau's
-- own header note on why these are references to init-owned tables.
local liveBases: { [Player]: Types.LiveBase } = nil :: any
local carries: { [Player]: Types.CarryState } = nil :: any
local activeLaunches: { [Player]: Types.LaunchState } = nil :: any

local Damage = {}

function Damage.setup(deps: Deps)
	liveBases = deps.liveBases
	carries = deps.carries
	activeLaunches = deps.activeLaunches
end

--[[
	Read-only copy of `player`'s merge objects, or nil if their data isn't
	loaded. Deep-copies each entry (not just the array) so a caller cannot
	reach back into profile.Data through the returned tables -- returning the
	live entry tables directly would let external code mutate saved data
	without going through DataService.set, silently desyncing the replica.
]]
function Damage.getSquishies(player: Player): { Types.MergeObjectEntry }?
	local data = DataService.getData(player)
	if data == nil then
		return nil
	end

	local copy: { Types.MergeObjectEntry } = {}
	for _, entry in data.Merge.Squishies do
		table.insert(copy, { Tier = entry.Tier, X = entry.X, Z = entry.Z, Health = entry.Health })
	end
	return copy
end

-- Permanently upgrades both current and maximum health without ever doubling
-- the same saved values twice. The persisted multiplier is the idempotence
-- marker; every live reference is replaced alongside the replicated array so
-- carry, launch, damage, and the in-world health bar stay on the same entries.
function Damage.applyHealthMultiplier(player: Player, requestedMultiplier: number): boolean
	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local currentMultiplier = MergeConfig.sanitizeSquishyHealthMultiplier(data.Merge.SquishyHealthMultiplier)
	local targetMultiplier =
		math.max(currentMultiplier, MergeConfig.sanitizeSquishyHealthMultiplier(requestedMultiplier))
	if targetMultiplier == currentMultiplier then
		local live = liveBases[player]
		if live ~= nil then
			for part, entry in live.parts do
				StatusUI.updateHealthVisual(part, entry.Tier, entry.Health, targetMultiplier)
			end
		end
		return true
	end

	local factor = targetMultiplier / currentMultiplier
	local replacements: { [any]: Types.MergeObjectEntry } = {}
	local updated: { Types.MergeObjectEntry } = table.create(#data.Merge.Squishies)
	for _, entry in data.Merge.Squishies do
		local newEntry: Types.MergeObjectEntry = {
			Tier = entry.Tier,
			X = entry.X,
			Z = entry.Z,
			Health = math.min(
				MergeConfig.maxHealthForTier(entry.Tier, targetMultiplier),
				Types.sanitizeHealth(entry.Health, entry.Tier, currentMultiplier) * factor
			),
		}
		replacements[entry] = newEntry
		table.insert(updated, newEntry)
	end

	DataService.set(player, { "Merge", "SquishyHealthMultiplier" }, targetMultiplier)
	DataService.set(player, { "Merge", "Squishies" }, updated)

	local carry = carries[player]
	if carry ~= nil then
		carry.entry = replacements[carry.entry] or carry.entry
	end
	local launch = activeLaunches[player]
	if launch ~= nil then
		launch.entry = replacements[launch.entry] or launch.entry
	end

	local live = liveBases[player]
	if live ~= nil then
		for part, oldEntry in live.parts do
			local replacement = replacements[oldEntry]
			if replacement ~= nil then
				live.parts[part] = replacement
				StatusUI.updateHealthVisual(part, replacement.Tier, replacement.Health, targetMultiplier)
			end
		end
	end

	return true
end

type DamageForEntry = (Types.MergeObjectEntry) -> number

-- One transactional damage path shared by the developer test and real launch
-- combat. `eligibleEntries == nil` means every squishy; launch combat passes a
-- set built from actual live part positions so the landing point matters.
local function applySquishyDamage(
	player: Player,
	damageForEntry: DamageForEntry,
	eligibleEntries: { [any]: true }?
): (number?, number)
	local data = DataService.getData(player)
	if data == nil then
		return nil, 0
	end
	local healthMultiplier = data.Merge.SquishyHealthMultiplier

	local updated: { Types.MergeObjectEntry } = table.create(#data.Merge.Squishies)
	local replacements: { [any]: Types.MergeObjectEntry } = {}
	local deadEntries: { [any]: true } = {}
	local damagedCount = 0
	local killedCount = 0

	for _, entry in data.Merge.Squishies do
		if eligibleEntries ~= nil and eligibleEntries[entry] == nil then
			table.insert(updated, entry)
			continue
		end

		local damage = math.max(0, damageForEntry(entry))
		local oldHealth = Types.sanitizeHealth(entry.Health, entry.Tier, healthMultiplier)
		local newHealth = math.max(0, oldHealth - damage)

		if oldHealth <= 0 or newHealth <= 0 then
			deadEntries[entry] = true
			killedCount += 1
			if oldHealth > 0 then
				damagedCount += 1
			end
			continue
		end

		local newEntry: Types.MergeObjectEntry = {
			Tier = entry.Tier,
			X = entry.X,
			Z = entry.Z,
			Health = newHealth,
		}
		table.insert(updated, newEntry)
		replacements[entry] = newEntry
		if newHealth ~= oldHealth then
			damagedCount += 1
		end
	end

	if damagedCount == 0 and killedCount == 0 then
		return 0, 0
	end

	-- One transaction removes every dead entry and updates every survivor,
	-- keeping Replica's numeric array compact at every point clients can see.
	DataService.set(player, { "Merge", "Squishies" }, updated)

	local carry = carries[player]
	if carry ~= nil then
		local replacement = replacements[carry.entry]
		if replacement ~= nil then
			carry.entry = replacement
		elseif deadEntries[carry.entry] then
			carries[player] = nil
			Types.clearCarryingAttributes(player)
			carry.weld:Destroy()
		end
	end

	local launch = activeLaunches[player]
	if launch ~= nil then
		local replacement = replacements[launch.entry]
		if replacement ~= nil then
			launch.entry = replacement
		elseif deadEntries[launch.entry] then
			-- The live-part cleanup below destroys the projectile. Clear the
			-- state now so its animation exits without permanently blocking pickup.
			activeLaunches[player] = nil
			LaunchEffects.destroyLaunchBeams(launch)
			-- Cheap and Parent-guarded even though the part is destroyed a few
			-- lines below -- restoreLaunchScale is the safety net for every
			-- launch exit path, this one included.
			LaunchEffects.restoreLaunchScale(launch)
		end
	end

	local live = liveBases[player]
	if live ~= nil then
		local deadParts: { BasePart } = {}
		for part, oldEntry in live.parts do
			local replacement = replacements[oldEntry]
			if replacement ~= nil then
				live.parts[part] = replacement
				StatusUI.updateHealthVisual(part, replacement.Tier, replacement.Health, healthMultiplier)
			elseif deadEntries[oldEntry] then
				table.insert(deadParts, part)
			end
		end

		-- Remove table keys after traversal; mutating keys during a `for...in`
		-- walk is undefined in Luau. Each VFX anchor outlives its destroyed Part.
		for _, part in deadParts do
			local deadEntry = live.parts[part]
			live.parts[part] = nil
			live.disarmed[part] = nil

			if part.Parent ~= nil and deadEntry ~= nil then
				local tierDef = Types.tierDefFor(deadEntry.Tier)
				Vfx.spawnSquishyPopVfx(live.objectsFolder, part.Position, tierDef.Color, tierDef.Size)
				part:Destroy()
			end
		end
	end

	return damagedCount, killedCount
end

-- Server-side all-squishy damage entry point used by the authenticated
-- developer console. The real launch path below uses flat attacker-owned
-- damage rather than a fraction of each victim's own max health.
function Damage.damageSquishies(player: Player, maxHealthFraction: number): (number?, number)
	if not Types.isFiniteNumber(maxHealthFraction) or maxHealthFraction <= 0 then
		return 0, 0
	end

	local data = DataService.getData(player)
	if data == nil then
		return nil, 0
	end
	local damageFraction = math.min(maxHealthFraction, 1)
	return applySquishyDamage(player, function(entry: Types.MergeObjectEntry): number
		return MergeConfig.maxHealthForTier(entry.Tier, data.Merge.SquishyHealthMultiplier) * damageFraction
	end, nil)
end

-- Applies one flat damage amount to every live squishy whose horizontal
-- center falls inside the selected landing radius. The launch service chooses
-- `damageAmount`; no client-supplied damage reaches this function.
function Damage.damageSquishiesNear(
	player: Player,
	worldPosition: Vector3,
	radius: number,
	damageAmount: number
): (number?, number)
	if
		typeof(worldPosition) ~= "Vector3"
		or not Types.isFiniteNumber(worldPosition.X)
		or not Types.isFiniteNumber(worldPosition.Y)
		or not Types.isFiniteNumber(worldPosition.Z)
		or not Types.isFiniteNumber(radius)
		or radius <= 0
		or not Types.isFiniteNumber(damageAmount)
		or damageAmount <= 0
	then
		return 0, 0
	end

	local live = liveBases[player]
	if live == nil then
		return 0, 0
	end

	local eligibleEntries: { [any]: true } = {}
	local radiusSquared = radius * radius
	local activeLaunch = activeLaunches[player]
	for part, entry in live.parts do
		if part.Parent == nil then
			continue
		end
		if part:GetAttribute("AutoMerging") == true then
			continue -- pair is reserved until its server-owned merge transaction commits
		end
		if activeLaunch ~= nil and activeLaunch.part == part then
			continue -- in flight; not a valid area-damage target, same exclusion pickUp applies
		end
		local dx = part.Position.X - worldPosition.X
		local dz = part.Position.Z - worldPosition.Z
		if dx * dx + dz * dz <= radiusSquared then
			eligibleEntries[entry] = true
		end
	end

	if next(eligibleEntries) == nil then
		return 0, 0
	end

	return applySquishyDamage(player, function(_entry: Types.MergeObjectEntry): number
		return damageAmount
	end, eligibleEntries)
end

--[[
	Developer console: run `count` auto-spawn attempts right now instead of
	waiting SPAWN_INTERVAL for each one.

	Deliberately a loop over Spawning.trySpawnObject rather than its own
	placement code. That function already owns every rule that makes a
	squishy legitimate -- the MAX_OBJECTS cap, the SpawnLevel tier,
	rejection-sampled placement, the incremental tableInsert that keeps the
	replicated array compact -- so a dev-spawned squishy is indistinguishable
	from an auto-spawned one, and there is no second spawn path to keep in
	sync with it. It does not yield, so the whole batch lands in one frame.

	Returns how many actually landed, which is NOT always `count`: a full pad
	spawns none and a crowded one spawns some, because findOpenSpot gives up
	rather than overlapping (the caller reports that difference). nil means
	there is nothing to spawn onto at all -- no loaded data, or no active base.
]]
function Damage.spawnSquishies(player: Player, count: number): number?
	local live = liveBases[player]
	if live == nil then
		return nil
	end

	local data = DataService.getData(player)
	if data == nil then
		return nil
	end

	if not Types.isFiniteNumber(count) then
		return 0
	end

	local before = #data.Merge.Squishies
	for _ = 1, math.clamp(math.floor(count), 1, MergeConfig.MAX_OBJECTS) do
		Spawning.trySpawnObject(player, live)
	end

	-- Re-read rather than counting successes inside the loop: `data` is the live
	-- profile table, so this reflects exactly what was committed.
	return #data.Merge.Squishies - before
end

--[[
	Developer console: remove every squishy the player owns.

	Routed through the shared damage transaction with lethal damage rather than a
	bare DataService.set(..., {}), so a wipe performs exactly the bookkeeping a
	real kill does -- the compact-array rewrite, dropping a carried or in-flight
	entry, destroying live parts, the pop VFX -- with no second removal path to
	keep in sync. Returns (nil, 0) only when the target has no loaded data.
]]
function Damage.clearSquishies(player: Player): (number?, number)
	return applySquishyDamage(player, function(_entry: Types.MergeObjectEntry): number
		return math.huge
	end, nil)
end

return Damage
