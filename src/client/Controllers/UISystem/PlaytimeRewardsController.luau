--!strict
--[[
	Playtime-based reward UI. Ported from the source's
	Controllers/PlaytimeRewardsController.luau.

	Data shape mirrors src/server/Services/DataService.luau's TEMPLATE
	(PORT-SPEC.md §2) rather than the source's own 5-field state --
	{"UISystem","PlaytimeRewards"} = { StartTimestamp, StartPlaytime,
	ClaimedRewards }.

	FORMULA FIX: this used to estimate elapsed reward-eligible playtime as
	`(os.time() - StartTimestamp) + StartPlaytime`, a wall-clock guess that
	does not match what the server actually grants against. The server
	(PlaytimeRewardsService.luau) validates a claim with
	`Duration <= getPlaytime(player) - StartPlaytime`, where getPlaytime()
	is a live in-memory playtime counter (ticks every real second the
	player is connected, resets are separate from wall-clock session time)
	that gets flushed to the replicated {"UISystem","Playtime"} field only
	every ~20 seconds -- see PlaytimeRewardsService.luau's own header for
	why. The basis is therefore ACCUMULATED PLAYTIME SINCE the reward
	track's last reset, not time since StartTimestamp.

	To track that without a packet every second, this module keeps a
	`baseline` (replicated Playtime minus PlaytimeRewards.StartPlaytime, as
	of the last time either replicated) plus an os.clock() delta ticked
	locally between flushes -- see `recapture`/`elapsedRewardPlaytime`
	below. That converges on the server's true value at every flush of
	either field and never overshoots it in between, since both sides tick
	at the same real-time rate.

	Bug fix (PORT-SPEC.md §5.3): the source declared its UpdateUi as
	`function UpdateUi()` with no `local`, an accidental global; here it's a
	local like every other function in this module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local PlaytimeRewardsConfig = require(ReplicatedStorage.Shared.UISystem.Config.PlaytimeRewards)

local log = Log.new("PlaytimeRewardsController")

type PlaytimeRewardsData = {
	StartTimestamp: number,
	StartPlaytime: number,
	ClaimedRewards: { [number]: boolean },
}

local data: PlaytimeRewardsData = { StartTimestamp = 0, StartPlaytime = 0, ClaimedRewards = {} }

-- The last replicated {"UISystem","Playtime"} value (PlaytimeRewardsService's
-- live counter, flushed every ~20s -- see the header comment above).
local livePlaytime = 0
-- livePlaytime - data.StartPlaytime, captured whenever either replicates.
local baseline = 0
local captureClock = os.clock()

-- Re-derives `baseline` from the current `livePlaytime`/`data` and resets the
-- local tick origin. Call after either replicated field changes.
local function recapture()
	baseline = livePlaytime - data.StartPlaytime
	captureClock = os.clock()
end

-- Accumulated reward-eligible playtime since the track's last reset, matching
-- the server's `getPlaytime(player) - StartPlaytime` basis exactly at each
-- flush and ticking smoothly in between via a monotonic os.clock() delta.
local function elapsedRewardPlaytime(): number
	return baseline + (os.clock() - captureClock)
end

local PlaytimeRewardsController = {}

local function updateUi(container: Instance)
	local elapsed = elapsedRewardPlaytime()

	for index, info in PlaytimeRewardsConfig.Rewards do
		local ui = container:FindFirstChild(tostring(index))
		if ui == nil then
			continue
		end

		local locked = ui:FindFirstChild("Locked")
		local redeem = ui:FindFirstChild("Redeem")
		local countdown = ui:FindFirstChild("Countdown")

		if data.ClaimedRewards[index] then
			if locked ~= nil and locked:IsA("GuiObject") then
				locked.Visible = false
			end
			if redeem ~= nil and redeem:IsA("GuiObject") then
				redeem.Visible = true
				local label = redeem:FindFirstChild("TextLabel")
				if label ~= nil and label:IsA("TextLabel") then
					label.Text = "CLAIMED"
				end
			end
			if countdown ~= nil and countdown:IsA("GuiObject") then
				countdown.Visible = false
			end
			continue
		end

		local leftTime = info.Duration - elapsed

		if leftTime > 0 then
			if locked ~= nil and locked:IsA("GuiObject") then
				locked.Visible = true
			end
			if redeem ~= nil and redeem:IsA("GuiObject") then
				redeem.Visible = false
			end
			if countdown ~= nil and countdown:IsA("TextLabel") then
				countdown.Text = Format.FormatTime(leftTime)
				countdown.Visible = true
			end
		else
			if redeem ~= nil and redeem:IsA("GuiObject") then
				redeem.Visible = true
				local label = redeem:FindFirstChild("TextLabel")
				if label ~= nil and label:IsA("TextLabel") then
					label.Text = "CLAIM"
				end
			end
			if locked ~= nil and locked:IsA("GuiObject") then
				locked.Visible = false
			end
			if countdown ~= nil and countdown:IsA("TextLabel") then
				countdown.Text = "READY"
			end
		end
	end
end

function PlaytimeRewardsController.Start()
	local frame = Frames.get("PlaytimeRewards")
	local container = frame:WaitForChild("Holder")

	for index in PlaytimeRewardsConfig.Rewards do
		local ui = container:FindFirstChild(tostring(index))
		if ui == nil then
			continue
		end
		local redeem = ui:FindFirstChild("Redeem")
		if redeem ~= nil and redeem:IsA("GuiButton") then
			redeem.MouseButton1Click:Connect(function()
				Net.playtimeClaim.send({ index = index })
			end)
		end
	end

	DataController.observe({ "UISystem", "Playtime" }, function(value: any)
		if type(value) ~= "number" then
			return
		end
		livePlaytime = value
		recapture()
		updateUi(container)
	end)

	DataController.observe({ "UISystem", "PlaytimeRewards" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		data = value
		recapture()
		updateUi(container)
	end)

	log.info("ready")

	while true do
		updateUi(container)
		task.wait(1)
	end
end

return PlaytimeRewardsController
