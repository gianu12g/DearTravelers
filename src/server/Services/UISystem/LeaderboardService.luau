--!strict
--[[
	Cash (now Coins, PORT-SPEC.md §2) leaderboard via an OrderedDataStore,
	refreshing a physical SurfaceGui model (PORT-SPEC.md §1, source
	ServerScriptService.Services.LeaderboardService).

	Hard physical-instance dependency (PORT-SPEC.md §6, server/INDEX.md
	§6.10): workspace.Leaderboard.Main.SurfaceGui.ScrollingFrame with
	template rows named RankTemplate1..RankTemplate4 -- PascalCase per this
	repo's naming rules, renamed in Studio from the source's default "1".."4"
	names. If that model (or any piece of it) is missing on this server, the
	leaderboard is inert: log a warning and disable rather than erroring the
	whole boot over a display feature.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("LeaderboardService")

local MAX_ENTRIES = 100
local REFRESH_INTERVAL_SECONDS = 20
local SAVE_INTERVAL_SECONDS = 10
local TEMPLATE_NAMES = { "RankTemplate1", "RankTemplate2", "RankTemplate3", "RankTemplate4" }

local coinsStore = DataStoreService:GetOrderedDataStore("Coins")

type Row = {
	frame: Instance,
	playerName: TextLabel?,
	value: TextLabel?,
	rank: TextLabel?,
}

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
	local ok, pages = pcall(function()
		return coinsStore:GetSortedAsync(false, MAX_ENTRIES)
	end)

	if not ok then
		log.warn("failed to load leaderboard page")
		return
	end

	local data = pages:GetCurrentPage()

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
			local username = "Unknown"
			local userId = tonumber(entry.key)
			if userId ~= nil then
				pcall(function()
					username = Players:GetNameFromUserIdAsync(userId)
				end)
			end
			row.playerName.Text = username
		end

		if row.value ~= nil then
			row.value.Text = Format.FormatNumber(entry.value)
		end

		if row.rank ~= nil then
			row.rank.Text = `#{rank}`
		end
	end
end

local function startPlayerSaves(player: Player)
	task.spawn(function()
		while player.Parent == Players do
			task.wait(SAVE_INTERVAL_SECONDS)

			local data = DataService.getData(player)
			if data == nil then
				continue
			end

			pcall(function()
				coinsStore:SetAsync(tostring(player.UserId), data.Coins)
			end)
		end
	end)
end

local LeaderboardService = {}

function LeaderboardService.Start()
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

	for _, player in Players:GetPlayers() do
		startPlayerSaves(player)
	end
	Players.PlayerAdded:Connect(startPlayerSaves)

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
