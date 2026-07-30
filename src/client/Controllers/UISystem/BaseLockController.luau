--!strict
--[[
	Binds the Studio-authored PlayerGui.Screens.LockBaseUI button to the
	server-authoritative timed base forcefield.

	The client sends no base name and no desired state. BaseService resolves the
	sender's current assignment and enforces the duration/cooldown, so an
	exploiter cannot lock another player's base, extend the active window, or
	make the visual disagree with damage immunity.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local NotificationController = require(script.Parent.NotificationController)

local log = Log.new("BaseLockController")

local WAIT_TIMEOUT = 10
local PENDING_TIMEOUT = 5

local player = Players.LocalPlayer

local BaseLockController = {}

local function secondsRemaining(instance: Instance?, attributeName: string): number
	local endTime = if instance ~= nil then instance:GetAttribute(attributeName) else nil
	if typeof(endTime) ~= "number" then
		return 0
	end
	return math.max(0, math.ceil(endTime - Workspace:GetServerTimeNow()))
end

local function assignedBasePart(): BasePart?
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return nil
	end
	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local bases = if mapLayout ~= nil then mapLayout:FindFirstChild("Bases") else nil
	local base = if bases ~= nil then bases:FindFirstChild(baseName) else nil
	return if base ~= nil and base:IsA("BasePart") then base else nil
end

local function formatLockTime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local remainingSeconds = seconds % 60
	return string.format("%02d:%02d", minutes, remainingSeconds)
end

function BaseLockController.Start()
	local playerGui = player:WaitForChild("PlayerGui", WAIT_TIMEOUT)
	if playerGui == nil then
		log.warn("PlayerGui did not appear -- base lock control disabled")
		return
	end
	local screens = playerGui:WaitForChild("Screens", WAIT_TIMEOUT)
	if screens == nil then
		log.warn("PlayerGui.Screens did not appear -- base lock control disabled")
		return
	end
	-- Root-level fallback keeps an older place copy usable while Studio/Rojo
	-- catches up with the authored move into Screens.
	local screen = screens:FindFirstChild("LockBaseUI") or playerGui:FindFirstChild("LockBaseUI")
	if screen == nil then
		screen = screens:WaitForChild("LockBaseUI", WAIT_TIMEOUT)
	end
	if screen == nil or not screen:IsA("ScreenGui") then
		log.warn("PlayerGui.Screens.LockBaseUI is missing or not a ScreenGui -- base lock control disabled")
		return
	end
	local targetingInstance = screens:WaitForChild("LaunchTargetingUI", WAIT_TIMEOUT)
	local targetingScreen = if targetingInstance ~= nil and targetingInstance:IsA("ScreenGui")
		then targetingInstance
		else nil
	if targetingScreen == nil then
		log.warn("PlayerGui.Screens.LaunchTargetingUI is missing -- launch-view hiding disabled")
	end
	local buttonInstance = screen:FindFirstChild("A.Lock", true) or screen:FindFirstChild("Lock", true)
	if buttonInstance == nil or not buttonInstance:IsA("GuiButton") then
		log.warn("LockBaseUI has no A.Lock GuiButton -- base lock control disabled")
		return
	end
	local button: GuiButton = buttonInstance
	local labelInstance = button:FindFirstChild("TextLabel")
	local label = if labelInstance ~= nil and labelInstance:IsA("TextLabel") then labelInstance else nil

	local pending = false
	local requestGeneration = 0

	local function refresh()
		local base = assignedBasePart()
		local hasBase = base ~= nil
		local locked = base ~= nil and base:GetAttribute("ForcefieldActive") == true
		local activeSeconds = secondsRemaining(base, "ForcefieldExpiresAt")
		local cooldownSeconds = secondsRemaining(base, "ForcefieldCooldownEndsAt")
		local targeting = targetingScreen ~= nil and targetingScreen.Enabled
		screen.Enabled = hasBase and not targeting
		button.Interactable = hasBase and not targeting and not pending and not locked and cooldownSeconds == 0
		if label ~= nil then
			if locked then
				label.Text = `LOCKED ({formatLockTime(activeSeconds)})`
			elseif cooldownSeconds > 0 then
				label.Text = `COOLDOWN ({cooldownSeconds}s)`
			else
				label.Text = "LOCK BASE"
			end
		end
	end

	Net.baseLockResult.listen(function(data)
		pending = false
		requestGeneration += 1
		refresh()
		NotificationController.Notify(if data.ok then "Success" else "Error", data.message)
	end)

	button.Activated:Connect(function()
		if pending or typeof(player:GetAttribute("AssignedBase")) ~= "string" then
			return
		end

		pending = true
		requestGeneration += 1
		local generation = requestGeneration
		refresh()
		Net.baseLockRequest.send()

		task.delay(PENDING_TIMEOUT, function()
			if pending and requestGeneration == generation then
				pending = false
				refresh()
			end
		end)
	end)

	player:GetAttributeChangedSignal("AssignedBase"):Connect(refresh)
	if targetingScreen ~= nil then
		targetingScreen:GetPropertyChangedSignal("Enabled"):Connect(refresh)
	end
	refresh()

	task.spawn(function()
		while screen.Parent ~= nil do
			refresh()
			task.wait(0.25)
		end
	end)

	log.info("ready")
end

return BaseLockController
