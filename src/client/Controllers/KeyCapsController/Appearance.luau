--!strict
--[[
	Theme application to key MeshParts and their base plates. See init.luau's
	module comment for the full behavior this implements.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local Log = require(ReplicatedStorage.Shared.Log)
local Themes = require(script.Parent.Themes)

local log = Log.new("LightUpKeysController")

local THEME_ATTRIBUTE = CosmeticsCatalog.THEME_ATTRIBUTE
local DEFAULT_THEME = CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID

local THEMES = Themes.THEMES

-- Per-base tracker so a base with many keys gets exactly one Theme attribute
-- connection. keyCount is the number of currently-wired keys pointing at this
-- base; the connection is torn down and originalColor restored once it hits
-- zero (the base's last key was untagged/removed).
type BaseState = {
	connection: RBXScriptConnection,
	originalColor: Color3,
	keyCount: number,
}

local normalizingTheme: { [MeshPart]: boolean } = {}
local trackedBases: { [BasePart]: BaseState } = {}

local Appearance = {}

local function applyTheme(key: MeshPart)
	local attribute = key:GetAttribute(THEME_ATTRIBUTE)
	local themeName = if typeof(attribute) == "string" and THEMES[attribute] ~= nil then attribute else DEFAULT_THEME

	if attribute ~= themeName then
		if attribute ~= nil then
			log.warn(
				`{key:GetFullName()}.{THEME_ATTRIBUTE} has invalid theme {tostring(attribute)} -- using {DEFAULT_THEME}`
			)
		end

		normalizingTheme[key] = true
		key:SetAttribute(THEME_ATTRIBUTE, themeName)
		normalizingTheme[key] = nil
	end

	local theme = THEMES[themeName]
	if theme == nil then
		log.warn(`default keycap theme "{DEFAULT_THEME}" is not configured -- appearance unchanged`)
		return
	end

	local colors = theme.Colors
	if #colors == 0 then
		log.warn(`keycap theme "{themeName}" has no colors -- appearance unchanged`)
		return
	end

	key.Color = colors[math.random(1, #colors)]
	key.Material = theme.Material
end

-- Same resolution as applyTheme (invalid/missing attribute falls back to
-- DEFAULT_THEME) but read-only: the base's Theme attribute has only one
-- writer, CosmeticsService, so there's no self-triggered signal to guard
-- against and nothing to normalize back onto the instance.
local function applyBaseTheme(basePart: BasePart)
	local attribute = basePart:GetAttribute(THEME_ATTRIBUTE)
	local themeName = if typeof(attribute) == "string" and THEMES[attribute] ~= nil then attribute else DEFAULT_THEME

	local theme = THEMES[themeName]
	if theme == nil then
		log.warn(`default keycap theme "{DEFAULT_THEME}" is not configured -- base appearance unchanged`)
		return
	end

	local colors = theme.Colors
	if #colors == 0 then
		log.warn(`keycap theme "{themeName}" has no colors -- base appearance unchanged`)
		return
	end

	-- THEMES tables are ordered dark-to-light -- index 1 is the theme's
	-- anchor/darkest color, the one used for the base plate tint.
	basePart.Color = colors[1]
end

-- The key's KeyCaps folder isn't always the key's direct parent -- the real
-- Studio-authored tree groups keys under per-pack subfolders, e.g.
-- Base1.KeyCaps.KeyPack.Key, not just Base1.KeyCaps.Key. Walk upward from the
-- key until an ancestor named "KeyCaps" (a Folder) is found, then require
-- that folder's own parent to be the base BasePart. Bounded at nil/workspace
-- so a key tagged somewhere unrelated doesn't walk forever.
function Appearance.getBaseFromKey(key: MeshPart): BasePart?
	local ancestor: Instance? = key.Parent
	while ancestor ~= nil and ancestor ~= workspace do
		if ancestor.Name == "KeyCaps" and ancestor:IsA("Folder") then
			local basePart = ancestor.Parent
			if basePart ~= nil and basePart:IsA("BasePart") then
				return basePart
			end
			return nil
		end
		ancestor = ancestor.Parent
	end

	return nil
end

-- Adds one key to `basePart`'s reference count, wiring its Theme connection
-- and applying the current theme the first time any key reaches it.
function Appearance.wireBase(basePart: BasePart)
	local state = trackedBases[basePart]
	if state ~= nil then
		state.keyCount += 1
		return
	end

	local newState: BaseState = {
		connection = basePart:GetAttributeChangedSignal(THEME_ATTRIBUTE):Connect(function()
			applyBaseTheme(basePart)
		end),
		originalColor = basePart.Color,
		keyCount = 1,
	}
	trackedBases[basePart] = newState

	applyBaseTheme(basePart)
end

-- Removes one key from `basePart`'s reference count; once the last key is
-- gone, disconnects and restores the base's pre-theme color.
function Appearance.unwireBase(basePart: BasePart)
	local state = trackedBases[basePart]
	if state == nil then
		return
	end

	state.keyCount -= 1
	if state.keyCount > 0 then
		return
	end
	trackedBases[basePart] = nil

	state.connection:Disconnect()
	if basePart.Parent ~= nil then
		basePart.Color = state.originalColor
	end
end

-- Applies the key's current theme and wires an attribute-changed connection
-- that reapplies it on change, skipping the key's own SetAttribute
-- normalization writes. Caller owns the returned connection and must
-- disconnect it when the key is untagged.
function Appearance.connectKeyTheme(key: MeshPart): RBXScriptConnection
	applyTheme(key)
	return key:GetAttributeChangedSignal(THEME_ATTRIBUTE):Connect(function()
		if not normalizingTheme[key] then
			applyTheme(key)
		end
	end)
end

--[[
	The dark-to-light Colors for `id`, or nil if it isn't a configured theme.
	Exposed for CosmeticsController's cosmetics-menu card, which restyles each
	owned theme's card gradient from these same colors (COSMETICS_PLAN.md) --
	Material is a physical-key concern the card has no use for.
]]
function Appearance.getThemeColors(id: string): { Color3 }?
	local theme = THEMES[id]
	return if theme ~= nil then theme.Colors else nil
end

-- CosmeticsCatalog.KeycapThemes is meant to list every id in THEMES, and
-- nothing else -- warn (don't error) if the two ever diverge, in either
-- direction, so a forgotten catalog entry or a stale one is caught in the
-- output instead of silently shipping.
function Appearance.warnCosmeticsCatalogDrift()
	for _, entry in CosmeticsCatalog.KeycapThemes do
		if THEMES[entry.Id] == nil then
			log.warn(`CosmeticsCatalog theme "{entry.Id}" has no entry in THEMES -- it can never render`)
		end
		if Images.ThemeIcons[entry.Id] == nil then
			log.warn(
				`CosmeticsCatalog theme "{entry.Id}" has no Images.ThemeIcons entry -- its card will use the template's default icon`
			)
		end
	end
	for themeName in THEMES do
		if not CosmeticsCatalog.isKeycapTheme(themeName) then
			log.warn(`THEMES theme "{themeName}" is missing from CosmeticsCatalog -- it can never be owned or equipped`)
		end
	end
end

return Appearance
