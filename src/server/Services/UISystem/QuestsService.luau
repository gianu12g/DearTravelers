--!strict
--[[
	Quest progress authority: period rollover, metric accumulation, and the
	automatic payout when a goal is reached.

	The only public entry point is `award(player, metric, amount)`. Gameplay code
	calls it with a verb it just performed; nothing outside this file knows which
	quests exist, which period they belong to, or whether one just completed.
	That keeps the hooks in MergeService/CoinsService/etc. one line each.

	ROLLOVER is lazy, not scheduled. Every award() and every join compares the
	track's stored PeriodKey against the current calendar key (Config/Quests
	.periodKey) and wipes that track if they differ. No timers, no midnight job,
	nothing to miss if the server restarts across a boundary -- and a player who
	is mid-session when the day flips gets the reset on their very next action.

	PAYOUT is automatic. See Config/Quests's header for why there is no claim
	step: the authored quest row has no claim button.

	CYCLE NOTE: CoinsService calls award() (for the CoinsEarned metric) and this
	service calls CoinsService.add() to pay out. Luau throws on a cyclic require
	at load, so CoinsService is bound in Init() using the deferred pattern
	documented in Loader.luau's header rather than required at module scope.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local QuestsConfig = require(ReplicatedStorage.Shared.UISystem.Config.Quests)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

-- Deferred to break the CoinsService <-> QuestsService cycle; see the header.
local CoinsService: typeof(require(ServerStorage.Services.CoinsService)) = nil :: any

local log = Log.new("QuestsService")

-- Tickets share UISystem.Tickets with the ThemeShop. Bounded here for the same
-- reason DataService bounds it: a reward table typo must not mint 2^53 tickets.
local MAX_TICKETS = 2 ^ 31 - 1

local QuestsService = {}

type Track = {
	PeriodKey: string,
	Progress: { [string]: number },
	Rewarded: { [string]: boolean },
}

--[[
	Resets `period` if the calendar has moved on. Returns the live track either
	way, or nil when the player's data is not loaded.

	Writes the whole track in ONE DataService.set rather than three: a client
	observing {"Quests", period} must never see the new PeriodKey next to the
	previous period's progress, which is exactly the half-committed state that
	would make a stale bar look complete.
]]
local function rollTrack(player: Player, period: QuestsConfig.Period, now: number): Track?
	local data = DataService.getData(player)
	if data == nil then
		return nil
	end

	local track = (data.Quests :: any)[period] :: Track
	local currentKey = QuestsConfig.periodKey(period, now)
	if track.PeriodKey == currentKey then
		return track
	end

	local fresh: Track = { PeriodKey = currentKey, Progress = {}, Rewarded = {} }
	DataService.set(player, { "Quests", period }, fresh)
	-- Re-read: DataService.set replaces the table the profile holds, so the
	-- local `fresh` and the replicated one are the same object, but reading it
	-- back keeps this honest if that ever stops being true.
	return ((DataService.getData(player) :: any).Quests :: any)[period] :: Track
end

local function grantReward(player: Player, quest: QuestsConfig.Quest): boolean
	local reward = quest.Reward
	local granted = false

	local coins = reward.Coins
	if coins ~= nil and coins > 0 then
		if CoinsService == nil or not CoinsService.add(player, coins) then
			log.warn(`could not pay {coins} coins for "{quest.Id}" to {player.Name}`)
			return false
		end
		granted = true
	end

	local tickets = reward.Tickets
	if tickets ~= nil and tickets > 0 then
		local data = DataService.getData(player)
		if data == nil then
			return false
		end
		-- Read-modify-write with no yield between (quality-gate trap #5).
		local current = data.UISystem.Tickets
		if type(current) ~= "number" or current ~= current then
			current = 0
		end
		DataService.set(player, { "UISystem", "Tickets" }, math.min(current + tickets, MAX_TICKETS))
		granted = true
	end

	return granted
end

--[[
	Adds `amount` to every currently-active quest tracking `metric`, across all
	three periods, and pays out any that just reached their goal.

	`amount` is server-supplied at every call site (a merge is 1, a coin grant is
	the amount CoinsService just validated), so it is guarded rather than
	sanitized: a non-positive or non-finite value is a bug at the caller, not
	hostile input, and silently ignoring it beats corrupting a counter.

	Yield-free. Callers include MergeService's read-modify-write merge
	transactions, which are only safe because nothing between their read and
	their write yields.
]]
function QuestsService.award(player: Player, metric: QuestsConfig.Metric, amount: number)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
		return
	end
	local whole = math.floor(amount)
	if whole <= 0 then
		return
	end

	local now = os.time()
	for _, period in QuestsConfig.PERIODS do
		local track = rollTrack(player, period, now)
		if track == nil then
			return
		end

		for _, quest in QuestsConfig.Catalog[period] do
			if quest.Metric ~= metric or track.Rewarded[quest.Id] then
				continue
			end

			local previous = track.Progress[quest.Id] or 0
			if previous >= quest.Goal then
				continue
			end
			local updated = math.min(previous + whole, quest.Goal)
			DataService.set(player, { "Quests", period, "Progress", quest.Id }, updated)

			if updated >= quest.Goal then
				-- Mark BEFORE paying: grantReward calls CoinsService.add, which
				-- awards the CoinsEarned metric, which re-enters this function.
				-- Without the flag already set, that re-entry would see an
				-- unrewarded complete quest and pay it a second time.
				DataService.set(player, { "Quests", period, "Rewarded", quest.Id }, true)
				if grantReward(player, quest) then
					UINotificationService.SendNotification(player, "Success", `Quest complete: {quest.Description}`)
				end
			end
		end
	end
end

function QuestsService.Init()
	CoinsService = require(ServerStorage.Services.CoinsService)
end

function QuestsService.Start()
	-- Roll every track once on join so a player who was away across a boundary
	-- sees an empty board immediately, rather than only after their first merge.
	SafePlayerAdded(function(player: Player)
		if not DataService.awaitData(player, 120) then
			return
		end
		local now = os.time()
		for _, period in QuestsConfig.PERIODS do
			rollTrack(player, period, now)
		end
	end)

	log.info("ready")
end

return QuestsService
