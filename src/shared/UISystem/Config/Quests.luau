--!strict
--[[
	Quest catalog: three independent tracks (Daily / Weekly / Monthly), each a
	list of goals over one METRIC that the server already emits during normal
	play. Shared, not server-only, because QuestsController renders descriptions
	and goals straight from here -- the client never needs the server to tell it
	what a quest IS, only how far along the player is.

	Rewards are granted AUTOMATICALLY the moment progress reaches the goal.
	There is deliberately no claim step: the authored quest row (Studio,
	Frames.Quests) has a description, a progress bar and a counter, and no claim
	button. Adding a claim flow would mean inventing UI that the design does not
	have, so the server just pays out and notifies.

	Ids are PERSISTED as table keys (see DataService's Quests subtree), so
	changing one orphans that quest's progress for every existing player.
	Retiring a quest is safe -- unknown ids are dropped on load. Renaming is
	what to avoid.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Quests = {}

--[[
	Every metric here is incremented from exactly one server-side call site, so
	"what counts" is never ambiguous:

	  Merges       one per completed merge -- manual (Carry.commitMerge) AND
	               auto-merge (AutoMerge.commitPair), since both produce the
	               same t+1 squishy and a player paying for Auto Merge should
	               not progress slower.
	  Launches     one per launch that actually resolves and lands.
	  CoinsEarned  every coin granted through CoinsService.add. That includes
	               passive income, offline income and quest payouts themselves.
	  Discoveries  one per NEWLY discovered model level (IndexService returns
	               true only on the first sighting), so re-owning a level the
	               player already has does not count.
	  Rebirths     one per completed rebirth.
]]
export type Metric = "Merges" | "Launches" | "CoinsEarned" | "Discoveries" | "Rebirths"

export type Reward = {
	Coins: number?,
	Tickets: number?,
}

export type Quest = {
	Id: string,
	Description: string,
	Metric: Metric,
	Goal: number,
	Reward: Reward,
}

export type Period = "Daily" | "Weekly" | "Monthly"

--[[
	Bound to a typed local before being attached to the module table. A cast
	written directly on the property assignment (`Quests.PERIODS = {...} ::
	{ Period }`) does not survive: Luau widens the string singletons back to
	plain `string`, and every `Catalog[period]` lookup downstream then fails to
	typecheck against the `{ [Period]: ... }` index.
]]
local PERIODS: { Period } = { "Daily", "Weekly", "Monthly" }
-- Display order, left to right, matching the authored tab buttons.
Quests.PERIODS = PERIODS

local CATALOG: { [Period]: { Quest } } = {
	Daily = {
		{
			Id = "daily_merge_100",
			Description = "Merge 100 Squishies!",
			Metric = "Merges",
			Goal = 100,
			Reward = { Coins = 5000 },
		},
		{
			Id = "daily_launch_10",
			Description = "Launch 10 Squishies!",
			Metric = "Launches",
			Goal = 10,
			Reward = { Coins = 3000 },
		},
		{
			Id = "daily_earn_50k",
			Description = "Earn 50,000 Cash!",
			Metric = "CoinsEarned",
			Goal = 50000,
			Reward = { Coins = 5000 },
		},
	},
	Weekly = {
		{
			Id = "weekly_merge_1k",
			Description = "Merge 1,000 Squishies!",
			Metric = "Merges",
			Goal = 1000,
			Reward = { Coins = 100000 },
		},
		{
			Id = "weekly_launch_100",
			Description = "Launch 100 Squishies!",
			Metric = "Launches",
			Goal = 100,
			Reward = { Coins = 75000 },
		},
		{
			Id = "weekly_discover_5",
			Description = "Discover 5 New Squishies!",
			Metric = "Discoveries",
			Goal = 5,
			Reward = { Tickets = 1 },
		},
	},
	Monthly = {
		{
			Id = "monthly_merge_10k",
			Description = "Merge 10,000 Squishies!",
			Metric = "Merges",
			Goal = 10000,
			Reward = { Coins = 1000000 },
		},
		{
			Id = "monthly_discover_15",
			Description = "Discover 15 New Squishies!",
			Metric = "Discoveries",
			Goal = 15,
			Reward = { Tickets = 3 },
		},
		{
			Id = "monthly_rebirth_2",
			Description = "Rebirth 2 Times!",
			Metric = "Rebirths",
			Goal = 2,
			Reward = { Coins = 500000 },
		},
	},
}
Quests.Catalog = CATALOG

--[[
	The identity of the CURRENT period, as a string key.

	Deliberately a formatted UTC date rather than a timestamp: comparing
	`stored ~= current` is then an exact calendar test with no interval
	arithmetic, no drift, and no "reset 24h after you first played" skew
	between players. os.date's `!` prefix forces UTC, so every server and every
	player rolls over at the same instant regardless of machine timezone.

	Known wart, accepted: %W is week-of-year with Monday as day one, and it
	restarts at each new year. A week straddling New Year therefore rolls over
	early, once a year. ISO week (%G-%V) would avoid it but is not reliably
	available across Luau's strftime, and one early weekly reset per year is a
	smaller cost than a subtly wrong custom week calculation.
]]
function Quests.periodKey(period: Period, now: number): string
	if period == "Daily" then
		return os.date("!%Y-%m-%d", now) :: string
	elseif period == "Weekly" then
		return os.date("!%Y-W%W", now) :: string
	end
	return os.date("!%Y-%m", now) :: string
end

-- Lookup by id across every track, for the server's increment path.
function Quests.find(questId: string): (Quest?, Period?)
	for _, period in PERIODS do
		for _, quest in CATALOG[period] do
			if quest.Id == questId then
				return quest, period
			end
		end
	end
	return nil, nil
end

return Quests
