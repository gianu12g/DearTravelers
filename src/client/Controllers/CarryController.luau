--!strict
--[[
	Binds the merge-gameplay carry mechanic to the Studio-authored controls in
	PlayerGui.Screens.DropLaunchUI.CarryActions. Studio owns the GUI and its
	Ui-* motion and sound attributes; this controller only owns carry-state
	visibility and the A.Drop button's network request.

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

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CarryController")

local player = Players.LocalPlayer

local CarryController = {}

local dropLaunchUi: ScreenGui? = nil
local carryActions: Frame? = nil
local dropButton: TextButton? = nil
local healthLabel: TextLabel? = nil
local damageLabel: TextLabel? = nil

local connectedButton: TextButton? = nil
local activatedConnection: RBXScriptConnection? = nil
local visibilityUpdate = 0

local connectedScreensFolder: Instance? = nil
local screensChildAddedConnection: RBXScriptConnection? = nil

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
	local screens = playerGui:WaitForChild("Screens") :: Folder
	local ui = screens:WaitForChild("DropLaunchUI") :: ScreenGui
	local actions = ui:WaitForChild("CarryActions") :: Frame
	local button = actions:WaitForChild("A.Drop") :: TextButton

	dropLaunchUi = ui
	carryActions = actions
	dropButton = button

	--[[
		The two carry-info readouts. Resolved with the rest of the UI so they
		are re-found after a respawn re-clones PlayerGui, and looked up
		defensively rather than with WaitForChild: they are decoration, and a
		frame authored without them must not block the DROP button from binding.
	]]
	local launchButton = actions:FindFirstChild("C.Launch")
	local dropInfo = button:FindFirstChild("InfoFrame")
	local launchInfo = if launchButton ~= nil then launchButton:FindFirstChild("InfoFrame") else nil
	local health = if dropInfo ~= nil then dropInfo:FindFirstChild("healthLabel") else nil
	local damage = if launchInfo ~= nil then launchInfo:FindFirstChild("damageLabel") else nil
	healthLabel = if health ~= nil and health:IsA("TextLabel") then health else nil
	damageLabel = if damage ~= nil and damage:IsA("TextLabel") then damage else nil

	return actions, button
end

--[[
	Fills the carry readouts from what the server published about the held
	squishy. Called on every carry-state change, and again whenever its health
	moves (someone else's launch can damage a squishy you are holding).

	Health is the live current value. Damage calls the same shared
	MergeConfig.damageForTier the server's impact resolution uses, so the
	readout cannot drift from what the launch actually does. That curve takes
	no health multiplier by design: the 2x Squishy Health pass raises how much
	a squishy can take, not how hard it hits, and the readout must not promise
	otherwise.
]]
local function refreshCarryInfo()
	local health = healthLabel
	if health ~= nil then
		local current = player:GetAttribute("CarryingHealth")
		health.Text = if type(current) == "number" then Format.FormatNumber(current) else "0"
	end

	local damage = damageLabel
	if damage ~= nil then
		local tier = player:GetAttribute("CarryingTier")
		if type(tier) == "number" then
			damage.Text = Format.FormatNumber(MergeConfig.damageForTier(tier))
		else
			damage.Text = "0"
		end
	end
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
		-- Fill BEFORE showing, so the panel never appears holding the previous
		-- squishy's numbers for a frame.
		refreshCarryInfo()
		actions.Visible = tier ~= nil
	end)
end

--[[
	Health can change while the panel is already open, without CarryingTier ever
	moving. Repainting only the labels avoids re-running the whole visibility
	path (and its UI resolution yield) for a number change.
]]
local function queueCarryInfoRefresh()
	if carryActions == nil or carryActions.Parent == nil then
		return
	end
	refreshCarryInfo()
end

local function watchScreensFolder(folder: Instance)
	if connectedScreensFolder == folder then
		return
	end
	if screensChildAddedConnection ~= nil then
		screensChildAddedConnection:Disconnect()
	end
	connectedScreensFolder = folder
	screensChildAddedConnection = folder.ChildAdded:Connect(function(child)
		if child.Name == "DropLaunchUI" and child:IsA("ScreenGui") then
			queueCarryingVisibility(player:GetAttribute("CarryingTier"))
		end
	end)
end

local function watchPlayerGui()
	local playerGui = player:WaitForChild("PlayerGui")

	playerGui.ChildAdded:Connect(function(child: Instance)
		if child.Name ~= "Screens" then
			return
		end
		-- ResetPlayerGuiOnSpawn re-clones the whole PlayerGui at once, so
		-- Screens arrives here as a single unit with DropLaunchUI already
		-- parented inside it -- resolve directly instead of waiting for a
		-- ChildAdded on the folder that already fired (if at all) before
		-- watchScreensFolder below could connect.
		queueCarryingVisibility(player:GetAttribute("CarryingTier"))
		watchScreensFolder(child)
	end)

	-- Screens can already exist by the time this connects (the common case,
	-- since resolveUi above already WaitForChild's it) or can still be on its
	-- way in on a slow first boot -- the ChildAdded connection above catches
	-- the late-arrival case, and this catches the already-there case, so
	-- individual re-clones of DropLaunchUI inside it are watched from here on
	-- regardless of which race won.
	local existingScreens = playerGui:FindFirstChild("Screens")
	if existingScreens ~= nil then
		watchScreensFolder(existingScreens)
	end
end

function CarryController.Init()
	-- Split to a local before :Connect (quality-gate.md Gate 2) -- calling
	-- :GetAttributeChangedSignal directly on the chained expression is the
	-- same method-chain-off-a-call-result trap the checklist calls out.
	local carryingTierChanged = player:GetAttributeChangedSignal("CarryingTier")
	carryingTierChanged:Connect(function()
		queueCarryingVisibility(player:GetAttribute("CarryingTier"))
	end)

	-- Same split-before-Connect rule as above (quality-gate.md Gate 2).
	local carryingHealthChanged = player:GetAttributeChangedSignal("CarryingHealth")
	carryingHealthChanged:Connect(queueCarryInfoRefresh)
	local carryingMaxHealthChanged = player:GetAttributeChangedSignal("CarryingMaxHealth")
	carryingMaxHealthChanged:Connect(queueCarryInfoRefresh)

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
