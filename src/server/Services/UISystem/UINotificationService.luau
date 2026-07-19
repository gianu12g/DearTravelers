--!strict
--[[
	Thin server->client push helpers for the UISystem port: a generic toast
	(SendNotification) and the confetti burst (EmitConfetti). Every other
	UISystem service that needs to tell one specific player something calls
	in here rather than touching Net.notify / Net.confettiEmit directly --
	one place to add e.g. rate limiting later, and it collapses the source's
	separate Notification and Conffeti packet namespaces (server/INDEX.md §4)
	into the one "tell the player" surface they always meant to be.

	No per-player state, no Init() -- every function below just forwards to
	Net for one player, and there's nothing to leak or clean up on
	PlayerRemoving.
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
