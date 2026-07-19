--!strict
--[[
	Calls `onPlayerAddedCallback` for every player currently in the game, and
	for every player who joins afterwards -- so a listener registered late
	never misses someone who was already connected (PORT-SPEC.md §1, ported
	from ServerScriptService.Utils.SafePlayerAdded).

	Bug fixed in passing: the source typed the callback as `(Player) -> nil`
	-- a function returning exactly one nil value -- when every real call site
	(including this port's) returns nothing at all, i.e. `(Player) -> ()`.
	Luau treats those as different return arities; `-> ()` is what every
	caller actually needs.
]]

local Players = game:GetService("Players")

local function safePlayerAdded(onPlayerAddedCallback: (Player) -> ()): RBXScriptConnection
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAddedCallback, player)
	end
	return Players.PlayerAdded:Connect(onPlayerAddedCallback)
end

return safePlayerAdded
