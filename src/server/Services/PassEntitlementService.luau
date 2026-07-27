--!strict
--[[
	Applies permanent pass benefits on join, native purchase, and
	gift delivery. PassEntitlements resolves native Roblox ownership and the
	profile-backed GiftedPasses map to the same result.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BaseService = require(script.Parent.BaseService)
local CosmeticsService = require(script.Parent.CosmeticsService)
local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local PassEntitlements = require(ServerStorage.Modules.PassEntitlements)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)

local log = Log.new("PassEntitlementService")

local SPEED_MULTIPLIER = 2
local BASE_WALK_SPEED_ATTRIBUTE = "PassBaseWalkSpeed"

local VIP_COSMETICS = {
	{ Slot = "KeycapThemes", Id = "Kintsugi" },
	{ Slot = "KeycapThemes", Id = "ImperialMarble" },
	{ Slot = "KeycapThemes", Id = "ChromePop" },
	{ Slot = "SquishyBeams", Id = "10_Celestial" },
	{ Slot = "MergePops", Id = "10_Celestial" },
}

local PassEntitlementService = {}

local function applyCharacterSpeed(player: Player, character: Model)
	if player:GetAttribute("MushBoostActive") == true then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local baseWalkSpeed = humanoid:GetAttribute(BASE_WALK_SPEED_ATTRIBUTE)
	if type(baseWalkSpeed) ~= "number" or baseWalkSpeed <= 0 then
		baseWalkSpeed = humanoid.WalkSpeed
		humanoid:SetAttribute(BASE_WALK_SPEED_ATTRIBUTE, baseWalkSpeed)
	end

	local multiplier = if player:GetAttribute("WalkSpeedMultiplier") == SPEED_MULTIPLIER
		then SPEED_MULTIPLIER
		else 1
	humanoid.WalkSpeed = baseWalkSpeed * multiplier
end

local function applyCurrentCharacterSpeed(player: Player)
	local character = player.Character
	if character ~= nil then
		applyCharacterSpeed(player, character)
	end
end

local function applyBenefit(player: Player, passName: string): boolean
	if passName == PassEntitlements.VIP then
		player:SetAttribute("VIP", true)
		BaseService.refreshNameLabel(player)
		for _, cosmetic in VIP_COSMETICS do
			if not CosmeticsService.grant(player, cosmetic.Slot :: any, cosmetic.Id) then
				return false
			end
		end
		return true
	elseif passName == PassEntitlements.DOUBLE_CASH then
		player:SetAttribute("CashMultiplier", 2)
		return true
	elseif passName == PassEntitlements.OFFLINE_EARNINGS then
		player:SetAttribute("OfflineEarningsMaxHours", MergeConfig.MAX_OFFLINE_PLUS_SECONDS / 3600)
		return true
	elseif passName == PassEntitlements.DOUBLE_SPEED then
		player:SetAttribute("WalkSpeedMultiplier", SPEED_MULTIPLIER)
		applyCurrentCharacterSpeed(player)
		return true
	end
	return false
end

function PassEntitlementService.grant(player: Player, passName: string): boolean
	if not DataService.awaitData(player, 30) then
		return false
	end
	PassEntitlements.markOwned(player, passName)
	return applyBenefit(player, passName)
end

local function onPlayerAdded(player: Player)
	player:SetAttribute("VIP", false)
	player:SetAttribute("CashMultiplier", 1)
	player:SetAttribute("OfflineEarningsMaxHours", MergeConfig.MAX_OFFLINE_SECONDS / 3600)
	player:SetAttribute("WalkSpeedMultiplier", 1)

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid ~= nil and humanoid:IsA("Humanoid") then
			applyCharacterSpeed(player, character)
		end
	end)
	player:GetAttributeChangedSignal("MushBoostActive"):Connect(function()
		if player:GetAttribute("MushBoostActive") ~= true then
			applyCurrentCharacterSpeed(player)
		end
	end)
	applyCurrentCharacterSpeed(player)

	if not DataService.awaitData(player, 30) then
		return
	end
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	for _, passName in {
		PassEntitlements.VIP,
		PassEntitlements.OFFLINE_EARNINGS,
		PassEntitlements.DOUBLE_CASH,
		PassEntitlements.DOUBLE_SPEED,
	} do
		if PassEntitlements.owns(player, passName, data) and not applyBenefit(player, passName) then
			log.warn(`failed to apply "{passName}" for {player.Name}`)
		end
	end
end

function PassEntitlementService.Start()
	Players.PlayerRemoving:Connect(PassEntitlements.clearPlayer)
	SafePlayerAdded(onPlayerAdded)
	log.info("ready")
end

return PassEntitlementService
