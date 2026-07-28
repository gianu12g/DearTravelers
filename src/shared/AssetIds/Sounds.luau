--!strict
--[[
	Every sound asset ID in the codebase lives here, one named entry per
	unique ID. Everything listed is preloaded at boot via
	`AssetIds/Preloader.luau` plus the loading screen.

	Each entry is a table so per-sound playback settings can sit next to the
	ID. `Start` is the one that exists today: seconds of dead air trimmed off
	the head of the upload, so the clip lands on its transient instead of
	arriving late. Omit it for assets that already start clean -- tuning it is
	a one-number edit here, no call site involved.

	Apply entries through `AssetIds/SoundKit.luau` rather than reading `.Id`
	by hand: it is what turns `Start` into actual playback behavior, so a
	hand-rolled `rbxassetid://` silently ignores the trim.

	Monetization IDs (PassID/GiftID/ProductID, GroupID/Admins) are NOT content
	assets and must never be added here -- see Config/Passes.luau,
	Config/Products.luau, Config/Packs.luau, Config/General.luau.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

export type Entry = {
	Id: number,
	-- Seconds skipped at the start of the clip, on every play. Optional.
	Start: number?,
}

local Sounds = {
	UiHover = { Id = 139800881181209 }, -- "ui-simple-button-hover" -- UIKitController default hover
	UiClick = { Id = 88442833509532 }, -- "ui-simple-button-click" -- UIKitController default click
	UiClose = { Id = 74657965144290 }, -- "ui-simple-inventory-close" -- UIKitController UiClose click
	UiMoney = { Id = 1210852193 }, -- "Coins ka-ching" -- UIKitController Money click
	NotificationSuccess = { Id = 124743961969068 }, -- "Success" -- NotificationController
	NotificationError = { Id = 137500936341394 }, -- "Fail" -- NotificationController
	NotificationInfo = { Id = 74379627889513 }, -- "Click" -- NotificationController
	KeyPress = { Id = 84953529887338 }, -- "Keyboard e" -- KeyCapsController key click
	MergeSquishyA = { Id = 125536824124728, Start = 0.1 }, -- squishy merge pop -- MergeVfxController (random pick)
	MergeSquishyB = { Id = 125536824124728, Start = 0.1 }, -- squishy merge pop -- MergeVfxController (random pick)
	SquishyLand = { Id = 130134863677489, Start = 0 }, -- launch touchdown thud -- MergeService.Launch
	SquishyPop = { Id = 125375534049465, Start = 0.1 }, -- launcher-only impact pop -- LaunchVfxController
	MusicLifeInAnElevator = { Id = 1841647093 }, -- "Life in an Elevator" -- ambient playlist
	MusicRelaxedScene = { Id = 1848354536 }, -- "Relaxed Scene" -- ambient playlist
	MusicShiawase = { Id = 5409360995 }, -- "Dion Timmer - Shiawase" -- ambient playlist
}

export type Sounds = typeof(Sounds)

return Sounds
