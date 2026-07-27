--!strict
--[[
	Binds the Studio-authored Rebirth frame to replicated player data.

	The UI displays the exponential player-facing tier number
	(2 ^ (model level - 1)), while eligibility and progress use sequential
	model levels. The Cash reward card and every placeholder icon remain
	entirely Studio-owned.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local UIKitController = require(script.Parent.UIKitController)

local log = Log.new("RebirthController")

local RebirthController = {}

function RebirthController.Start()
	local frame = Frames.get("Rebirth")
	local top = frame:WaitForChild("Top")
	local rebirthProgress = top:WaitForChild("Progress") :: TextLabel

	local holder = frame:WaitForChild("Holder")
	local goal = holder:WaitForChild("Goal")
	local progressBar = goal:WaitForChild("ProgressBar") :: GuiObject
	local fillBar = progressBar:WaitForChild("FillBar") :: GuiObject
	local goalLabel = progressBar:WaitForChild("TextLabel") :: TextLabel
	local buyRebirth = holder:WaitForChild("BuyRebirth") :: GuiButton

	local rewards = holder:WaitForChild("Rewards")
	local rewardsList = rewards:WaitForChild("RewardsList")
	local rewardLabels: { TextLabel } = {}
	for index = 1, RebirthConfig.MODEL_LEVELS_PER_REBIRTH do
		local rewardFrame = rewardsList:WaitForChild(`{index}Tier`)
		rewardLabels[index] = rewardFrame:WaitForChild("TextLabel") :: TextLabel
	end

	local currentRebirths = 0
	local currentSquishies: any = {}

	local function render()
		local rebirths = RebirthConfig.sanitizeRebirths(currentRebirths)
		local requiredModelLevel = RebirthConfig.maxModelLevel(rebirths)
		local bestModelLevel = math.min(RebirthConfig.bestModelLevel(currentSquishies), requiredModelLevel)
		local progress = math.clamp(bestModelLevel / requiredModelLevel, 0, 1)
		local percentage = math.floor(progress * 100 + 0.5)

		rebirthProgress.Text = `{rebirths}/{RebirthConfig.MAX_REBIRTHS}`
		goalLabel.Text =
			`Tier {Format.FormatNumber(RebirthConfig.tierNumberForModelLevel(bestModelLevel))}/{Format.FormatNumber(
				RebirthConfig.tierNumberForModelLevel(requiredModelLevel)
			)} - {percentage}%`
		fillBar.Size = UDim2.new(progress, 0, fillBar.Size.Y.Scale, fillBar.Size.Y.Offset)

		for index, rewardLabel in rewardLabels do
			if rebirths >= RebirthConfig.MAX_REBIRTHS then
				rewardLabel.Text = "MAX"
			else
				local unlockedModelLevel = requiredModelLevel + index
				rewardLabel.Text =
					`Tier {Format.FormatNumber(RebirthConfig.tierNumberForModelLevel(unlockedModelLevel))}`
			end
		end
	end

	DataController.observe({ "Rebirths" }, function(value, oldValue)
		local nextRebirths = if type(value) == "number" then value else 0
		if type(oldValue) == "number" and nextRebirths > oldValue then
			UIKitController.CloseCurrentFrame(true)
		end

		currentRebirths = nextRebirths
		render()
	end)

	DataController.observe({ "Merge", "Squishies" }, function(value)
		currentSquishies = if type(value) == "table" then value else {}
		render()
	end)

	buyRebirth.MouseButton1Click:Connect(function()
		Net.rebirthRequest.send()
	end)

	render()
	log.info("ready")
end

return RebirthController
