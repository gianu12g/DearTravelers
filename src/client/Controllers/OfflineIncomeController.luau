--!strict
--[[
	Shows the replicated receipt for the offline grant prepared before the
	player's data replica is created. No remote is used: the receipt is durable
	state, so it cannot be lost if the client UI initializes after the server
	finishes loading the profile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local NotificationController = require(script.Parent.UISystem.NotificationController)

local OfflineIncomeController = {}

local shownAwardedAt = 0

function OfflineIncomeController.Start()
	DataController.observe({ "Merge", "OfflineEarnings" }, function(receipt)
		if type(receipt) ~= "table" then
			return
		end

		local amount = receipt.Amount
		local seconds = receipt.Seconds
		local awardedAt = receipt.AwardedAt
		if type(amount) ~= "number" or type(seconds) ~= "number" or type(awardedAt) ~= "number" then
			return
		end
		if amount <= 0 or awardedAt <= shownAwardedAt then
			return
		end

		shownAwardedAt = awardedAt
		NotificationController.Notify(
			"Success",
			`Welcome back! Your squishies earned ${Format.FormatNumber(amount)} over {Format.FormatTime(seconds)}.`
		)
	end)
end

return OfflineIncomeController
