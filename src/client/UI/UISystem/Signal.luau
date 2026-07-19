--!strict
--[[
	Minimal typed pub/sub signal -- just enough for UISignals.luau's
	OpenFrame/CloseFrame cross-controller events. PORT-SPEC.md §4: LemonSignal
	is NOT added as a dependency; this ~40-line first-party replacement
	covers the one thing the port needs (Connect/Fire, no priority, no
	Wait()).

	Closures rather than a metatable+self design on purpose: a generic
	`Signal<T...>:Connect(...)` method runs into Luau strict-mode limits
	around generic packs on `self` methods, and quality-gate.md flags method
	chains off call results as a trap anyway -- returning a plain table of
	functions from `new()` sidesteps both.

	A plain module (name ends in neither Service nor Controller), so the
	Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.
]]

export type Connection = {
	Disconnect: () -> (),
}

export type Signal<T...> = {
	Connect: (listener: (T...) -> ()) -> Connection,
	Fire: (T...) -> (),
}

local function new<T...>(): Signal<T...>
	local listeners: { (T...) -> () } = {}

	local function connect(listener: (T...) -> ()): Connection
		table.insert(listeners, listener)
		local disconnected = false

		return {
			Disconnect = function()
				if disconnected then
					return
				end
				disconnected = true
				local index = table.find(listeners, listener)
				if index ~= nil then
					table.remove(listeners, index)
				end
			end,
		}
	end

	local function fire(...: T...)
		-- Snapshot first: a listener that connects/disconnects mid-fire must
		-- not perturb the list being iterated. Spawned so one slow/erroring
		-- listener never blocks or breaks the others.
		for _, listener in table.clone(listeners) do
			task.spawn(listener, ...)
		end
	end

	return {
		Connect = connect,
		Fire = fire,
	}
end

return {
	new = new,
}
