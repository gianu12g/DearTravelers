--!strict
--[[
	Phase 3: passive income and the activity checkpoint. See runTick's own
	note for the full reasoning behind the aggregated-grant shape. `liveBases`
	is owned by init.luau and handed to this module once via Income.setup()
	-- see Spawning.luau's own note on the same pattern. `incomeRemainders` is
	this module's own state: nothing outside Income needs it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CoinsService = require(script.Parent.Parent.CoinsService)
local DataService = require(script.Parent.Parent.DataService)
local Net = require(ReplicatedStorage.Shared.Net)
local SquishyProgress = require(ServerStorage.Modules.SquishyProgress)
local Types = require(script.Parent.Types)

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
}

-- Set once by Income.setup(), called from init.Init(). See Spawning.luau's
-- own header note on why this is a reference to an init-owned table.
local liveBases: { [Player]: Types.LiveBase } = nil :: any

-- Coins are integer-owned, while 25% rebirth bonuses can produce quarters.
-- Carry each player's fractional remainder across online pulses so a $1
-- model at 1.25x pays $5 over four seconds instead of being floored back to
-- $1 forever. The remainder is always < 1 coin and intentionally session-only.
local incomeRemainders: { [Player]: number } = {}

local Income = {}

function Income.setup(deps: Deps)
	liveBases = deps.liveBases
end

-- Called from onPlayerRemoving: forgets this player's fractional remainder
-- entirely so the table does not carry a stale entry for a Player instance
-- that will never rejoin.
function Income.clearPlayer(player: Player)
	incomeRemainders[player] = nil
end

-- Rebirth resets the player's whole cash-producing state. This fractional
-- carry is not persisted currency, but retaining it after Coins and every
-- squishy are wiped would leak a pre-rebirth fraction into the new run.
function Income.resetRemainder(player: Player)
	incomeRemainders[player] = nil
end

--[[
	Phase 3: passive income. One grant per player per INCOME_INTERVAL, summed
	over every entry in THEIR data.Merge.Squishies (not live.parts) -- data is
	the source of truth, and reading it directly is what makes this include a
	currently-carried object for free: carry.entry is the SAME table as its
	entry in data.Merge.Squishies the entire time it's carried (the init.luau
	header's PHASE 2 note), so there is nothing special to do here for that
	case.

	liveBases (not Players:GetPlayers()) is the population: a player with no
	live pad -- not yet activated, data still loading, base released -- earns
	nothing and errors nothing, because they were never iterated.

	One CoinsService.add() call per player, not one per object: that is the
	entire reason this is a sum-then-grant instead of a loop of individual
	grants, per the perf budget (8 players * 25 objects must not mean 200
	writes a second).

	The sum is capped at MAX_OBJECTS entries because profile data is
	attacker-influenced over a long enough time horizon (developer tools, old
	versions, or a migration bug), and a planted oversized array must not earn
	income without bound.
]]
function Income.runTick()
	for player in liveBases do
		local data = DataService.getData(player)
		if data == nil then
			continue -- not expected once a pad is live, but never error over it
		end

		local cashMultiplier = if player:GetAttribute("CashMultiplier") == 2 then 2 else 1
		local exactTotal = SquishyProgress.incomePerPulse(data.Merge.Squishies, data.Rebirths) * cashMultiplier
			+ (incomeRemainders[player] or 0)
		local total = math.floor(exactTotal)
		incomeRemainders[player] = exactTotal - total

		if total > 0 and CoinsService.add(player, total) then
			Net.mergeIncomePulse.sendTo(nil, player)
		end
	end
end

-- Periodically moves the trusted activity timestamp forward for every loaded
-- player. Clean leaves write an exact timestamp in DataService; this cheaper
-- checkpoint bounds duplicate earnings if a session ends uncleanly.
function Income.checkpointLastActive()
	local now = os.time()
	for _, player in Players:GetPlayers() do
		if DataService.getData(player) ~= nil then
			DataService.set(player, { "Merge", "LastActiveAt" }, now)
		end
	end
end

return Income
