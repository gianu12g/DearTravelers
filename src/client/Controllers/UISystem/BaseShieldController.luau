--!strict
--[[
	Renders every base's public shield status on its Studio-authored
	NameLabel.ShieldIcon.

	BaseService owns ForcefieldActive and ForcefieldExpiresAt on each BasePart.
	Those attributes replicate to every observer. Each client derives the
	countdown from Workspace:GetServerTimeNow(), so the server sends one
	expiration timestamp per activation rather than replicating changing label
	text every second.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("BaseShieldController")

local WAIT_TIMEOUT = 10
local UPDATE_INTERVAL = 0.25

type ShieldRecord = {
	icon: ImageLabel,
	timer: TextLabel,
}

local records: { [BasePart]: ShieldRecord } = {}

local BaseShieldController = {}

local function findBaseAncestor(instance: Instance, basesFolder: Instance): BasePart?
	local current: Instance? = instance
	while current ~= nil and current ~= basesFolder do
		if current.Parent == basesFolder and current:IsA("BasePart") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function registerBase(base: BasePart)
	if records[base] ~= nil then
		return
	end

	local nameLabel = base:FindFirstChild("NameLabel")
	local shieldIcon = if nameLabel ~= nil then nameLabel:FindFirstChild("ShieldIcon") else nil
	local timer = if shieldIcon ~= nil then shieldIcon:FindFirstChild("Timer") else nil
	if
		nameLabel == nil
		or not nameLabel:IsA("BillboardGui")
		or shieldIcon == nil
		or not shieldIcon:IsA("ImageLabel")
		or timer == nil
		or not timer:IsA("TextLabel")
	then
		return
	end

	shieldIcon.Visible = false
	timer.Text = "00:00"
	records[base] = {
		icon = shieldIcon,
		timer = timer,
	}
end

local function render(base: BasePart, record: ShieldRecord)
	if base.Parent == nil or record.icon.Parent == nil or record.timer.Parent == nil then
		records[base] = nil
		return
	end

	local expiresAt = base:GetAttribute("ForcefieldExpiresAt")
	local remaining = if typeof(expiresAt) == "number" then math.max(0, expiresAt - Workspace:GetServerTimeNow()) else 0
	local visible = base:GetAttribute("ForcefieldActive") == true and remaining > 0

	record.icon.Visible = visible
	record.timer.Text = if visible then Format.FormatCountdown(remaining) else "00:00"
end

function BaseShieldController.Start()
	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.warn("Workspace.MapLayout did not appear -- public shield labels disabled")
		return
	end
	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.warn("Workspace.MapLayout.Bases did not appear -- public shield labels disabled")
		return
	end

	for _, child in basesFolder:GetChildren() do
		if child:IsA("BasePart") then
			registerBase(child)
		end
	end

	basesFolder.ChildAdded:Connect(function(child)
		if child:IsA("BasePart") then
			task.defer(registerBase, child)
		end
	end)
	basesFolder.DescendantAdded:Connect(function(descendant)
		local base = findBaseAncestor(descendant, basesFolder)
		if base ~= nil then
			task.defer(registerBase, base)
		end
	end)

	task.spawn(function()
		while basesFolder.Parent ~= nil do
			for base, record in records do
				render(base, record)
			end
			task.wait(UPDATE_INTERVAL)
		end
	end)

	log.info("ready (watching public shield labels)")
end

return BaseShieldController
