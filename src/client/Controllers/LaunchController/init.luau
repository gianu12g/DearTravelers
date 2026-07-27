--!strict
--[[
	Connects the launch button to the authored LaunchTargetingUI and
	LaunchTargetMarkerUI instances in StarterGui. Targeting takes over the real
	Workspace.CurrentCamera, tweening it to a computed top-down overview pose
	while active and back to wherever the player's camera actually was on every
	exit path. The base ownership visuals now live in each base's NameLabel
	BillboardGui, so no duplicated viewport overlay is required.

	NameLabels use a raised world offset and half their authored size during
	normal play so they clear the forcefield domes without dominating the 3D
	view. During targeting they switch locally to their authored size and zero
	world offset: from the straight-down overview, raising a 3D point creates
	perspective parallax that pushes every label radially away from its base.

	Split into:
	  - Camera: real-camera overview takeover/release (no shared state with
	    the others; owned entirely by Targeting's calls into it).
	  - Targeting: the targeting state machine, hint, target marker/icon, and
	    the mergeLaunchRequest/mergeLaunchResult round trip.
	  - LaunchButton: the DropLaunchUI button, its cooldown visuals, and the
	    PlayerGui/Screens re-clone watching.
	This init wires the two children together plus the lifecycle/input/Net
	glue that touches both.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local LaunchButton = require(script.LaunchButton)
local Targeting = require(script.Targeting)

local log = Log.new("LaunchController")

local player = Players.LocalPlayer

local WAIT_TIMEOUT = 10

local LaunchController = {}

local mapLayoutDescendantAddedConnection: RBXScriptConnection? = nil

function LaunchController.cancelTargeting()
	Targeting.cancelTargeting()
end

function LaunchController.beginTargeting()
	LaunchButton.beginTargeting()
end

function LaunchController.Init()
	Targeting.setBaseLabelsLaunchMode(false)
	task.spawn(function()
		local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
		if mapLayout == nil then
			return
		end

		local previousConnection = mapLayoutDescendantAddedConnection
		if previousConnection ~= nil then
			previousConnection:Disconnect()
		end
		mapLayoutDescendantAddedConnection = mapLayout.DescendantAdded:Connect(function(descendant)
			local parent = descendant.Parent
			local isNameLabel = descendant:IsA("BillboardGui") and descendant.Name == "NameLabel"
			local isForcefield = descendant:IsA("BasePart") and parent ~= nil and parent.Name == "BaseForcefields"
			if not isNameLabel and not isForcefield then
				return
			end

			task.defer(function()
				if mapLayout.Parent ~= nil then
					Targeting.setBaseLabelsLaunchMode(Targeting.isTargeting())
				end
			end)
		end)
		Targeting.setBaseLabelsLaunchMode(Targeting.isTargeting())
	end)

	Net.mergeLaunchResult.listen(Targeting.handleLaunchResult)

	local carryingChanged = player:GetAttributeChangedSignal("CarryingTier")
	carryingChanged:Connect(function()
		Targeting.handleCarryingTierChanged()
		LaunchButton.updateLaunchCooldownDisplay()
	end)
	local launchReadyChanged = player:GetAttributeChangedSignal("CarryingLaunchReadyAt")
	launchReadyChanged:Connect(LaunchButton.updateLaunchCooldownDisplay)
	local radiusDebugChanged = player:GetAttributeChangedSignal(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE)
	radiusDebugChanged:Connect(Targeting.refreshDebugVisibility)

	local cooldownDisplayAccumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		cooldownDisplayAccumulator += dt
		if cooldownDisplayAccumulator < 0.1 then
			return
		end
		cooldownDisplayAccumulator = 0
		LaunchButton.updateLaunchCooldownDisplay()
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not Targeting.isTargeting() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.UserInputType == Enum.UserInputType.MouseButton2 then
			Targeting.cancelTargeting()
		elseif not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			Targeting.chooseTarget(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)

	UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
		if
			Targeting.isTargeting()
			and not Targeting.isAwaitingServer()
			and not gameProcessed
			and #touchPositions > 0
		then
			Targeting.chooseTarget(touchPositions[1])
		end
	end)

	task.spawn(LaunchButton.watchPlayerGui)
	log.info("ready (real-camera launch targeting)")
end

return LaunchController
