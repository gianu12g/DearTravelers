--!strict
--[[
	Logical-name -> PlayerGui.Main.Frames.* indirection. Ported from the
	source's Controllers/UiController/Frames.luau (there a child ModuleScript
	of UiController; here a standalone plain module, since every UISystem
	controller needs it, not just UIKitController).

	Deliberately lazy, unlike the source (which indexed the frames straight
	off `Player.PlayerGui:WaitForChild("Main")` at module-body scope). Every
	*Controller that needs a frame requires this module at its own top level,
	and that require runs during Loader.collect() -- BEFORE any Init() and
	well before PlayerGui.Main necessarily exists (StarterGui only clones
	into PlayerGui once the character/UI has spawned; see
	Controllers/UIController.luau's own note on this race). An eager
	WaitForChild at module-body scope would block the ENTIRE loader, for
	every controller, until that clone happens. Frames.get() defers the
	yield to whichever controller actually calls it, which in practice means
	Start() -- exactly where ARCHITECTURE.md says yielding is fine.

	Also survives PlayerGui wipes: StarterGui.ResetPlayerGuiOnSpawn (on by
	default) destroys and re-clones the whole PlayerGui on every respawn, so
	a cached instance can go stale. get() checks .Parent and re-resolves
	rather than handing back a dead reference.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer

export type FrameName =
	"Shop"
	| "GiftPlayerChoose"
	| "GiftConfirm"
	| "PlaytimeRewards"
	| "DailyRewards"
	| "Codes"
	| "GroupReward"
	| "WheelSpin"
	| "Settings"
	| "FriendInvite"

-- Logical name -> the actual Studio-authored child name under Main.Frames.
local STUDIO_NAMES: { [FrameName]: string } = {
	Shop = "Shop",
	GiftPlayerChoose = "Gifting",
	GiftConfirm = "Confirm",
	PlaytimeRewards = "TimeRewards",
	DailyRewards = "DailyRewards",
	Codes = "Codes",
	GroupReward = "Group",
	WheelSpin = "Wheel",
	Settings = "Settings",
	FriendInvite = "Friends",
}

local cache: { [FrameName]: Frame } = {}

local Frames = {}

--[[
	Runtime guard for a value coming off a Studio attribute (Ui-Frame) or
	over the wire -- both are `unknown` strings at best, never actually typed
	as FrameName until this passes.
]]
function Frames.isFrameName(name: string): boolean
	return STUDIO_NAMES[name :: FrameName] ~= nil
end

--[[
	Resolves (and caches) the Frame for a logical name. Yields on a cold
	cache or after a PlayerGui wipe -- call from Start(), not Init().
]]
function Frames.get(name: FrameName): Frame
	local cached = cache[name]
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end

	local studioName = STUDIO_NAMES[name]

	local playerGui = player:WaitForChild("PlayerGui")
	local main = playerGui:WaitForChild("Main")
	local framesFolder = main:WaitForChild("Frames")
	local frame = framesFolder:WaitForChild(studioName) :: Frame

	cache[name] = frame
	return frame
end

return Frames
