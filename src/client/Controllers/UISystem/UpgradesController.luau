--!strict
--[[
	Binds the Studio-authored Main.Frames.Upgrades rows to replicated player
	data and the server-authoritative purchase packet.

	The visible coin control in each authored row is named EquipButton (the
	hidden Purchase control is a copied Robux/VIP button), so this controller
	deliberately touches only EquipButton.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local NotificationController = require(script.Parent.NotificationController)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local log = Log.new("UpgradesController")

local PENDING_TIMEOUT = 5

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type Row = {
	currentLevel: TextLabel,
	button: GuiButton,
	priceTag: TextLabel,
}

type View = {
	frame: Frame,
	rows: { [UpgradeConfig.UpgradeKey]: Row },
}

local UpgradesController = {}

local view: View? = nil
local pending: { [UpgradeConfig.UpgradeKey]: number } = {}
local requestGeneration = 0

local function displayValue(key: UpgradeConfig.UpgradeKey, value: number): string
	if key == "SpawnTier" then
		return tostring(RebirthConfig.tierNumberForModelLevel(value))
	elseif key == "MaxSpawns" then
		return tostring(value)
	else
		return Format.FormatCountdown(UpgradeConfig.lockDurationSeconds(value))
	end
end

local function render()
	local currentView = view
	if currentView == nil or currentView.frame.Parent == nil then
		return
	end

	local data = DataController.getData()
	for _, key in UpgradeConfig.ORDER do
		local row = currentView.rows[key]
		if data == nil then
			row.currentLevel.Text = "Level --"
			row.priceTag.Text = "--"
			row.button.Interactable = false
			continue
		end

		local value = UpgradeConfig.readValue(data, key)
		local level = UpgradeConfig.levelForValue(key, value)
		row.currentLevel.Text = `Level {level} ({displayValue(key, value)})`

		local atGlobalMaximum = value >= UpgradeConfig.maximumValue(key)
		local rebirthGated = key == "SpawnTier"
			and not atGlobalMaximum
			and value >= RebirthConfig.maxModelLevel(data.Rebirths)
		local isPending = pending[key] ~= nil
		local cost = UpgradeConfig.costForValue(key, value)

		if isPending then
			row.priceTag.Text = "..."
		elseif atGlobalMaximum then
			row.priceTag.Text = "MAX"
		elseif rebirthGated then
			row.priceTag.Text = "REBIRTH"
		else
			row.priceTag.Text = Format.FormatNumber(cost :: number)
		end

		row.button.Interactable = not isPending and not atGlobalMaximum and not rebirthGated and cost ~= nil
	end
end

local function requestUpgrade(key: UpgradeConfig.UpgradeKey)
	if pending[key] ~= nil then
		return
	end

	requestGeneration += 1
	local generation = requestGeneration
	pending[key] = generation
	render()
	Net.upgradeRequest.send({ upgrade = key })

	task.delay(PENDING_TIMEOUT, function()
		if pending[key] == generation then
			pending[key] = nil
			render()
			NotificationController.Notify("Error", "Upgrade request timed out")
		end
	end)
end

local function resolveRow(holder: Instance, rowName: string): Row?
	local row = holder:FindFirstChild(rowName)
	if row == nil or not row:IsA("Frame") then
		log.warn(`Upgrades.Holder.{rowName} is missing or not a Frame`)
		return nil
	end

	local currentLevel = row:FindFirstChild("currentLevel")
	local button = row:FindFirstChild("EquipButton")
	local priceTag = if button ~= nil then button:FindFirstChild("PriceTag") else nil
	if
		currentLevel == nil
		or not currentLevel:IsA("TextLabel")
		or button == nil
		or not button:IsA("GuiButton")
		or priceTag == nil
		or not priceTag:IsA("TextLabel")
	then
		log.warn(`Upgrades.Holder.{rowName} needs currentLevel, EquipButton and EquipButton.PriceTag`)
		return nil
	end

	return {
		currentLevel = currentLevel,
		button = button,
		priceTag = priceTag,
	}
end

local function bindFrame(frame: Frame)
	if view ~= nil and view.frame == frame then
		return
	end

	local scrollingFrame = frame:FindFirstChild("MainScrollingFrame")
	local holder = if scrollingFrame ~= nil then scrollingFrame:FindFirstChild("Holder") else nil
	if holder == nil then
		log.warn("Main.Frames.Upgrades.MainScrollingFrame.Holder is missing")
		return
	end

	local spawnTier = resolveRow(holder, "SpawnTier")
	local maxSpawns = resolveRow(holder, "MaxSpawn")
	local lockBase = resolveRow(holder, "LockBase")
	if spawnTier == nil or maxSpawns == nil or lockBase == nil then
		return
	end

	local rows: { [UpgradeConfig.UpgradeKey]: Row } = {
		SpawnTier = spawnTier,
		MaxSpawns = maxSpawns,
		LockBase = lockBase,
	}
	view = {
		frame = frame,
		rows = rows,
	}

	for _, key in UpgradeConfig.ORDER do
		local rowKey = key
		rows[rowKey].button.Activated:Connect(function()
			requestUpgrade(rowKey)
		end)
	end

	frame.Destroying:Connect(function()
		if view ~= nil and view.frame == frame then
			view = nil
		end
	end)

	render()
end

function UpgradesController.Init()
	Net.upgradeResult.listen(function(result)
		if UpgradeConfig.isUpgradeKey(result.upgrade) then
			pending[result.upgrade :: UpgradeConfig.UpgradeKey] = nil
		end
		render()
		NotificationController.Notify(if result.ok then "Success" else "Error", result.message)
	end)
end

function UpgradesController.Start()
	bindFrame(Frames.get("Upgrades"))

	-- StarterGui.ResetPlayerGuiOnSpawn can replace Main.Frames. Rebind the
	-- freshly cloned authored frame without accumulating Replica observers.
	playerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "Upgrades" and descendant:IsA("Frame") then
			local parent = descendant.Parent
			if parent ~= nil and parent.Name == "Frames" then
				task.defer(bindFrame, descendant)
			end
		end
	end)

	DataController.observe({ "Coins" }, function()
		render()
	end)
	DataController.observe({ "Rebirths" }, function()
		render()
	end)
	DataController.observe({ "Merge", "SpawnLevel" }, function()
		render()
	end)
	DataController.observe({ "Merge", "MaxSpawns" }, function()
		render()
	end)
	DataController.observe({ "Merge", "LockBase" }, function()
		render()
	end)

	log.info("ready")
end

return UpgradesController
