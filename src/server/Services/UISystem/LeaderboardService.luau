--!strict
--[[
	Cash (now Coins, PORT-SPEC.md §2) leaderboard via an OrderedDataStore,
	refreshing a physical SurfaceGui model (PORT-SPEC.md §1, source
	ServerScriptService.Services.LeaderboardService).

	Hard physical-instance dependency (PORT-SPEC.md §6, server/INDEX.md
	§6.10): workspace.Leaderboard.Main.SurfaceGui.ScrollingFrame with
	template rows named RankTemplate1..RankTemplate4 -- PascalCase per this
	repo's naming rules, renamed in Studio from the source's default "1".."4"
	names. If that model (or any piece of it) is missing on this server, score
	publication continues while only the display is disabled; a cosmetic map
	dependency must not create gaps in the global ranking.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local UserService = game:GetService("UserService")
local Workspace = game:GetService("Workspace")

local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("LeaderboardService")

local MAX_ENTRIES = 100
local REFRESH_INTERVAL_SECONDS = 60
local SAVE_INTERVAL_SECONDS = 60
local USERNAME_CACHE_SECONDS = 3600
local USERNAME_FAILURE_CACHE_SECONDS = 60
local TEMPLATE_NAMES = { "RankTemplate1", "RankTemplate2", "RankTemplate3", "RankTemplate4" }

local coinsStore = DataStoreService:GetOrderedDataStore("Coins")

type Row = {
	frame: Instance,
	playerName: TextLabel?,
	value: TextLabel?,
	rank: TextLabel?,
}

type UsernameCacheEntry = {
	name: string,
	expiresAt: number,
}

local usernameCache: { [number]: UsernameCacheEntry } = {}
local lastSavedCoins: { [number]: number } = {}
local observedCoins: { [number]: number } = {}
local queuedCoins: { [number]: number } = {}
local writing: { [number]: true } = {}

local function getCachedUsername(userId: number): string
	local cached = usernameCache[userId]
	return if cached ~= nil then cached.name else "Unknown"
end

-- Coalesces writes by user. If coins change while one SetAsync is yielding,
-- the worker immediately writes the newest queued value next instead of
-- spawning overlapping requests that can land out of order.
local function requestSave(userId: number, coins: number)
	queuedCoins[userId] = coins
	if writing[userId] then
		return
	end
	writing[userId] = true

	task.spawn(function()
		while queuedCoins[userId] ~= nil do
			local value = queuedCoins[userId]
			queuedCoins[userId] = nil
			if lastSavedCoins[userId] == value then
				continue
			end

			local ok, err = pcall(function()
				coinsStore:SetAsync(tostring(userId), value)
			end)
			if ok then
				lastSavedCoins[userId] = value
			else
				log.warn(`failed to save leaderboard coins for userId {userId}: {tostring(err)}`)
			end
		end
		writing[userId] = nil
		if Players:GetPlayerByUserId(userId) == nil then
			lastSavedCoins[userId] = nil
		end
	end)
end

local function getTemplate(templates: { Instance }, rank: number): Instance
	if rank <= 3 then
		return templates[rank]
	end
	return templates[4]
end

local function createRows(scrollingFrame: ScrollingFrame, templates: { Instance }): { Row }
	local rows: { Row } = {}

	for rank = 1, MAX_ENTRIES do
		local entry = getTemplate(templates, rank):Clone()
		entry.Name = `Rank{rank}`
		if entry:IsA("GuiObject") then
			entry.LayoutOrder = rank
			entry.Visible = false
		end
		entry.Parent = scrollingFrame

		local playerNameChild = entry:FindFirstChild("UserName", true)
		local valueChild = entry:FindFirstChild("Amount", true)
		local rankChild = entry:FindFirstChild("Rank", true)

		rows[rank] = {
			frame = entry,
			playerName = if playerNameChild ~= nil and playerNameChild:IsA("TextLabel") then playerNameChild else nil,
			value = if valueChild ~= nil and valueChild:IsA("TextLabel") then valueChild else nil,
			rank = if rankChild ~= nil and rankChild:IsA("TextLabel") then rankChild else nil,
		}
	end

	return rows
end

local function updateLeaderboard(rows: { Row })
	local now = os.clock()
	for userId, cached in usernameCache do
		if cached.expiresAt <= now then
			usernameCache[userId] = nil
		end
	end

	local ok, pages = pcall(function()
		return coinsStore:GetSortedAsync(false, MAX_ENTRIES)
	end)

	if not ok then
		log.warn(`failed to load leaderboard page: {tostring(pages)}`)
		return
	end

	local data = pages:GetCurrentPage()
	local unresolvedIds: { number } = {}
	local unresolvedSet: { [number]: true } = {}
	for _, entry in data do
		local userId = tonumber(entry.key)
		if userId ~= nil and usernameCache[userId] == nil and not unresolvedSet[userId] then
			unresolvedSet[userId] = true
			table.insert(unresolvedIds, userId)
		end
	end

	if #unresolvedIds > 0 then
		-- UserService resolves the whole page in one request; doing one
		-- GetNameFromUserIdAsync per row creates a 100-request startup burst in
		-- every server that owns a physical leaderboard.
		local namesOk, userInfos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(unresolvedIds)
		end)
		local expiresAt = os.clock() + (if namesOk then USERNAME_CACHE_SECONDS else USERNAME_FAILURE_CACHE_SECONDS)
		if namesOk then
			for _, info in userInfos do
				if type(info.Id) == "number" and type(info.Username) == "string" then
					usernameCache[info.Id] = { name = info.Username, expiresAt = expiresAt }
					unresolvedSet[info.Id] = nil
				end
			end
		end
		for userId in unresolvedSet do
			usernameCache[userId] = { name = "Unknown", expiresAt = expiresAt }
		end
	end

	for rank = 1, MAX_ENTRIES do
		local row = rows[rank]
		local entry = data[rank]

		if row.frame:IsA("GuiObject") then
			row.frame.Visible = entry ~= nil
		end

		if entry == nil then
			continue
		end

		if row.playerName ~= nil then
			local userId = tonumber(entry.key)
			row.playerName.Text = if userId ~= nil then getCachedUsername(userId) else "Unknown"
		end

		if row.value ~= nil then
			row.value.Text = Format.FormatNumber(entry.value)
		end

		if row.rank ~= nil then
			row.rank.Text = `#{rank}`
		end
	end
end

local function observePlayer(player: Player)
	task.spawn(function()
		if not DataService.awaitData(player, 120) then
			return
		end
		local data = DataService.getData(player)
		if data ~= nil then
			observedCoins[player.UserId] = data.Coins
			requestSave(player.UserId, data.Coins)
		end
	end)
end

local LeaderboardService = {}

function LeaderboardService.Start()
	-- OrderedDataStore publication is independent of the optional physical
	-- display. Every server contributes scores even in places/maps that do not
	-- mount a leaderboard model.
	for _, player in Players:GetPlayers() do
		observePlayer(player)
	end
	Players.PlayerAdded:Connect(observePlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local data = DataService.getData(player)
		local coins = if data ~= nil then data.Coins else observedCoins[player.UserId]
		if coins ~= nil then
			requestSave(player.UserId, coins)
		end
		observedCoins[player.UserId] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL_SECONDS)
			for _, player in Players:GetPlayers() do
				local data = DataService.getData(player)
				if data ~= nil then
					observedCoins[player.UserId] = data.Coins
					requestSave(player.UserId, data.Coins)
				end
			end
		end
	end)

	local leaderboardModel = Workspace:FindFirstChild("Leaderboard")
	if leaderboardModel == nil then
		log.warn("workspace.Leaderboard is missing -- leaderboard disabled")
		return
	end

	local main = leaderboardModel:FindFirstChild("Main")
	if main == nil then
		log.warn("workspace.Leaderboard.Main is missing -- leaderboard disabled")
		return
	end

	local surfaceGuiInstance = main:FindFirstChild("SurfaceGui")
	if surfaceGuiInstance == nil then
		log.warn("workspace.Leaderboard.Main.SurfaceGui is missing -- leaderboard disabled")
		return
	end

	local scrollingFrameInstance = surfaceGuiInstance:FindFirstChild("ScrollingFrame")
	if scrollingFrameInstance == nil or not scrollingFrameInstance:IsA("ScrollingFrame") then
		log.warn("workspace.Leaderboard.Main.SurfaceGui.ScrollingFrame is missing -- leaderboard disabled")
		return
	end
	local scrollingFrame: ScrollingFrame = scrollingFrameInstance

	local templates: { Instance } = {}
	for i, name in TEMPLATE_NAMES do
		local template = scrollingFrame:FindFirstChild(name)
		if template == nil then
			log.warn(`workspace.Leaderboard is missing template "{name}" -- leaderboard disabled`)
			return
		end
		templates[i] = template
		template.Parent = nil
	end

	local rows = createRows(scrollingFrame, templates)

	task.spawn(function()
		updateLeaderboard(rows)
		while true do
			task.wait(REFRESH_INTERVAL_SECONDS)
			updateLeaderboard(rows)
		end
	end)

	log.info("ready")
end

return LeaderboardService
