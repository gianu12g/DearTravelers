--!strict
--[[
	Developer-product "pack" reward stubs (PORT-SPEC.md §1, from source
	MarketplaceService.PacksRewards -- print()-only placeholders in the
	source). Keys match Shared/UISystem/Config/Packs.luau 1:1 -- unlike
	PassRewards.luau, the source's keys here were already correct.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CosmeticsService = require(ServerStorage.Services.CosmeticsService)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("PackRewards")

local ARCADE_THEMES_PACK = {
	"CandyCircuit",
	"NeonGrid",
	"AcidPulse",
	"SolarFlare",
	"BlueReactor",
}

local function grantArcadeThemesPack(player: Player): boolean
	-- grant() is idempotent for themes the player already owns. If a later
	-- grant fails, Roblox can safely retry the receipt: successful earlier
	-- grants remain owned and become no-ops on the next attempt.
	for _, themeId in ARCADE_THEMES_PACK do
		if not CosmeticsService.grant(player, "KeycapThemes", themeId) then
			log.warn(`failed to grant keycap theme "{themeId}" to {player.Name}`)
			return false
		end
	end
	return true
end

local PackRewards: { [string]: (Player) -> boolean } = {
	["Limited Themes Pack"] = grantArcadeThemesPack,
}

return PackRewards
