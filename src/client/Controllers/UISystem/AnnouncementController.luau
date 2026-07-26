--!strict
--[[
	Queued gameplay announcements for the Studio-authored
	PlayerGui.NotificationUI.NotificationParent banner.

	This is intentionally separate from NotificationController's stackable
	success/error toasts. Announcements are serialized so launch messages remain
	readable instead of overlapping when several players fire at once.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("AnnouncementController")

local WAIT_TIMEOUT = 10
local DISPLAY_SECONDS = 3.5
local MAX_QUEUED = 8
local SHOW_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local player = Players.LocalPlayer

local queue: { string } = {}
local draining = false
local notificationParent: Frame? = nil
local messageLabel: TextLabel? = nil
local announcementScale: UIScale? = nil

local AnnouncementController = {}

local function isLive(instance: Instance?): boolean
	return instance ~= nil and instance:IsDescendantOf(game)
end

local function resolveUi(): boolean
	if isLive(notificationParent) and isLive(messageLabel) and isLive(announcementScale) then
		return true
	end

	local playerGui = player:WaitForChild("PlayerGui", WAIT_TIMEOUT)
	if playerGui == nil then
		return false
	end
	local screen = playerGui:WaitForChild("NotificationUI", WAIT_TIMEOUT)
	if screen == nil or not screen:IsA("ScreenGui") then
		log.warn("PlayerGui.NotificationUI is missing or not a ScreenGui")
		return false
	end
	local parentInstance = screen:FindFirstChild("NotificationParent")
	if parentInstance == nil or not parentInstance:IsA("Frame") then
		log.warn("NotificationUI.NotificationParent is missing or not a Frame")
		return false
	end
	local labelInstance = parentInstance:FindFirstChild("TextLabel")
	if labelInstance == nil or not labelInstance:IsA("TextLabel") then
		log.warn("NotificationUI.NotificationParent.TextLabel is missing")
		return false
	end

	local scale = parentInstance:FindFirstChild("AnnouncementScale")
	if scale ~= nil and not scale:IsA("UIScale") then
		scale:Destroy()
		scale = nil
	end
	if scale == nil then
		scale = Instance.new("UIScale")
		scale.Name = "AnnouncementScale"
		scale.Parent = parentInstance
	end

	notificationParent = parentInstance
	messageLabel = labelInstance
	announcementScale = scale
	parentInstance.Visible = false
	scale.Scale = 1
	return true
end

local function drain()
	if draining then
		return
	end
	draining = true

	while #queue > 0 do
		if not resolveUi() then
			table.clear(queue)
			break
		end
		local parent = notificationParent :: Frame
		local label = messageLabel :: TextLabel
		local scale = announcementScale :: UIScale
		local message = table.remove(queue, 1)

		label.Text = message
		scale.Scale = 0.72
		parent.Visible = true
		local show = TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 })
		show:Play()
		show.Completed:Wait()

		task.wait(DISPLAY_SECONDS)

		local hide = TweenService:Create(scale, HIDE_TWEEN, { Scale = 0.72 })
		hide:Play()
		hide.Completed:Wait()
		if isLive(parent) then
			parent.Visible = false
		end
	end

	draining = false
end

local function enqueue(message: string)
	if #queue >= MAX_QUEUED then
		table.remove(queue, 1)
	end
	table.insert(queue, message)
	task.spawn(drain)
end

-- Local entry point mirrors NotificationController.Notify: client-only
-- systems may reuse the authored banner without manufacturing a server round
-- trip. Server announcements enter through the packet listener below.
function AnnouncementController.Announce(message: string)
	if message == "" then
		return
	end
	enqueue(message)
end

function AnnouncementController.Init()
	Net.announcement.listen(function(data)
		AnnouncementController.Announce(data.message)
	end)
end

function AnnouncementController.Start()
	if resolveUi() then
		log.info("ready")
	else
		log.warn("announcement UI unavailable")
	end
end

return AnnouncementController
