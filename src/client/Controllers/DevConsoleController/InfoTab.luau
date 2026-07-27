--!strict
--[[
	The Info tab: live readouts about the client and the current target. Purely
	a display -- nothing here sends a packet.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local Snapshot = require(script.Parent.Snapshot)
local Widgets = require(script.Parent.Widgets)
local Window = require(script.Parent.Window)

local player = Players.LocalPlayer

export type Deps = {
	getTarget: () -> Player,
	getActiveTab: () -> string,
	registerPage: (string, Frame) -> (),
}

local InfoTab = {}

local deps: Deps? = nil

local infoValueLabels: { [string]: TextLabel } = {}

local frameCount = 0
local fpsSampledAt = os.clock()
local framesPerSecond = 0
local frameConnection: RBXScriptConnection? = nil

function InfoTab.setup(newDeps: Deps)
	deps = newDeps
end

local function setInfo(name: string, value: string)
	local label = infoValueLabels[name]
	if label ~= nil then
		label.Text = value
	end
end

function InfoTab.updateInfo()
	local currentDeps = deps :: Deps
	if currentDeps.getActiveTab() ~= "Info" then
		-- Nothing to see: skip the work rather than formatting strings nobody is
		-- looking at, every tick, for as long as the panel stays open.
		return
	end

	local now = os.clock()
	local elapsed = now - fpsSampledAt
	if elapsed >= 0.4 then
		framesPerSecond = frameCount / elapsed
		frameCount = 0
		fpsSampledAt = now
	end

	local target = currentDeps.getTarget()
	local screen = Window.viewportSize()
	local windowSize = Window.getSize()

	setInfo("FPS", `{math.round(framesPerSecond)}`)
	setInfo("Ping", `{math.round(player:GetNetworkPing() * 1000)} ms`)
	setInfo("Viewport", `{math.round(screen.X)} x {math.round(screen.Y)}`)
	setInfo("Window", `{math.round(windowSize.X)} x {math.round(windowSize.Y)}`)
	setInfo("Place / Job", `{game.PlaceId} / {if game.JobId == "" then "(studio)" else game.JobId}`)
	setInfo("Players", `{#Players:GetPlayers()}`)
	setInfo("Me", `{player.Name} ({player.UserId})`)
	setInfo("Target", `{target.Name} ({target.UserId})`)

	local assignedBase = target:GetAttribute("AssignedBase")
	local queuePosition = target:GetAttribute("BaseQueuePosition")
	setInfo(
		"Target base",
		if typeof(assignedBase) == "string"
			then assignedBase :: string
			elseif typeof(queuePosition) == "number" then `(queued #{queuePosition})`
			else "(none)"
	)

	setInfo("Coins", Snapshot.text("Coins"))
	setInfo("Level / XP", `{Snapshot.text("Level")} / {Snapshot.text("Experience")}`)
	setInfo("Spawn tier", Snapshot.text("Merge.SpawnLevel"))
	local maxSpawns = Snapshot.number("Merge.MaxSpawns") or UpgradeConfig.DEFAULT_MAX_SPAWNS
	setInfo("Squishies", `{Snapshot.countArrayEntries("Merge.Squishies")} / {maxSpawns}`)
	setInfo("Spins", Snapshot.text("UISystem.Spins"))
	setInfo("Keycap theme", Snapshot.text("Cosmetics.KeycapThemeId"))
	setInfo("Squishy beam", Snapshot.text("Cosmetics.SquishyBeamId"))
	setInfo("Merge pop", Snapshot.text("Cosmetics.MergePopId"))
	setInfo(
		"Cosmetics owned",
		`{Snapshot.countArrayEntries("Cosmetics.Owned.KeycapThemes")} keycaps, {Snapshot.countArrayEntries(
			"Cosmetics.Owned.SquishyBeams"
		)} beams, {Snapshot.countArrayEntries("Cosmetics.Owned.MergePops")} merge pops`
	)
	setInfo("Data version", Snapshot.text("Version"))
end

-- Only while the panel is open, per spec -- cancelled on close and on destroy
-- so it can never outlive the UI it's refreshing.
function InfoTab.startSampling()
	InfoTab.stopSampling()

	frameCount = 0
	fpsSampledAt = os.clock()
	frameConnection = RunService.RenderStepped:Connect(function()
		frameCount += 1
	end)
end

function InfoTab.stopSampling()
	local connection = frameConnection
	if connection ~= nil then
		connection:Disconnect()
		frameConnection = nil
	end
end

function InfoTab.build(parent: Frame)
	local currentDeps = deps :: Deps
	local page = Widgets.newPage(parent, "Info", currentDeps.registerPage)
	local list = Widgets.newScrollList(page, "InfoList", UDim2.new(), UDim2.fromScale(1, 1))

	local order = 0
	local function section(title: string)
		order += 1
		Widgets.addSectionHeader(list, order, title)
	end
	local function field(name: string)
		order += 1
		infoValueLabels[name] = Widgets.addInfoRow(list, order, name)
	end

	section("CLIENT")
	field("FPS")
	field("Ping")
	field("Viewport")
	field("Window")

	section("SESSION")
	field("Place / Job")
	field("Players")
	field("Me")

	section("TARGET")
	field("Target")
	field("Target base")
	field("Coins")
	field("Level / XP")
	field("Spawn tier")
	field("Squishies")
	field("Spins")
	field("Keycap theme")
	field("Squishy beam")
	field("Merge pop")
	field("Cosmetics owned")
	field("Data version")
end

function InfoTab.cleanup()
	InfoTab.stopSampling()
	table.clear(infoValueLabels)
end

return InfoTab
