--!strict
--[[
	Thin server-to-client helpers for the active UISystem toast and confetti
	effects. Services call in here rather than touching Net.notify or
	Net.confettiEmit directly, keeping one "tell the player" surface.

	No per-player state and no Init(): every function just forwards to Net, so
	there is nothing to leak or clean up on PlayerRemoving.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("UINotificationService")

local UINotificationService = {}

function UINotificationService.SendNotification(player: Player, kind: string, message: string)
	local ok, sendError = pcall(function()
		Net.notify.sendTo({ kind = kind, message = message }, player)
	end)
	if not ok then
		-- Notifications are best-effort presentation. A departed client or
		-- transient networking error must never unwind a paid receipt/message
		-- handler after its durable reward mutation.
		log.warn(`notification send failed for {player.Name}: {tostring(sendError)}`)
	end
end

function UINotificationService.EmitConfetti(player: Player)
	local ok, sendError = pcall(function()
		Net.confettiEmit.sendTo(nil, player)
	end)
	if not ok then
		log.warn(`confetti send failed for {player.Name}: {tostring(sendError)}`)
	end
end

function UINotificationService.Start()
	log.info("ready")
end

return UINotificationService
