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
	Net.notify.sendTo({ kind = kind, message = message }, player)
end

function UINotificationService.EmitConfetti(player: Player)
	Net.confettiEmit.sendTo(nil, player)
end

function UINotificationService.Start()
	log.info("ready")
end

return UINotificationService
