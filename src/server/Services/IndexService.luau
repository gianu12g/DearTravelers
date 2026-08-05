--!strict
--[[
	Squishy Index discovery authority.

	A model level counts as discovered the first time the player OWNS a squishy
	at that level. Rather than hooking each of the six paths that can produce
	one (auto-spawn, deadlock rescue, Carry.commitMerge, AutoMerge.commitPair,
	the purchased-delivery compaction, and setSpawnLevel's floor raise), this
	hangs off Spawning.spawnRestingPart -- the single choke point every resting
	MergeObject Part is created through (see its own header note). That also
	means existing profiles backfill themselves: base activation re-materializes
	every persisted squishy through the same function, so a returning player's
	index fills in on their next join with no migration step.

	markDiscovered is deliberately YIELD-FREE. Its callers include the
	read-modify-write transactions in commitMerge/commitPair/setSpawnLevel,
	which are only safe because nothing between their read and their
	DataService.set can yield (quality-gate.md trap #5). A yield added here
	would silently make those racy.

	No Init()/Start() -- this service holds no state of its own and listens to
	nothing; it is pure behavior over DataService. The Loader still picks it up
	by name and simply finds no lifecycle hooks to run (ARCHITECTURE.md
	Recipe 3's inverse: a *Service with neither hook is legal, just inert).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local QuestsService = require(script.Parent.UISystem.QuestsService)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)

local IndexService = {}

--[[
	Records `modelLevel` as discovered for `player`. Returns true only when this
	call is what newly discovered it, so a caller can drive a "New!" toast off
	the return value without re-reading the profile.

	Silently ignores a level outside 1..MAX_MODEL_LEVEL instead of clamping:
	the only way to get one is a corrupted entry, and clamping would award the
	player a legitimate index entry (level 1, or the max) they never earned.
	NaN is rejected explicitly -- every comparison against it is false, so the
	range check alone would let it through (quality-gate.md trap #8).
]]
function IndexService.markDiscovered(player: Player, modelLevel: any): boolean
	if
		type(modelLevel) ~= "number"
		or modelLevel ~= modelLevel
		or modelLevel ~= math.floor(modelLevel)
		or modelLevel < 1
		or modelLevel > RebirthConfig.MAX_MODEL_LEVEL
	then
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local discovered = data.Index.DiscoveredSquishies
	if table.find(discovered, modelLevel) ~= nil then
		return false
	end

	-- Append rather than rewriting the array: Replica's TableInsert sends one
	-- element instead of retransmitting every level discovered so far, and the
	-- array stays compact because this is the only writer.
	DataService.tableInsert(player, { "Index", "DiscoveredSquishies" }, modelLevel)
	-- Quest metric. Reached only on a genuinely NEW level, because every
	-- already-discovered path returned above -- so re-owning a level the player
	-- already has cannot farm the "Discover N New Squishies" quests.
	QuestsService.award(player, "Discoveries", 1)
	return true
end

return IndexService
