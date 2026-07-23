--!strict
--[[
	Every image asset ID in the codebase lives here, one named entry per
	unique ID. Everything listed is preloaded at boot via
	`AssetIds/Preloader.luau` plus the loading screen.

	Monetization IDs (PassID/GiftID/ProductID, GroupID/Admins) are NOT content
	assets and must never be added here -- see Config/Passes.luau,
	Config/Products.luau, Config/Packs.luau, Config/General.luau.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Images = {
	LaunchTarget = 72382621618473, -- LaunchController drop-target marker icon
	TopbarSettings = 106769461169677, -- TopbarUIController topbar button that opens Settings
	DailyRewardDay1 = 73989013612789, -- DailyRewards day 1
	SecretPack = 88132060004695, -- DailyRewards day 2 + Promotion "Secret Pack"
	DailyRewardDay3 = 135629275004235, -- DailyRewards day 3
	StarterPack = 73167539394400, -- DailyRewards day 4 + Promotion "Starter Pack"
	Cash = 110024503496390, -- DailyRewards day 5 + every WheelSpin cash reward
	DailyRewardDay6 = 127607991886697, -- DailyRewards day 6
	DailyRewardDay7 = 137945076270111, -- DailyRewards day 7
	PlaytimeReward = 112943806732824, -- every PlaytimeRewards slot
	VipPass = 122420734012429, -- Promotion "VIP"
	TeleporterPass = 113198463459379, -- Promotion "Teleporter"
	SpeedPass = 130304640405359, -- Promotion "x2 Speed"
	Cash100K = 72195296200818, -- Promotion "100K Cash"
	Wheel = 101212300915466, -- Promotion "x5 Spins" (asset's real name is "Wheel")
}

export type Images = typeof(Images)

return Images
