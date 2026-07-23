--!strict
--[[
	Every sound asset ID in the codebase lives here, one named entry per
	unique ID. Everything listed is preloaded at boot via
	`AssetIds/Preloader.luau` plus the loading screen.

	Monetization IDs (PassID/GiftID/ProductID, GroupID/Admins) are NOT content
	assets and must never be added here -- see Config/Passes.luau,
	Config/Products.luau, Config/Packs.luau, Config/General.luau.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Sounds = {
	UiHover = 139800881181209, -- "ui-simple-button-hover" -- UIKitController default hover
	UiClick = 88442833509532, -- "ui-simple-button-click" -- UIKitController default click
	UiClose = 74657965144290, -- "ui-simple-inventory-close" -- UIKitController UiClose click
	UiMoney = 1210852193, -- "Coins ka-ching" -- UIKitController Money click
	NotificationSuccess = 124743961969068, -- "Success" -- NotificationController
	NotificationError = 137500936341394, -- "Fail" -- NotificationController
	NotificationInfo = 74379627889513, -- "Click" -- NotificationController
	KeyPress = 84953529887338, -- "Keyboard e" -- KeyCapsController key click
	MusicLifeInAnElevator = 1841647093, -- "Life in an Elevator" -- ambient playlist
	MusicRelaxedScene = 1848354536, -- "Relaxed Scene" -- ambient playlist
	MusicShiawase = 5409360995, -- "Dion Timmer - Shiawase" -- ambient playlist
}

export type Sounds = typeof(Sounds)

return Sounds
