--!strict
--[[
	Playtime-gated reward track (PORT-SPEC.md §1, source
	ServerScriptService.Services.PlaytimeRewardsService).

	PLAYTIME TICKING TRADEOFF (PORT-SPEC.md instructions): the source wrote
	profile.Playtime through its replication layer every 1 second, for every
	online player. Doing that here would mean a Replica :Set() -- one
	replication packet -- every second per player, forever, for a field
	nothing needs sub-flush-interval precision on. Instead this service keeps
	an in-memory {start timestamp, base playtime} pair per player and
	computes the live value on demand (getPlaytime); the profile's Playtime
	field is flushed via DataService.set only every FLUSH_INTERVAL_SECONDS
	and on PlayerRemoving/BindToClose. Claims validate against the live
	in-memory value (getPlaytime), never the possibly-stale saved one, so a
	claim is never wrongly blocked by an unflushed profile. Anything else
	that needs live playtime (WheelSpinService's free-spin cadence) should
	call getPlaytime() too, not read the profile directly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PlaytimeRewardFunctions = require(ServerStorage.Modules.UISystem.PlaytimeRewardFunctions)
local PlaytimeRewardsConfig = require(ReplicatedStorage.Shared.UISystem.Config.PlaytimeRewards)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local UINotificationService = require(ServerStorage.Services.UISystem.UINotificationService)

local log = Log.new("PlaytimeRewardsService")

local FLUSH_INTERVAL_SECONDS = 20

local function newClaimedRewards(): { boolean }
	return table.create(#PlaytimeRewardsConfig.Rewards, false)
end

type LiveState = {
	startTimestamp: number,
	basePlaytime: number,
}

--[[
	The profile's PlaytimeRewards subtable, cast once at the point of use.
	ClaimedRewards defaults to {} in TEMPLATE (an empty table literal infers
	as the empty-table type, not an indexed map), so reading it without this
	cast would not typecheck under --!strict; StartTimestamp/StartPlaytime
	are plain numbers either way. Verified against DataService.luau's
	TEMPLATE shape directly (ARCHITECTURE.md's Data section), not guessed.
]]
type PlaytimeRewardsData = {
	StartTimestamp: number,
	StartPlaytime: number,
	ClaimedRewards: { [number]: boolean },
}

local live: { [Player]: LiveState } = {}

-- See FriendRewardService.luau's identical helper for why this polling wait
-- exists: DataService.getData(player) returns nil until the async
-- ProfileStore session load finishes.
local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

local PlaytimeRewardsService = {}
local claimLimiter = RateLimiter.new(1, 2)

--[[
	The live, up-to-the-second playtime for `player`, or nil if this service
	has no tracking state for them (not loaded yet, or already left). Other
	UISystem services should read THIS, not the profile's Playtime field --
	see the tradeoff note above.
]]
function PlaytimeRewardsService.getPlaytime(player: Player): number?
	local state = live[player]
	if state == nil then
		return nil
	end
	return state.basePlaytime + (os.time() - state.startTimestamp)
end

local function flush(player: Player)
	local state = live[player]
	if state == nil then
		return
	end
	local playtime = state.basePlaytime + (os.time() - state.startTimestamp)
	DataService.set(player, { "UISystem", "Playtime" }, playtime)
end

local function resetIfStale(player: Player)
	local data = DataService.getData(player)
	local state = live[player]
	if data == nil or state == nil then
		return
	end

	local rewards = (data.UISystem.PlaytimeRewards :: any) :: PlaytimeRewardsData
	if os.time() - rewards.StartTimestamp < PlaytimeRewardsConfig.Config.ResetDuration then
		return
	end

	local playtime = state.basePlaytime + (os.time() - state.startTimestamp)
	DataService.setValues(player, { "UISystem", "PlaytimeRewards" }, {
		StartTimestamp = os.time(),
		StartPlaytime = playtime,
		ClaimedRewards = newClaimedRewards(),
	})
end

function PlaytimeRewardsService.Init()
	Net.playtimeClaim.listen(function(data, player)
		if player == nil or not claimLimiter:allow(player) then
			return
		end

		local index = data.index
		if typeof(index) ~= "number" or index < 1 or index > #PlaytimeRewardsConfig.Rewards then
			return
		end

		local rewardFunction = PlaytimeRewardFunctions[index]
		if rewardFunction == nil then
			return
		end

		local playerData = DataService.getData(player)
		local playtime = PlaytimeRewardsService.getPlaytime(player)
		if playerData == nil or playtime == nil then
			return
		end

		local rewards = (playerData.UISystem.PlaytimeRewards :: any) :: PlaytimeRewardsData
		if rewards.ClaimedRewards[index] then
			return
		end

		local rewardsPlaytime = playtime - rewards.StartPlaytime
		if PlaytimeRewardsConfig.Rewards[index].Duration > rewardsPlaytime then
			return
		end

		local claimed = table.clone(rewards.ClaimedRewards)
		claimed[index] = true
		local ok, rewarded = pcall(rewardFunction, player)
		if not ok or not rewarded then
			log.warn(`reward function for playtime index {index} rejected the claim for {player.Name}`)
			UINotificationService.SendNotification(player, "Error", "This reward is not available yet")
			return
		end

		DataService.set(player, { "UISystem", "PlaytimeRewards", "ClaimedRewards" }, claimed)
		UINotificationService.SendNotification(player, "Success", "Successfully claimed")
	end)
end

function PlaytimeRewardsService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		flush(player)
		live[player] = nil
	end)

	game:BindToClose(function()
		for player in live do
			flush(player)
		end
	end)

	SafePlayerAdded(function(player: Player)
		local data = waitForData(player)
		if data == nil then
			return
		end

		live[player] = { startTimestamp = os.time(), basePlaytime = data.UISystem.Playtime }
		resetIfStale(player)

		while player.Parent == Players and live[player] ~= nil do
			task.wait(FLUSH_INTERVAL_SECONDS)
			if live[player] == nil then
				break
			end
			flush(player)
			resetIfStale(player)
		end
	end)

	log.info("ready")
end

return PlaytimeRewardsService
