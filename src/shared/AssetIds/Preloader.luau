--!strict
--[[
	Returns every asset ID declared in Images + Sounds as `rbxassetid://`
	content strings. The boot loading screen preloads exactly this list, so
	adding an ID to either config is all it takes to get it preloaded.

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
	Iterates every value in Images then Sounds, formatting each as
	`rbxassetid://{id}`. Dedupes with a `seen` set so two names that share
	one ID (e.g. Images.SecretPack / DailyRewards day 2) don't preload twice.
]]
function Preloader.collect(): { string }
	local ids: { string } = {}
	local seen: { [number]: true } = {}

	for _, id in Images do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, `rbxassetid://{id}`)
		end
	end

	for _, id in Sounds do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, `rbxassetid://{id}`)
		end
	end

	return ids
end

return Preloader
