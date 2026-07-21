--!strict
--[[
	Binds the merge-gameplay carry mechanic to the Studio-authored controls in
	PlayerGui.DropLaunchUI.CarryActions. Studio owns the GUI and its Ui-* motion
	and sound attributes; this controller only owns carry-state visibility and
	the Drop button's network request.

	DropLaunchUI resets with PlayerGui on respawn, so references are resolved
	lazily and cached only while their ScreenGui clone is still parented. A new
	clone is rebound and receives the current carry-state visibility.

	CarryingTier is intentionally an Attribute, not Replica state (see
	MergeService's PHASE 2 header note): it's public -- anyone standing nearby
	can already see what a player is carrying -- so reading it here is not a
	trust boundary, only a "should this client draw the controls" signal.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CarryController")

local player = Players.LocalPlayer

local CarryController = {}

local dropLaunchUi: ScreenGui? = nil
local carryActions: Frame? = nil
local dropButton: TextButton? = nil

local connectedButton: TextButton? = nil
local activatedConnection: RBXScriptConnection? = nil
local visibilityUpdate = 0

--[[
	Yields only on a cold cache or after PlayerGui is wiped on respawn. Keep
	this behind task.spawn/event handlers so Init can connect CarryingTier first.
]]
local function resolveUi(): (Frame, TextButton)
	local cachedUi = dropLaunchUi
	local cachedActions = carryActions
	local cachedButton = dropButton
	if
		cachedUi ~= nil
		and cachedUi.Parent ~= nil
		and cachedActions ~= nil
		and cachedActions.Parent ~= nil
		and cachedButton ~= nil
		and cachedButton.Parent ~= nil
	then
		return cachedActions, cachedButton
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local ui = playerGui:WaitForChild("DropLaunchUI") :: ScreenGui
	local actions = ui:WaitForChild("CarryActions") :: Frame
	local button = actions:WaitForChild("Drop") :: TextButton

	dropLaunchUi = ui
	carryActions = actions
	dropButton = button

	return actions, button
end

local function bindDropButton(button: TextButton)
	-- The authored button has the UIKitController Ui-* tween/sound attributes.
	-- It was not tagged in Studio, so retain the repo-wide UIButton opt-in too.
	if not CollectionService:HasTag(button, "UIButton") then
		CollectionService:AddTag(button, "UIButton")
	end

	if connectedButton == button then
		return
	end

	if activatedConnection ~= nil then
		activatedConnection:Disconnect()
	end

	connectedButton = button
	activatedConnection = button.Activated:Connect(function()
		Net.mergeDropRequest.send()
	end)
end

local function queueCarryingVisibility(tier: unknown)
	visibilityUpdate += 1
	local thisUpdate = visibilityUpdate

	task.spawn(function()
		local actions, button = resolveUi()
		if thisUpdate ~= visibilityUpdate then
			return
		end

		bindDropButton(button)
		actions.Visible = tier ~= nil
	end)
end

local function watchPlayerGui()
	local playerGui = player:WaitForChild("PlayerGui")

	playerGui.ChildAdded:Connect(function(child)
		if child.Name ~= "DropLaunchUI" or not child:IsA("ScreenGui") then
			return
		end

		queueCarryingVisibility(player:GetAttribute("CarryingTier"))
	end)
end

function CarryController.Init()
	-- Split to a local before :Connect (quality-gate.md Gate 2) -- calling
	-- :GetAttributeChangedSignal directly on the chained expression is the
	-- same method-chain-off-a-call-result trap the checklist calls out.
	local carryingTierChanged = player:GetAttributeChangedSignal("CarryingTier")
	carryingTierChanged:Connect(function()
		queueCarryingVisibility(player:GetAttribute("CarryingTier"))
	end)

	-- PlayerGui resolution can yield, so start the respawn watcher only after
	-- the attribute listener is connected.
	task.spawn(watchPlayerGui)

	-- Read the current value once, right after connecting -- MergeService
	-- could set it before this Init() runs. queueCarryingVisibility defers the
	-- yielding UI resolution without losing this defensive initial read.
	queueCarryingVisibility(player:GetAttribute("CarryingTier"))

	log.info("ready (DropLaunchUI)")
end

return CarryController
