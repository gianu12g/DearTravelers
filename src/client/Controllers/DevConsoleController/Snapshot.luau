--!strict
--[[
	The latest devSnapshot for the current target, plus the read accessors the
	Data, Actions and Info tabs all pull numbers and strings out of. Owning this
	in one place means every tab reads the same snapshot instead of each
	keeping its own stale copy.
]]

export type SnapshotEntry = {
	path: { string },
	kind: string,
	value: string,
}

local Snapshot = {}

local latestEntries: { SnapshotEntry } = {}
local entryByPath: { [string]: SnapshotEntry } = {}

function Snapshot.dottedPath(path: { string }): string
	return table.concat(path, ".")
end

function Snapshot.setEntries(entries: { SnapshotEntry })
	latestEntries = entries

	entryByPath = {}
	for _, entry in latestEntries do
		entryByPath[Snapshot.dottedPath(entry.path)] = entry
	end
end

function Snapshot.getEntries(): { SnapshotEntry }
	return latestEntries
end

function Snapshot.clear()
	latestEntries = {}
	entryByPath = {}
end

-- Numeric value of a snapshot leaf, or nil when the snapshot hasn't arrived yet
-- (or the field isn't a number). Used by the affordances that need to know the
-- current value client-side -- only the spawn-tier clamp, since every other
-- adjustment sends a delta and lets the server do the arithmetic.
function Snapshot.number(path: string): number?
	local entry = entryByPath[path]
	if entry == nil then
		return nil
	end
	return tonumber(entry.value)
end

function Snapshot.text(path: string): string
	local entry = entryByPath[path]
	return if entry ~= nil then entry.value else "--"
end

--[[
	How many entries an array field has in the latest snapshot. Counts distinct
	indices rather than leaves so it reads the same answer off a table array
	(Merge.Squishies.4.Tier) as off a scalar one (Cosmetics.Owned.SquishyBeams.4).
]]
function Snapshot.countArrayEntries(prefix: string): number
	local prefixWithDot = `{prefix}.`
	local depth = #string.split(prefix, ".")
	local seen: { [string]: boolean } = {}
	local count = 0

	for _, entry in latestEntries do
		if string.sub(Snapshot.dottedPath(entry.path), 1, #prefixWithDot) ~= prefixWithDot then
			continue
		end
		local index = entry.path[depth + 1]
		if index ~= nil and not seen[index] then
			seen[index] = true
			count += 1
		end
	end

	return count
end

return Snapshot
