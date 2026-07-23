--!strict
--[[
	Ownership + equip backbone for cosmetics (COSMETICS_PLAN.md): keycap
	Themes and squishy launch Trails. Equip is a plain DataService.set write;
	DataController.observe on the replicated value drives the client menu,
	and world visuals follow from there -- this service's own job is only to
	validate the write and, for themes, apply the world-visible side effect
	(the `Theme` attribute KeyCapsController already renders).

	No purchase flow here (COSMETICS_PLAN.md "Out of scope") -- grant() is
	the shop's future entry point; today nothing calls it but a later dev
	console / bundle purchase.

	THEME RE-APPLY TIMING: `AssignedBase` is stamped on the Player by
	BaseService.SafePlayerAdded with NO data gate (BaseService.luau's own
	header), so it can land before this player's profile has loaded. Waiting
	on DataService.awaitData before reading the equipped id is therefore
	load-bearing, not defensive -- a fresh join without it would read the
	TEMPLATE default before the real profile value existed.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BaseService = require(script.Parent.BaseService)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)

local log = Log.new("CosmeticsService")

local MAX_ID_LENGTH = 64

local CosmeticsService = {}
local equipLimiter = RateLimiter.new(2, 4)

-- Per-player AssignedBase watcher, so a theme re-applies whenever a player
-- (re)gets a base -- reverse-indexed by Player for the same reason
-- BaseService/MergeService's own attribute connections are (PlayerRemoving
-- only hands us a Player).
local assignedBaseConnections: { [Player]: RBXScriptConnection } = {}

local function isValidIdForSlot(slot: CosmeticsCatalog.Slot, id: string): boolean
	if slot == "KeycapThemes" then
		return CosmeticsCatalog.isKeycapTheme(id)
	end
	return CosmeticsCatalog.isSquishyTrail(id)
end

--[[
	Stamps every Key-tagged MeshPart under `player`'s base KeyCaps folder, and
	the base part itself, with the given theme id. KeyCapsController's own
	attribute-changed observers (wireKey for keys, the base tracker for the
	base part) render the theme -- keys pick a random Colors entry, the base
	part is tinted with Colors[1] (the anchor/darkest color, THEMES tables are
	ordered dark-to-light). Re-stamping the same value is harmless (no signal
	fires), so callers don't need to check "did this already change".

	No-ops quietly if the player has no base yet, or the base has no KeyCaps
	folder -- both are BaseService/Studio-authoring concerns already logged
	elsewhere, not something this service should double-warn about.
]]
function CosmeticsService.applyKeycapTheme(player: Player, themeId: string)
	local basePart = BaseService.getBasePart(player)
	if basePart == nil then
		return
	end
	local keyCaps = basePart:FindFirstChild("KeyCaps")
	if keyCaps == nil then
		return
	end

	for _, instance in keyCaps:GetDescendants() do
		if instance:IsA("MeshPart") and CollectionService:HasTag(instance, CosmeticsCatalog.KEY_TAG) then
			instance:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, themeId)
		end
	end

	basePart:SetAttribute(CosmeticsCatalog.THEME_ATTRIBUTE, themeId)
end

--[[
	Grants ownership of `id` in `slot` to `player` if not already owned. The
	shop's future entry point -- the menu updates live via
	DataController.observe({"Cosmetics","Owned"}) on the calling client.

	Returns false if `id` isn't a real catalog entry for `slot`, or if the
	player's data never loads within the timeout; true otherwise (including
	the already-owned no-op case).
]]
function CosmeticsService.grant(player: Player, slot: CosmeticsCatalog.Slot, id: string): boolean
	if not isValidIdForSlot(slot, id) then
		log.warn(`grant() rejected unknown {slot} id "{id}" for {player.Name}`)
		return false
	end
	if not DataService.awaitData(player, 30) then
		return false
	end
	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local owned = data.Cosmetics.Owned[slot]
	if table.find(owned, id) ~= nil then
		return true
	end

	DataService.tableInsert(player, { "Cosmetics", "Owned", slot }, id)
	return true
end

-- Re-applies the persisted theme once this player's data is loaded and they
-- still hold the base that triggered this call (both can change out from
-- under a yielding awaitData -- a left/reassigned player must not have a
-- stale apply land on someone else's base).
local function reapplyPersistedTheme(player: Player)
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return
	end
	if not DataService.awaitData(player, 30) then
		return
	end
	if player:GetAttribute("AssignedBase") ~= baseName then
		return
	end
	local data = DataService.getData(player)
	if data == nil then
		return
	end
	CosmeticsService.applyKeycapTheme(player, data.Cosmetics.KeycapThemeId)
end

local function onPlayerAdded(player: Player)
	if assignedBaseConnections[player] ~= nil then
		-- Already hooked -- same double-connect guard BaseService/MergeService
		-- use for the identical case.
		return
	end

	local changedSignal = player:GetAttributeChangedSignal("AssignedBase")
	assignedBaseConnections[player] = changedSignal:Connect(function()
		reapplyPersistedTheme(player)
	end)
	-- BaseService may have already assigned a base before this connection
	-- existed -- read the attribute's current value once, right after
	-- connecting, so that case isn't silently missed.
	reapplyPersistedTheme(player)
end

local function onPlayerRemoving(player: Player)
	local connection = assignedBaseConnections[player]
	if connection ~= nil then
		assignedBaseConnections[player] = nil
		connection:Disconnect()
	end
end

function CosmeticsService.Init()
	Net.cosmeticEquip.listen(function(data, player)
		if player == nil or not equipLimiter:allow(player) then
			return
		end

		local slotValue = data.slot
		local id = data.id
		if typeof(slotValue) ~= "string" or typeof(id) ~= "string" then
			return
		end
		if slotValue ~= "KeycapThemes" and slotValue ~= "SquishyTrails" then
			return
		end
		if #id == 0 or #id > MAX_ID_LENGTH then
			return
		end
		local slot: CosmeticsCatalog.Slot = slotValue :: CosmeticsCatalog.Slot

		if not DataService.awaitData(player, 10) then
			return
		end
		local playerData = DataService.getData(player)
		if playerData == nil then
			return
		end

		if not isValidIdForSlot(slot, id) then
			return
		end

		-- Forged equip of an unowned id -- silently dropped
		-- (COSMETICS_PLAN.md verification list).
		local owned = playerData.Cosmetics.Owned[slot]
		if table.find(owned, id) == nil then
			return
		end

		local equippedField = if slot == "KeycapThemes" then "KeycapThemeId" else "SquishyTrailId"
		DataService.set(player, { "Cosmetics", equippedField }, id)

		if slot == "KeycapThemes" then
			CosmeticsService.applyKeycapTheme(player, id)
		end
	end)
end

function CosmeticsService.Start()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	SafePlayerAdded(onPlayerAdded)

	log.info("ready")
end

return CosmeticsService
