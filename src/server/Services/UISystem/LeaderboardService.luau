--!strict
--[[
	Global physical leaderboards, fanned out to every tagged board in Workspace.

	The map has eight bases with three boards beside each base, but there are
	still only three logical leaderboards. Each refresh reads one page per
	metric, resolves the union of usernames, then applies the same immutable
	snapshot to every board with that metric's tag. Adding more physical copies
	therefore adds no DataStore reads and no username requests.

	Tag the root of each board with exactly one of:
	  LeaderboardCoins
	  LeaderboardIncome
	  LeaderboardPlaytime

	The tagged root may be a Model, BasePart, SurfaceGui, or the ScrollingFrame
	itself. Somewhere beneath it must be a ScrollingFrame containing the four
	hidden row templates RankTemplate1..RankTemplate4. Rows must expose nested
	TextLabels named UserName, Amount, and Rank. An optional TextLabel named
	LeaderboardTitle or Title is populated from the metric definition.
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local PlaytimeRewardsService = require(ServerStorage.Services.UISystem.PlaytimeRewardsService)
local SquishyProgress = require(ServerStorage.Modules.SquishyProgress)

local log = Log.new("LeaderboardService")

-- Ten entries fit a glanceable physical board. Across 24 boards this creates
-- 240 live rows instead of the previous configuration's potential 2,400.
local MAX_ENTRIES = 10
local REFRESH_INTERVAL_SECONDS = 60
local SAVE_INTERVAL_SECONDS = 60
local USERNAME_CACHE_SECONDS = 3600
local USERNAME_FAILURE_CACHE_SECONDS = 60
local USERNAME_BATCH_SIZE = 100
local SHUTDOWN_WRITE_TIMEOUT_SECONDS = 8
local MAX_ORDERED_SCORE = 2 ^ 53 - 1
local GENERATED_ROW_ATTRIBUTE = "LeaderboardGeneratedRow"
local TEMPLATE_NAMES = { "RankTemplate1", "RankTemplate2", "RankTemplate3", "RankTemplate4" }
local TITLE_NAMES = { "LeaderboardTitle", "Title" }

type MetricDefinition = {
	id: string,
	tag: string,
	storeName: string,
	title: string,
	getScore: (Player, DataService.PlayerData) -> number,
	formatScore: (number) -> string,
}

type SnapshotEntry = {
	userId: number,
	name: string,
	score: number,
}

type RawEntry = {
	userId: number,
	score: number,
}

type Row = {
	frame: GuiObject,
	playerName: TextLabel?,
	value: TextLabel?,
	rank: TextLabel?,
}

type Board = {
	root: Instance,
	rows: { Row },
}

type MetricState = {
	definition: MetricDefinition,
	store: OrderedDataStore,
	lastSaved: { [number]: number },
	observed: { [number]: number },
	queued: { [number]: number },
	writing: { [number]: true },
	boards: { [Instance]: Board },
	snapshot: { SnapshotEntry },
}

type UsernameCacheEntry = {
	name: string,
	expiresAt: number,
}

local function getPlaytimeScore(player: Player, data: DataService.PlayerData): number
	return PlaytimeRewardsService.getPlaytime(player) or data.UISystem.Playtime
end

local METRIC_DEFINITIONS: { MetricDefinition } = {
	{
		id = "Coins",
		tag = "LeaderboardCoins",
		storeName = "Coins", -- Preserve the existing production leaderboard.
		title = "TOP COINS",
		getScore = function(_player: Player, data: DataService.PlayerData): number
			return data.Coins
		end,
		formatScore = Format.FormatNumber,
	},
	{
		id = "Income",
		tag = "LeaderboardIncome",
		storeName = "Leaderboard_Income_v1",
		title = "TOP INCOME",
		getScore = function(_player: Player, data: DataService.PlayerData): number
			return SquishyProgress.incomePerPulse(data.Merge.Squishies)
		end,
		formatScore = function(value: number): string
			return `{Format.FormatNumber(value)}/s`
		end,
	},
	{
		id = "Playtime",
		tag = "LeaderboardPlaytime",
		storeName = "Leaderboard_Playtime_v1",
		title = "MOST PLAYTIME",
		getScore = getPlaytimeScore,
		formatScore = Format.FormatTime,
	},
}

local metrics: { MetricState } = {}
for _, definition in METRIC_DEFINITIONS do
	table.insert(metrics, {
		definition = definition,
		store = DataStoreService:GetOrderedDataStore(definition.storeName),
		lastSaved = {},
		observed = {},
		queued = {},
		writing = {},
		boards = {},
		snapshot = {},
	})
end

local usernameCache: { [number]: UsernameCacheEntry } = {}
local mountedMetricByRoot: { [Instance]: MetricState } = {}
local warnedMultipleTags: { [Instance]: true } = {}

local function normalizeScore(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, MAX_ORDERED_SCORE)
end

local function scorePlayer(metric: MetricState, player: Player, data: DataService.PlayerData): number
	return normalizeScore(metric.definition.getScore(player, data))
end

-- Coalesce writes by metric and user. If a score changes while SetAsync is
-- yielding, the worker writes only the newest queued value next.
local function requestSave(metric: MetricState, userId: number, score: number)
	metric.queued[userId] = score
	if metric.writing[userId] then
		return
	end
	metric.writing[userId] = true

	task.spawn(function()
		while metric.queued[userId] ~= nil do
			local value = metric.queued[userId]
			metric.queued[userId] = nil
			if metric.lastSaved[userId] == value then
				continue
			end

			local ok, err = pcall(function()
				metric.store:SetAsync(tostring(userId), value)
			end)
			if ok then
				metric.lastSaved[userId] = value
			else
				log.warn(`failed to save {metric.definition.id} leaderboard score for userId {userId}: {tostring(err)}`)
			end
		end

		metric.writing[userId] = nil
		if Players:GetPlayerByUserId(userId) == nil then
			metric.lastSaved[userId] = nil
		end
	end)
end

local function getTemplate(templates: { GuiObject }, rank: number): GuiObject
	if rank <= 3 then
		return templates[rank]
	end
	return templates[4]
end

local function findScrollingFrame(root: Instance): ScrollingFrame?
	if root:IsA("ScrollingFrame") then
		return root
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ScrollingFrame") then
			return descendant
		end
	end
	return nil
end

local function findTextLabel(root: Instance, name: string): TextLabel?
	local child = root:FindFirstChild(name, true)
	return if child ~= nil and child:IsA("TextLabel") then child else nil
end

local function setBoardTitle(root: Instance, definition: MetricDefinition)
	local customTitle = root:GetAttribute("LeaderboardTitle")
	local title = if type(customTitle) == "string" and customTitle ~= "" then customTitle else definition.title

	for _, titleName in TITLE_NAMES do
		local titleLabel = findTextLabel(root, titleName)
		if titleLabel ~= nil then
			titleLabel.Text = title
			return
		end
	end
end

local function createRows(scrollingFrame: ScrollingFrame): { Row }?
	-- Clean up only rows created by this service. Authored decorations and
	-- layouts in the ScrollingFrame remain untouched.
	for _, child in scrollingFrame:GetChildren() do
		if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
			child:Destroy()
		end
	end

	local templates: { GuiObject } = {}
	for index, name in TEMPLATE_NAMES do
		local template = scrollingFrame:FindFirstChild(name)
		if template == nil or not template:IsA("GuiObject") then
			return nil
		end
		template.Visible = false
		templates[index] = template
	end

	local rows: { Row } = {}
	for rank = 1, MAX_ENTRIES do
		local entry = getTemplate(templates, rank):Clone()
		entry.Name = `LeaderboardRank{rank}`
		entry.LayoutOrder = rank
		entry.Visible = false
		entry:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
		entry.Parent = scrollingFrame

		rows[rank] = {
			frame = entry,
			playerName = findTextLabel(entry, "UserName"),
			value = findTextLabel(entry, "Amount"),
			rank = findTextLabel(entry, "Rank"),
		}
	end

	return rows
end

local function renderBoard(board: Board, metric: MetricState)
	for rank = 1, MAX_ENTRIES do
		local row = board.rows[rank]
		local entry = metric.snapshot[rank]
		row.frame.Visible = entry ~= nil

		if entry == nil then
			continue
		end
		if row.playerName ~= nil then
			row.playerName.Text = entry.name
		end
		if row.value ~= nil then
			row.value.Text = metric.definition.formatScore(entry.score)
		end
		if row.rank ~= nil then
			row.rank.Text = `#{rank}`
		end
	end
end

local function unmountBoard(root: Instance)
	local metric = mountedMetricByRoot[root]
	if metric == nil then
		return
	end

	local board = metric.boards[root]
	metric.boards[root] = nil
	mountedMetricByRoot[root] = nil
	if board ~= nil then
		for _, row in board.rows do
			row.frame:Destroy()
		end
	end
end

local function mountBoard(metric: MetricState, root: Instance)
	if not root:IsDescendantOf(Workspace) then
		return
	end

	local scrollingFrame = findScrollingFrame(root)
	if scrollingFrame == nil then
		log.warn(`{root:GetFullName()} has tag {metric.definition.tag} but no ScrollingFrame`)
		return
	end

	local rows = createRows(scrollingFrame)
	if rows == nil then
		log.warn(`{root:GetFullName()} is missing one or more GuiObject templates RankTemplate1..RankTemplate4`)
		return
	end

	local board: Board = { root = root, rows = rows }
	metric.boards[root] = board
	mountedMetricByRoot[root] = metric
	setBoardTitle(root, metric.definition)
	renderBoard(board, metric)
end

local function reconcileBoard(root: Instance)
	local selected: MetricState? = nil
	local tagCount = 0
	for _, metric in metrics do
		if CollectionService:HasTag(root, metric.definition.tag) then
			tagCount += 1
			if selected == nil then
				selected = metric
			end
		end
	end

	if tagCount > 1 and selected ~= nil then
		if not warnedMultipleTags[root] then
			warnedMultipleTags[root] = true
			log.warn(`{root:GetFullName()} has multiple leaderboard tags; using {selected.definition.tag}`)
		end
	else
		warnedMultipleTags[root] = nil
	end

	local current = mountedMetricByRoot[root]
	if current == selected then
		return
	end
	if current ~= nil then
		unmountBoard(root)
	end
	if selected ~= nil then
		mountBoard(selected, root)
	end
end

local function pruneUsernameCache()
	local now = os.clock()
	for userId, cached in usernameCache do
		if cached.expiresAt <= now then
			usernameCache[userId] = nil
		end
	end
end

local function resolveUsernames(rawByMetric: { [MetricState]: { RawEntry } })
	pruneUsernameCache()

	local unresolvedIds: { number } = {}
	local unresolvedSet: { [number]: true } = {}
	for _, rawEntries in rawByMetric do
		for _, entry in rawEntries do
			if usernameCache[entry.userId] == nil and not unresolvedSet[entry.userId] then
				unresolvedSet[entry.userId] = true
				table.insert(unresolvedIds, entry.userId)
			end
		end
	end

	for first = 1, #unresolvedIds, USERNAME_BATCH_SIZE do
		local batch: { number } = {}
		local batchSet: { [number]: true } = {}
		for index = first, math.min(first + USERNAME_BATCH_SIZE - 1, #unresolvedIds) do
			local userId = unresolvedIds[index]
			table.insert(batch, userId)
			batchSet[userId] = true
		end

		local ok, userInfos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(batch)
		end)
		local expiresAt = os.clock() + (if ok then USERNAME_CACHE_SECONDS else USERNAME_FAILURE_CACHE_SECONDS)
		if ok then
			for _, info in userInfos do
				if type(info.Id) == "number" and type(info.Username) == "string" then
					usernameCache[info.Id] = { name = info.Username, expiresAt = expiresAt }
					batchSet[info.Id] = nil
				end
			end
		end
		for userId in batchSet do
			usernameCache[userId] = { name = "Unknown", expiresAt = expiresAt }
		end
	end
end

local function fetchMetric(metric: MetricState): { RawEntry }?
	local ok, pages = pcall(function()
		return metric.store:GetSortedAsync(false, MAX_ENTRIES)
	end)
	if not ok then
		log.warn(`failed to load {metric.definition.id} leaderboard: {tostring(pages)}`)
		return nil
	end

	local rawEntries: { RawEntry } = {}
	for _, entry in pages:GetCurrentPage() do
		local userId = tonumber(entry.key)
		if userId ~= nil and userId > 0 and userId == math.floor(userId) and userId <= MAX_ORDERED_SCORE then
			table.insert(rawEntries, {
				userId = userId,
				score = normalizeScore(entry.value),
			})
		end
	end
	return rawEntries
end

local function refreshAllLeaderboards()
	local rawByMetric: { [MetricState]: { RawEntry } } = {}
	for _, metric in metrics do
		local rawEntries = fetchMetric(metric)
		if rawEntries ~= nil then
			rawByMetric[metric] = rawEntries
		end
	end

	resolveUsernames(rawByMetric)
	for metric, rawEntries in rawByMetric do
		local snapshot: { SnapshotEntry } = {}
		for _, entry in rawEntries do
			local cached = usernameCache[entry.userId]
			table.insert(snapshot, {
				userId = entry.userId,
				name = if cached ~= nil then cached.name else "Unknown",
				score = entry.score,
			})
		end
		metric.snapshot = snapshot
		for _, board in metric.boards do
			renderBoard(board, metric)
		end
	end
end

local function publishPlayer(player: Player, data: DataService.PlayerData?)
	for _, metric in metrics do
		local score: number? = nil
		if data ~= nil then
			score = scorePlayer(metric, player, data)
		elseif metric.definition.id == "Playtime" then
			local livePlaytime = PlaytimeRewardsService.getPlaytime(player)
			if livePlaytime ~= nil then
				score = normalizeScore(livePlaytime)
			else
				score = metric.observed[player.UserId]
			end
		else
			score = metric.observed[player.UserId]
		end

		if score ~= nil then
			metric.observed[player.UserId] = score
			requestSave(metric, player.UserId, score)
		end
	end
end

local function observePlayer(player: Player)
	usernameCache[player.UserId] = { name = player.Name, expiresAt = os.clock() + USERNAME_CACHE_SECONDS }
	task.spawn(function()
		if not DataService.awaitData(player, 120) then
			return
		end
		local data = DataService.getData(player)
		if data ~= nil then
			publishPlayer(player, data)
		end
	end)
end

local function anyWritePending(): boolean
	for _, metric in metrics do
		if next(metric.writing) ~= nil then
			return true
		end
	end
	return false
end

local LeaderboardService = {}

function LeaderboardService.Start()
	-- Wire tag signals before taking the initial snapshot so a board added
	-- during setup cannot be missed between GetTagged and Connect.
	for _, metric in metrics do
		CollectionService:GetInstanceAddedSignal(metric.definition.tag):Connect(function(root: Instance)
			reconcileBoard(root)
		end)
		CollectionService:GetInstanceRemovedSignal(metric.definition.tag):Connect(function(root: Instance)
			reconcileBoard(root)
		end)
	end
	for _, metric in metrics do
		for _, root in CollectionService:GetTagged(metric.definition.tag) do
			reconcileBoard(root)
		end
	end

	for _, player in Players:GetPlayers() do
		observePlayer(player)
	end
	Players.PlayerAdded:Connect(observePlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		publishPlayer(player, DataService.getData(player))
		for _, metric in metrics do
			metric.observed[player.UserId] = nil
		end
	end)

	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL_SECONDS)
			for _, player in Players:GetPlayers() do
				local data = DataService.getData(player)
				if data ~= nil then
					publishPlayer(player, data)
				end
			end
		end
	end)

	task.spawn(function()
		refreshAllLeaderboards()
		while true do
			task.wait(REFRESH_INTERVAL_SECONDS)
			refreshAllLeaderboards()
		end
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			publishPlayer(player, DataService.getData(player))
		end

		local deadline = os.clock() + SHUTDOWN_WRITE_TIMEOUT_SECONDS
		while anyWritePending() and os.clock() < deadline do
			task.wait(0.1)
		end
		if anyWritePending() then
			log.warn("leaderboard writes were still pending at shutdown timeout")
		end
	end)

	local boardCount = 0
	for _ in mountedMetricByRoot do
		boardCount += 1
	end
	log.info(`ready ({boardCount} tagged boards, {#metrics} shared metrics)`)
end

return LeaderboardService
