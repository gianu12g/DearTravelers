--!strict
--[[
	Music/SFX volume settings (PORT-SPEC.md §1, source
	ServerScriptService.Services.SettingsService, renamed UISettingsService --
	"Settings" is generic enough to want the UISystem domain spelled out).

	State lives at {"UISystem", "Settings"}; Replica replicates it to the
	owning client automatically via DataService.set, so the source's
	dedicated `_Settings` Replication entity (server/INDEX.md §3) is not
	ported -- there is nothing left for it to do.

	The source additionally checked `typeof(plrSettings[settingName]) ~=
	typeof(value)`. Net.luau's settingUpdate packet already fixes the value's
	wire type at float64 (see its header comment: "unlike the source's
	Packet.Any, the wire type itself rules out any other payload shape"), so
	that check would now always pass and is dropped; the known-key check
	below is what's left doing real work.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(ServerStorage.Services.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("UISettingsService")

local UISettingsService = {}

function UISettingsService.Init()
	Net.settingUpdate.listen(function(data, player)
		if player == nil then
			return
		end

		local key = data.key
		local value = data.value

		if typeof(key) ~= "string" then
			return
		end
		-- NaN and +/-infinity defeat a naive range check (quality-gate.md
		-- trap #8); there is no sane persisted volume for either.
		if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return
		end
		-- Volume is a [0,1] slider; clamp rather than reject so a client
		-- sending a stray out-of-range value still lands somewhere sane.
		value = math.clamp(value, 0, 1)

		local playerData = DataService.getData(player)
		if playerData == nil then
			return
		end

		--[[
			Settings = { Music = 0.9, SFX = 0.9 } in TEMPLATE -- a sealed
			2-field record, not an indexed map, so a runtime string key needs
			this cast to read through it. Verified against the template
			shape directly, not guessed (ARCHITECTURE.md's Data section).
		]]
		local settings = (playerData.UISystem.Settings :: any) :: { [string]: number }
		if settings[key] == nil then
			-- Not a known setting -- refuse to invent a new key.
			return
		end

		DataService.set(player, { "UISystem", "Settings", key }, value)
	end)
end

function UISettingsService.Start()
	log.info("ready")
end

return UISettingsService
