--!strict
--[[
	Group-membership reward. Ported from the source's
	Controllers/GroupRewardController.luau.

	The source's GroupReward.ClaimReward was an invoke returning whether the
	claim succeeded, and prompted the group-join dialog when it didn't
	(taken as "not a member yet"). Here that becomes groupClaimRequest /
	groupClaimResult (PORT-SPEC.md §3): on a failed result, prompt
	GroupService:PromptJoinAsync the same way. A successful claim doesn't
	need to touch the buttons directly -- {"UISystem","GroupReward"} flips
	server-side and the DataController.observe below repaints from that,
	same source of truth the rest of the UI already uses.
]]

local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local GeneralConfig = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("GroupRewardController")

local GroupRewardController = {}

--[[
	No Init() -- groupClaimResult only ever arrives in reply to a request
	THIS client sent, after the frame is resolved below; see
	WheelSpinController for the fuller reasoning.
]]
function GroupRewardController.Start()
	local frame = Frames.get("GroupReward")
	local redeemButton = frame:WaitForChild("Redeem") :: GuiButton
	local redeemedButton = frame:WaitForChild("Redeemed") :: GuiButton

	local function updateUi(inGroup: boolean)
		redeemButton.Visible = not inGroup
		redeemedButton.Visible = inGroup
	end

	DataController.observe({ "UISystem", "GroupReward" }, function(value: any)
		if type(value) ~= "boolean" then
			return
		end
		updateUi(value)
	end)

	Net.groupClaimResult.listen(function(data)
		if data.ok then
			return
		end
		pcall(function()
			GroupService:PromptJoinAsync(GeneralConfig.GroupID)
		end)
	end)

	redeemButton.MouseButton1Click:Connect(function()
		Net.groupClaimRequest.send()
	end)

	log.info("ready")
end

return GroupRewardController
