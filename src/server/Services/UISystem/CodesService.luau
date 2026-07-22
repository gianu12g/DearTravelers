--!strict
--[[
	Redeem-code handler (PORT-SPEC.md §1, source
	ServerScriptService.Services.CodesService). A DataStore-backed use-counter
	(`Codes`) tracks total redemptions per code across all servers; a
	per-player mutex (redeeming) blocks a second in-flight redemption for the
	same player, released on every path via pcall + explicit release
	(quality-gate.md: no `finally` in Luau).

	The source's RemoteFunction invoke (Packets.Codes.RedeemCode) becomes the
	codeRedeemRequest -> codeRedeemResult pair (PORT-SPEC.md §3).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CodeDefinitions = require(ServerStorage.Modules.UISystem.CodeDefinitions)
local DataService = require(ServerStorage.Services.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)

local log = Log.new("CodesService")

-- Client-arg cap (PORT-SPEC.md instructions: string length caps, "code <= 32
-- chars etc."). Every code in CodeDefinitions is well under this.
local MAX_CODE_LENGTH = 32
local DATASTORE_RETRIES = 5
local REWARD_RETRIES = 3

local codesStore = DataStoreService:GetDataStore("Codes")

local redeeming: { [Player]: true } = {}
local redeemLimiter = RateLimiter.new(0.5, 2)

local function reserveCodeUse(code: string, maximumUses: number): (boolean, boolean)
	local ok, updatedUses = Format.Retry(function()
		return codesStore:UpdateAsync(code, function(current: any)
			if current ~= nil and (type(current) ~= "number" or current ~= math.floor(current) or current < 0) then
				error(`invalid use counter for code "{code}"`)
			end
			local uses = current or 0
			if uses >= maximumUses then
				-- nil cancels UpdateAsync. The cap check and increment therefore
				-- happen in one atomic transform across every live server.
				return nil
			end
			return uses + 1
		end)
	end, DATASTORE_RETRIES)

	if not ok then
		log.warn(`failed to reserve a use for code "{code}": {tostring(updatedUses)}`)
		return false, false
	end
	return true, updatedUses ~= nil
end

local function releaseCodeUse(code: string)
	local ok, err = Format.Retry(function()
		codesStore:UpdateAsync(code, function(current: any)
			if type(current) ~= "number" or current ~= math.floor(current) or current <= 0 then
				return nil
			end
			return current - 1
		end)
	end, DATASTORE_RETRIES)
	if not ok then
		-- Failing closed can make fewer redemptions available, but can never
		-- oversubscribe a globally limited campaign.
		log.warn(`failed to release a use for code "{code}": {tostring(err)}`)
	end
end

-- Runs fully inside the per-player mutex (see Init()), so this player's own
-- RedeemedCodes read-modify-write cannot race itself.
local function redeem(player: Player, rawCode: string): (boolean, string)
	local code = string.lower(rawCode)
	local info = CodeDefinitions[code]
	if info == nil then
		return false, "Invalid Code"
	end

	local data = DataService.getData(player)
	if data == nil then
		return false, "Something went wrong, try again later"
	end

	local redeemedCodes = (data.UISystem.RedeemedCodes :: any) :: { string }
	if table.find(redeemedCodes, code) ~= nil then
		return false, "Already Redeemed"
	end

	if not info.isValid(player) then
		return false, "Invalid Code"
	end

	local reservedUse = false
	if info.numberOfUses > 0 then
		local storeAvailable, reserved = reserveCodeUse(code, info.numberOfUses)
		if not storeAvailable then
			return false, "Something went wrong, try again later"
		end
		if not reserved then
			return false, "Code reached max amount of uses"
		end
		reservedUse = true
	end

	local rewarded, rewardErr = Format.Retry(function()
		if not info.reward(player) then
			error("reward rejected the grant")
		end
		return true
	end, REWARD_RETRIES)

	if not rewarded then
		log.warn(`failed rewarding "{code}" to {player.Name}: {tostring(rewardErr)}`)
		if reservedUse then
			releaseCodeUse(code)
		end
		return false, "Something went wrong, try again later"
	end

	local updated = table.clone(redeemedCodes)
	table.insert(updated, code)
	DataService.set(player, { "UISystem", "RedeemedCodes" }, updated)

	return true, "Code Redeemed Successfully"
end

local CodesService = {}

function CodesService.Init()
	Net.codeRedeemRequest.listen(function(data, player)
		if player == nil or not redeemLimiter:allow(player) then
			return
		end

		local code = data.code
		if typeof(code) ~= "string" or #code == 0 or #code > MAX_CODE_LENGTH then
			Net.codeRedeemResult.sendTo({ ok = false, message = "Invalid code" }, player)
			return
		end

		if redeeming[player] then
			Net.codeRedeemResult.sendTo({ ok = false, message = "Please wait" }, player)
			return
		end
		redeeming[player] = true

		local ok, resultOk, message = pcall(redeem, player, code)
		redeeming[player] = nil

		if not ok then
			log.warn(`redeem() errored for {player.Name}: {tostring(resultOk)}`)
			Net.codeRedeemResult.sendTo({ ok = false, message = "Something went wrong" }, player)
			return
		end

		Net.codeRedeemResult.sendTo({ ok = resultOk :: boolean, message = message :: string }, player)
	end)
end

function CodesService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		redeeming[player] = nil
	end)

	log.info("ready")
end

return CodesService
