--!strict
--[[
	Daily login-streak reward UI. Ported from the source's
	Controllers/DailyRewardsController.luau.

	Data shape mirrors src/server/Services/DataService.luau's TEMPLATE
	(PORT-SPEC.md §2) rather than the source's own field names --
	{"UISystem","DailyRewards"} = { StartTimestamp, ClaimedRewards }, no
	other fields. Bug fix (PORT-SPEC.md §5.3): the source declared its
	UpdateUi as `function UpdateUi()` with no `local`, an accidental global;
	here it's a local like every other function in this module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyRewardsConfig = require(ReplicatedStorage.Shared.UISystem.Config.DailyRewards)
local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("DailyRewardsController")

type DailyRewardsData = {
	StartTimestamp: number,
	ClaimedRewards: { [number]: boolean },
}

local DAY_SECONDS = 24 * 60 * 60

local data: DailyRewardsData = { StartTimestamp = 0, ClaimedRewards = {} }

local DailyRewardsController = {}

local function updateUi(container: Instance)
	local now = os.time()
	local totalTime = now - data.StartTimestamp

	for i = 1, 7 do
		local ui = container:FindFirstChild(tostring(i))
		if ui == nil then
			continue
		end

		local locked = ui:FindFirstChild("Locked")
		local redeem = ui:FindFirstChild("Redeem")
		local dayText = ui:FindFirstChild("DayText")

		if data.ClaimedRewards[i] then
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
			if dayText ~= nil and dayText:IsA("TextLabel") then
				dayText.Text = `Day {i}`
			end
			continue
		end

		local leftTime = ((i - 1) * DAY_SECONDS) - totalTime
		if leftTime > DAY_SECONDS then
			if redeem ~= nil and redeem:IsA("GuiObject") then
				redeem.Visible = false
			end
			if locked ~= nil and locked:IsA("GuiObject") then
				locked.Visible = true
			end
			if dayText ~= nil and dayText:IsA("TextLabel") then
				dayText.Text = `Day {i}`
			end
			continue
		elseif leftTime > 0 then
			if redeem ~= nil and redeem:IsA("GuiObject") then
				redeem.Visible = false
			end
			if locked ~= nil and locked:IsA("GuiObject") then
				locked.Visible = true
			end
			if dayText ~= nil and dayText:IsA("TextLabel") then
				dayText.Text = Format.FormatTime(leftTime)
			end
			continue
		end

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
	end
end

function DailyRewardsController.Start()
	local frame = Frames.get("DailyRewards")
	local container = frame:WaitForChild("Holder")

	for _, item in container:GetChildren() do
		if not item:IsA("Frame") then
			continue
		end
		local index = tonumber(item.Name)
		if index == nil then
			continue
		end
		local info = DailyRewardsConfig[index]
		if info == nil then
			continue
		end
		local decor = item:FindFirstChild("Decor")
		if decor ~= nil then
			local icon = decor:FindFirstChild("Icon")
			if icon ~= nil and icon:IsA("ImageLabel") then
				icon.Image = `rbxassetid://{info.Icon}`
			end
		end
		local rewardText = item:FindFirstChild("RewardText")
		if rewardText ~= nil and rewardText:IsA("TextLabel") then
			rewardText.Text = info.Text
		end
	end

	for i = 1, 7 do
		local ui = container:FindFirstChild(tostring(i))
		if ui == nil then
			continue
		end
		local redeem = ui:FindFirstChild("Redeem")
		if redeem ~= nil and redeem:IsA("GuiButton") then
			redeem.MouseButton1Click:Connect(function()
				Net.dailyClaim.send({ index = i })
			end)
		end
	end

	DataController.observe({ "UISystem", "DailyRewards" }, function(value: any)
		if type(value) ~= "table" then
			return
		end
		data = value
		updateUi(container)
	end)

	log.info("ready")

	while true do
		updateUi(container)
		task.wait(1)
	end
end

return DailyRewardsController
