--!strict
--[[
	The DROP button for the merge-gameplay loop's carry mechanic (Phase 2).
	MergeService is server-authoritative for everything that matters --
	pickup, carry, ram-to-merge, and drop-spot placement -- this controller
	only shows a button and asks.

	Deliberately breaks UI-AND-MOTION.md's "Studio owns the GUIs" rule, for
	the same reason DevConsoleController does: this button's entire existence
	is driven by a live per-player Attribute (CarryingTier), not by static
	content anyone would author in Studio, and it must float over whatever
	screen the player already has open rather than becoming one of
	UIController's exclusive screens -- dropping has to work mid-menu the
	same as any other HUD element.

	CarryingTier is intentionally an Attribute, not Replica state (see
	MergeService's PHASE 2 header note): it's public -- anyone standing
	nearby can already see what a player is carrying -- so reading it here is
	not a trust boundary, only a "should this client draw a button" signal.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CarryController")

-- >=44px in both dimensions, the usual mobile-safe touch target size.
local BUTTON_SIZE = UDim2.fromOffset(200, 56)
local BUTTON_BOTTOM_OFFSET = 32
local BACKGROUND_COLOR = Color3.fromRGB(230, 90, 70)
local TEXT_COLOR = Color3.new(1, 1, 1)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CarryController = {}

--[[
	Built once. `ResetOnSpawn = false` is what keeps it alive across
	respawns: PlayerGui gets wiped and re-cloned from StarterGui on every
	spawn (UI-AND-MOTION.md's gotcha), but this ScreenGui was never cloned
	FROM StarterGui in the first place, so without this it would silently
	vanish the first time the player dies.
]]
local function buildGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "CarryHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false

	local button = Instance.new("TextButton")
	button.Name = "DropButton"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -BUTTON_BOTTOM_OFFSET)
	button.Size = BUTTON_SIZE
	button.BackgroundColor3 = BACKGROUND_COLOR
	button.TextColor3 = TEXT_COLOR
	button.Font = Enum.Font.GothamBold
	button.TextSize = 22
	button.Text = "DROP"
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button

	-- Opt into Buttons.luau's hover/press motion (UI-AND-MOTION.md) rather
	-- than hand-rolling it here.
	CollectionService:AddTag(button, "UIButton")

	button.Activated:Connect(function()
		Net.mergeDropRequest.send()
	end)

	gui.Parent = playerGui
	return gui
end

local screenGui: ScreenGui? = nil

local function setCarrying(tier: unknown)
	local gui = screenGui
	if gui == nil then
		return
	end
	gui.Enabled = tier ~= nil
end

function CarryController.Init()
	screenGui = buildGui()

	-- Split to a local before :Connect (quality-gate.md Gate 2) -- calling
	-- :GetAttributeChangedSignal directly on the chained expression is the
	-- same method-chain-off-a-call-result trap the checklist calls out.
	local carryingTierChanged = player:GetAttributeChangedSignal("CarryingTier")
	carryingTierChanged:Connect(function()
		setCarrying(player:GetAttribute("CarryingTier"))
	end)

	-- Read the current value once, right after connecting -- MergeService
	-- could in principle set it before this Init() runs (same defensive
	-- read every attribute-observer in this codebase does; see
	-- MergeService.onPlayerAdded / BaseService's AssignedBase watcher).
	setCarrying(player:GetAttribute("CarryingTier"))

	log.info("ready")
end

return CarryController
