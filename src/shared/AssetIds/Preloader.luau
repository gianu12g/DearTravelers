--!strict
--[[
	Returns every asset ID declared in Images + Sounds as `rbxassetid://`
	content strings. The boot loading screen preloads exactly this list, so
	adding an ID to either config is all it takes to get it preloaded --
	including an ID nested inside a grouped sub-table (e.g. Images.ThemeIcons),
	not just a flat top-level entry: collectIds recurses into any table value
	it finds, so a whole group preloads the same as a single flat ID would.

	Must be requirable from ReplicatedFirst (LoadingScreen.client.luau runs
	before ReplicatedStorage's descendants are guaranteed to have replicated)
	-- so this module makes no Net requires and yields for nothing beyond
	WaitForChild on its own siblings.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

-- script.Parent is Instance? in strict mode; bind it to a local once so the
-- WaitForChild calls below aren't a method chain off a nilable property.
local parent = script.Parent :: Instance

local imagesModule = parent:WaitForChild("Images")
local Images = require(imagesModule :: ModuleScript)

local soundsModule = parent:WaitForChild("Sounds")
local Sounds = require(soundsModule :: ModuleScript)

local Preloader = {}

--[[
	Walks `source` one level at a time, recursing into any nested table (a
	grouped set like Images.ThemeIcons) and formatting every number leaf as
	`rbxassetid://{id}`. `source` is deliberately `any` -- like
	DataService.repairTypes/deepCopy, this walks whatever shape a config
	module happens to have, flat or nested, without needing a type for every
	possible shape. Dedupes via `seen` so two names sharing one ID (e.g.
	Images.SecretPack / DailyRewards day 2) don't preload twice.
]]
local function collectIds(source: any, ids: { string }, seen: { [number]: true })
	for _, value in source do
		if type(value) == "number" then
			if not seen[value] then
				seen[value] = true
				table.insert(ids, `rbxassetid://{value}`)
			end
		elseif type(value) == "table" then
			collectIds(value, ids, seen)
		end
	end
end

function Preloader.collect(): { string }
	local ids: { string } = {}
	local seen: { [number]: true } = {}

	collectIds(Images, ids, seen)
	collectIds(Sounds, ids, seen)

	return ids
end

return Preloader
