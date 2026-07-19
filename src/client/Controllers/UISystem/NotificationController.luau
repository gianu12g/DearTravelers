--!strict
--[[
	Toast/notification system. Ported from the source's
	Controllers/NotificationController.luau.

	Template lives under PlayerGui.Main.HUD.Notifications.Template (cloned
	and unparented on first use, same as the source). Exposes Notify() so
	any other UISystem controller can raise a LOCAL-only toast (e.g. a
	client-side validation error) without a network round trip, and also
	listens for the server-pushed Net.notify packet -- both paths end up
	here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("NotificationController")

local player = Players.LocalPlayer

export type NotificationKind = "Success" | "Error" | "Info"

type NotificationTypeData = {
	Background: Color3,
	Stroke: Color3,
	Sound: number,
}

local TYPES: { [NotificationKind]: NotificationTypeData } = {
	Success = { Background = Color3.fromRGB(0, 170, 0), Stroke = Color3.fromRGB(0, 106, 0), Sound = 124743961969068 },
	Error = { Background = Color3.fromRGB(230, 0, 0), Stroke = Color3.fromRGB(170, 0, 0), Sound = 137500936341394 },
	Info = { Background = Color3.fromRGB(0, 170, 255), Stroke = Color3.fromRGB(0, 90, 135), Sound = 74379627889513 },
}

type ActiveNotification = {
	clone: Frame,
	count: number,
	dismissThread: thread,
}

local activeNotifications: { [string]: ActiveNotification } = {}
local layoutOrder = 0

local template: Frame? = nil
local notificationsUi: Instance? = nil
local soundsFolder: Folder? = nil

local NotificationController = {}

local function isKnownKind(kind: string): boolean
	return TYPES[kind :: NotificationKind] ~= nil
end

--[[
	Resolves (and caches) the toast template + parent frame. Yields on a
	cold cache -- Notify() should not be called from any Init(). Every
	caller in this port fires it from Start() or a packet listener, both of
	which are past that point.
]]
local function resolveTemplate(): Frame
	local cached = template
	if cached ~= nil and cached.Parent == nil then
		-- Unparented is the expected steady state for the cached template
		-- itself (it's a clone source, never shown) -- only re-resolve if
		-- the whole Notifications frame is gone (PlayerGui wipe).
		local ui = notificationsUi
		if ui ~= nil and ui.Parent ~= nil then
			return cached
		end
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local main = playerGui:WaitForChild("Main")
	local hud = main:WaitForChild("HUD")
	local ui = hud:WaitForChild("Notifications")
	local templateInstance = ui:WaitForChild("Template") :: Frame
	templateInstance.Parent = nil

	notificationsUi = ui
	template = templateInstance
	return templateInstance
end

local function playSound(kind: NotificationKind)
	local folder = soundsFolder
	if folder == nil then
		return
	end
	local sound = folder:FindFirstChild(kind)
	if sound ~= nil and sound:IsA("Sound") then
		sound:Play()
	end
end

local function dismiss(key: string, clone: Frame)
	clone:TweenSize(UDim2.fromScale(0, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.2, false, function()
		clone:Destroy()
		activeNotifications[key] = nil
	end)
end

function NotificationController.Notify(kind: string, message: string)
	if not isKnownKind(kind) then
		log.warn(`Notify: unknown kind "{kind}" -- ignoring`)
		return
	end
	local notificationKind = kind :: NotificationKind
	local typeData = TYPES[notificationKind]

	local templateInstance = resolveTemplate()
	local ui = notificationsUi
	if ui == nil then
		return
	end

	local key = notificationKind .. "|" .. message
	local existing = activeNotifications[key]

	if existing ~= nil then
		existing.count += 1
		local messageLabel = existing.clone:WaitForChild("Message") :: TextLabel
		messageLabel.Text = `{message} (x{existing.count})`

		task.cancel(existing.dismissThread)
		existing.dismissThread = task.delay(5, function()
			dismiss(key, existing.clone)
		end)

		layoutOrder -= 1
		existing.clone.LayoutOrder = layoutOrder
	else
		local clone = templateInstance:Clone()
		clone.BackgroundColor3 = typeData.Background
		local messageLabel = clone:WaitForChild("Message") :: TextLabel
		messageLabel.Text = message
		local stroke = messageLabel:FindFirstChildOfClass("UIStroke")
		if stroke ~= nil then
			stroke.Color = typeData.Stroke
		end
		clone.Size = UDim2.fromScale(0, 0)

		layoutOrder -= 1
		clone.LayoutOrder = layoutOrder
		clone.Parent = ui
		clone:TweenSize(UDim2.fromScale(0, 1), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.2)

		local dismissThread = task.delay(5, function()
			local entry = activeNotifications[key]
			if entry ~= nil then
				dismiss(key, entry.clone)
			end
		end)

		activeNotifications[key] = { clone = clone, count = 1, dismissThread = dismissThread }
	end

	playSound(notificationKind)
end

function NotificationController.Init()
	local folder = Instance.new("Folder")
	folder.Name = "Notifications"
	for kind, data in TYPES do
		local sound = Instance.new("Sound")
		sound.SoundId = `rbxassetid://{data.Sound}`
		sound.Volume = 1
		sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
		sound.Name = kind
		sound.Parent = folder
	end
	folder.Parent = SoundService
	soundsFolder = folder

	Net.notify.listen(function(data)
		NotificationController.Notify(data.kind, data.message)
	end)
end

return NotificationController
