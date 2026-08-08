--!strict
--[[
	Promo-code redemption. Ported from the source's
	Controllers/CodesController.luau.

	The source's Codes.RedeemCode was an invoke; here it's the
	codeRedeemRequest/codeRedeemResult pair (PORT-SPEC.md §3). The button is
	disabled for the round trip and re-enabled by a timeout even if the
	server never replies, so a dropped packet can't wedge it shut forever.

	The input no longer lives in its own Main.Frames.Codes frame -- it is an
	inline box inside the shop (Main.Frames.Shop.CodesFrame), so it is
	resolved off the Shop frame rather than through Frames.get("Codes").
	Main.Frames.Codes and the HUD button that opened it still exist in the
	Studio tree but are hidden and unwired; nothing here touches them.

	Living inside a frame that stays open after a redemption changes two
	things versus the old standalone popup: the box is cleared on success
	(otherwise the spent code sits there inviting an "Already Redeemed"), and
	Enter submits, since a player typing into an inline field expects that.
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
	local shopFrame = Frames.get("Shop")
	local codesFrame = shopFrame:WaitForChild("CodesFrame")
	local codeInput = codesFrame:WaitForChild("TextCode") :: TextBox
	local redeemButton = codesFrame:WaitForChild("Redeem") :: GuiButton

	local pending = false
	-- Bumped on every send so a stale timeout can only ever re-enable the
	-- request it was started for, never a newer one still in flight.
	local requestId = 0

	local function setPending(isPending: boolean)
		pending = isPending
		redeemButton.Interactable = not isPending
	end

	Net.codeRedeemResult.listen(function(data)
		setPending(false)
		if data.ok then
			codeInput.Text = ""
		end
		NotificationController.Notify(if data.ok then "Success" else "Error", data.message)
	end)

	local function submit()
		if pending then
			return
		end

		-- Codes get copy-pasted out of Discord/YouTube descriptions, which
		-- routinely drags surrounding whitespace along. The server lower-cases
		-- but does not trim, so an untrimmed paste would read as "Invalid Code".
		local code = (string.gsub(codeInput.Text, "^%s*(.-)%s*$", "%1"))
		if code == "" then
			NotificationController.Notify("Error", "Enter Code First")
			return
		end

		setPending(true)
		requestId += 1
		local thisRequestId = requestId
		Net.codeRedeemRequest.send({ code = code })

		task.delay(PENDING_TIMEOUT, function()
			if pending and requestId == thisRequestId then
				setPending(false)
			end
		end)
	end

	redeemButton.MouseButton1Click:Connect(submit)

	codeInput.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end)

	log.info("ready")
end

return CodesController
