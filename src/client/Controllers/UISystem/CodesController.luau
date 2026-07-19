--!strict
--[[
	Promo-code redemption. Ported from the source's
	Controllers/CodesController.luau.

	The source's Codes.RedeemCode was an invoke; here it's the
	codeRedeemRequest/codeRedeemResult pair (PORT-SPEC.md §3). The button is
	disabled for the round trip and re-enabled by a timeout even if the
	server never replies, so a dropped packet can't wedge it shut forever.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local NotificationController = require(script.Parent.NotificationController)

local log = Log.new("CodesController")

local PENDING_TIMEOUT = 8

local CodesController = {}

--[[
	No Init() -- codeRedeemResult only ever arrives in reply to a request
	THIS client sent after the button below is wired, and resolving the
	frame needs yielding WaitForChild calls Init() must never do (see
	WheelSpinController for the same reasoning).
]]
function CodesController.Start()
	local frame = Frames.get("Codes")
	local codeInput = frame:WaitForChild("TextCode") :: TextBox
	local redeemButton = frame:WaitForChild("Redeem") :: GuiButton

	local pending = false

	local function setPending(isPending: boolean)
		pending = isPending
		redeemButton.Interactable = not isPending
	end

	Net.codeRedeemResult.listen(function(data)
		setPending(false)
		NotificationController.Notify(if data.ok then "Success" else "Error", data.message)
	end)

	redeemButton.MouseButton1Click:Connect(function()
		if pending then
			return
		end

		local code = codeInput.Text
		if code == "" then
			NotificationController.Notify("Error", "Enter Code First")
			return
		end

		setPending(true)
		Net.codeRedeemRequest.send({ code = code })

		task.delay(PENDING_TIMEOUT, function()
			if pending then
				setPending(false)
			end
		end)
	end)

	log.info("ready")
end

return CodesController
