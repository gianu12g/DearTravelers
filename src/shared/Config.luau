--!strict
--[[
	Who gets the developer console, and why that answer isn't a list in this file.

	The developer list is deliberately NOT here. It lives in the group's role
	config on create.roblox.com -- add someone to a role at rank >= 254 ("Owner2")
	and they have the console on their next join. No code change, no republish.

	Why 254 and not 100 (chosen by the owner): rank 255 is Roblox-reserved for
	exactly one account, the group owner, so 254 is the highest rank that can
	hold more than one person. That's what makes "add a developer" possible at
	all -- 255 can't.

	GetRankInGroup is cached per machine for the session. Someone promoted while
	already in-game keeps their OLD rank until they rejoin. That's Roblox's
	behaviour, not a bug here.

	isDeveloper fails closed on purpose: a transient group-API blip denies
	access rather than granting it (same shape as quality-gate.md's "unhandled
	InvokeServer error" trap, just with a group API instead of a RemoteFunction).

	ALLOW_IN_STUDIO grants nothing new: anyone who can open this place in Studio
	already has the command bar, which is strictly more powerful than this
	console. It reads false on every live server, because IsStudio() does.

	Safe to put in a shared module: group IDs and ranks are public, and
	GetRankInGroup is client-callable anyway. Secrecy is not the control here --
	the server-side re-check in DevService is.
]]

local RunService = game:GetService("RunService")

local Config = {}

Config.GROUP_ID = 36093973
Config.DEVELOPER_RANK = 254
Config.ALLOW_IN_STUDIO = true

function Config.isDeveloper(player: Player): boolean
	if Config.ALLOW_IN_STUDIO and RunService:IsStudio() then
		return true
	end

	local ok, rank = pcall(player.GetRankInGroup, player, Config.GROUP_ID)
	if not ok then
		return false
	end

	return rank >= Config.DEVELOPER_RANK
end

return Config
