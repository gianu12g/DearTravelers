--!strict
--[[
	Client side of the data layer.

	Replica hands you a plain table (replica.Data) that the server keeps in sync,
	plus listeners that fire when a path changes. That's the whole model.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Replica = require(ReplicatedStorage.ReplicaClient)

local log = Log.new("DataController")

local player = Players.LocalPlayer

local DataController = {
	Priority = 100,
}

local dataReplica: any = nil
local readyWaiters: { thread } = {}

function DataController.Init()
	--[[
		Register in Init, NOT Start. OnNew does not replay replicas that already
		arrived -- if the replica lands before this listener exists, you miss it
		permanently and silently.

		Main.client.luau calls Replica.RequestData() only after every Init() has
		run, so this listener is guaranteed live before the server sends anything.
		That ordering is the entire reason Init and Start are separate phases.
	]]
	Replica.OnNew("PlayerData", function(replica)
		-- Tags are set once server-side at creation and never change.
		if replica.Tags.UserId ~= player.UserId then
			return -- not ours (won't happen today; cheap guard if that changes)
		end

		dataReplica = replica
		log.info("player data received")

		for _, thread in readyWaiters do
			task.spawn(thread)
		end
		table.clear(readyWaiters)
	end)
end

--[[
	Yields until the replica has arrived. Returns false on timeout.

	This is the per-player readiness gate, and it replaces a global "wait for the
	server to boot" flag. It's better for a specific reason: "the server booted"
	and "MY data is here" are different facts. A player joining a 40-minute-old
	server would sail straight past a global flag that flipped ages ago and read
	an empty table. The gap between those two facts is exactly where the "coins
	show 0 for half a second" bug lives.
]]
function DataController.await(timeout: number?): boolean
	if dataReplica ~= nil then
		return true
	end

	local thread = coroutine.running()
	table.insert(readyWaiters, thread)

	local timedOut = false
	if timeout ~= nil then
		task.delay(timeout, function()
			if dataReplica ~= nil then
				return -- already resumed by OnNew; must not resume twice
			end
			local index = table.find(readyWaiters, thread)
			if index ~= nil then
				table.remove(readyWaiters, index)
				timedOut = true
				task.spawn(thread)
			end
		end)
	end

	coroutine.yield()
	return not timedOut
end

-- The replicated table. nil until await() returns.
function DataController.getData(): any?
	return if dataReplica ~= nil then dataReplica.Data else nil
end

--[[
	Fires when a path changes, AND immediately with the current value -- so a UI
	binding is one call with no "connect, then also read once" boilerplate, and
	no first frame showing the Studio placeholder text.

		DataController.observe({"Coins"}, function(coins)
			label.Text = `{coins}`
		end)
]]
function DataController.observe(path: { string | number }, listener: (value: any, old: any?) -> ())
	task.spawn(function()
		if not DataController.await(30) then
			log.warn(`observe({table.concat(path :: any, ".")}) timed out waiting for data`)
			return
		end

		dataReplica:OnSet(path, listener)

		-- Fire once with the value that's already there.
		local current: any = dataReplica.Data
		for _, key in path do
			if current == nil then
				break
			end
			current = current[key]
		end
		listener(current, nil)
	end)
end

return DataController
