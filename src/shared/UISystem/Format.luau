--!strict
--[[
	Display-formatting helpers, ported from the UISystem dump's
	ReplicatedStorage.Utils.GlobalFunctions (FormatTime, FormatNumber,
	Retry). Pure functions, both sides need them for identical HUD text, so
	they live here rather than being duplicated client/server.

	Do not confuse this with a same-named-but-empty stub the source also
	had at ServerScriptService.Utils.GlobalFunctions -- that one is not
	ported; this file is the real implementation (server/INDEX.md §6.2).

	A plain module -- the name ends in neither Service nor Controller, so
	the Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.
]]

local Format = {}

local function pad(n: number): string
	return string.format("%02d", n)
end

-- "1:02:03:04" (d:h:m:s), trimmed to the largest non-zero unit.
function Format.FormatTime(seconds: number): string
	local total = math.floor(seconds)

	local days = math.floor(total / 86400)
	local hours = math.floor((total % 86400) / 3600)
	local minutes = math.floor((total % 3600) / 60)
	local secs = total % 60

	if days > 0 then
		return string.format("%d:%s:%s:%s", days, pad(hours), pad(minutes), pad(secs))
	elseif hours > 0 then
		return string.format("%s:%s:%s", pad(hours), pad(minutes), pad(secs))
	elseif minutes > 0 then
		return string.format("%s:%s", pad(minutes), pad(secs))
	else
		return tostring(secs)
	end
end

local SUFFIXES = {
	"",
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"De",
	"Ud",
	"Dd",
	"Td",
	"Qad",
	"Qid",
	"Sxd",
	"Spd",
	"Ocd",
	"Nod",
	"Vg",
	"Uvg",
	"Dvg",
	"Tvg",
	"Qavg",
	"Qivg",
	"Sxvg",
	"Spvg",
	"Ocvg",
	"Novg",
	"Tg",
}

-- "1.23K", "4.56M", etc. Falls back to scientific notation past the largest
-- named suffix (Tg, 10^93) rather than indexing off the end of the table.
function Format.FormatNumber(value: number): string
	if value < 1000 then
		return tostring(math.floor(value))
	end

	local index = math.floor(math.log10(value) / 3)

	if index >= #SUFFIXES then
		return string.format("%.2e", value)
	end

	local suffix = SUFFIXES[index + 1]
	local shortValue = value / math.pow(10, 3 * index)
	local truncated = math.floor(shortValue * 100) / 100

	return string.format("%.2f%s", truncated, suffix)
end

--[[
	Retries `callback` up to `retries` times, waiting 0.5s between attempts.
	Returns (true, result) on the first success, or (false, lastResult) if
	every attempt failed -- lastResult is then pcall's error value, not a T,
	same as the source (it never distinguished the two on the wire either).
]]
function Format.Retry<T>(callback: () -> T, retries: number): (boolean, T?)
	local success: boolean = false
	local result: T? = nil

	for _ = 1, retries do
		success, result = pcall(callback)

		if success then
			return true, result
		end

		task.wait(0.5)
	end

	return false, result
end

return Format
