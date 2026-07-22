--!strict
--[[
	Boot-time loading screen. Ported from the source's
	ReplicatedFirst/LoadingScreen.luau (PORT-SPEC.md §1/§8). Reparents
	ReplicatedFirst.LoadingScreenUi into PlayerGui, disables the default
	Roblox loading screen, tweens a progress bar while preloading assets,
	shows a Skip button after 3s, fades out, restores the camera, then
	signals UIKitController to auto-open the DailyRewards frame.

	This runs in ReplicatedFirst, before StarterPlayerScripts.Controllers
	exists -- Loader.load() hasn't required a single Controller yet by the
	time this script starts, so it must not require any *Controller
	(UIKitController included). It CAN require plain shared modules (no
	lifecycle, Loader ignores them) -- this file uses the UISystem Config
	modules for icon ids, and deliberately does NOT require Shared.Net or
	Shared.UISystem.Net: both block on the client until BytenetStorage AND
	their namespace replicate, which is exactly the kind of wait this
	script cannot afford this early and does not need (see those modules'
	own header comments).

	Handshake with UIKitController (open DailyRewards once loading ends):
	a bare Signal fire would race -- UIKitController.Start() may not have
	run yet, and a fire with no listener connected is simply lost, not
	queued. Instead this sets an ATTRIBUTE on the ReplicatedFirst service
	itself once loading finishes. An attribute is state, not an event: it
	persists regardless of which side gets there first, so
	UIKitController.Start() can check it directly if it's late, or listen
	for the AttributeChanged signal if it's early. See
	UIKitController.luau's watchLoadingScreenHandshake for the read side.
]]

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local loadingScreenUi = ReplicatedFirst:FindFirstChild("LoadingScreenUi")
if loadingScreenUi == nil then
	-- Nothing to do: either the place hasn't been set up per PORT-SPEC.md
	-- §6, or another script already claimed it. Don't hang the boot on a
	-- missing screen.
	return
end

loadingScreenUi.Parent = playerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

local container = loadingScreenUi:WaitForChild("LoadingScreen")
local progressHolder = container:WaitForChild("ProgressHolder")
local progressBar = progressHolder:WaitForChild("Bar") :: Frame
local middle = container:WaitForChild("Middle")
local skipButton = middle:WaitForChild("Skip") :: TextButton
local icon = middle:WaitForChild("GameIcon") :: ImageLabel

skipButton.Visible = false
progressBar.Size = UDim2.fromScale(0, 1)

local progressTween = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

icon.Rotation = -10
local shakeTween = TweenService:Create(
	icon,
	TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Rotation = 10 }
)
shakeTween:Play()

task.delay(3, function()
	if loadingScreenUi.Parent == nil then
		return
	end
	skipButton.Visible = true
	skipButton.BackgroundTransparency = 1
	skipButton.TextTransparency = 1

	TweenService:Create(
		skipButton,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0, TextTransparency = 0 }
	):Play()
end)

local skipped = false
skipButton.MouseButton1Click:Connect(function()
	skipped = true
end)

--[[
	The source called ContentProvider:PreloadAsync(game:GetDescendants())
	-- every instance in the whole DataModel. That is slow (thousands of
	instances, most of them nothing to do with what a player looks at
	before the game is interactive) and unbounded. Instead: PlayerGui
	(whatever of Main/Full has already cloned in from StarterGui by now --
	that replication is independent of this script's own execution order)
	plus ReplicatedStorage.Assets (the Confetti/Shine templates) plus every
	icon id referenced by the UISystem Config modules, since
	ContentProvider:PreloadAsync accepts bare "rbxassetid://" strings
	alongside Instances.
]]
-- ReplicatedFirst runs before ReplicatedStorage's descendants are guaranteed
-- to exist on the client. These modules are plain config tables and are safe
-- to require here, but their folder chain still has to finish replicating.
local shared = ReplicatedStorage:WaitForChild("Shared")
local uiSystem = shared:WaitForChild("UISystem")
local config = uiSystem:WaitForChild("Config")

local DailyRewardsConfig = require(config:WaitForChild("DailyRewards") :: ModuleScript)
local PlaytimeRewardsConfig = require(config:WaitForChild("PlaytimeRewards") :: ModuleScript)
local PromotionConfig = require(config:WaitForChild("Promotion") :: ModuleScript)
local WheelSpinConfig = require(config:WaitForChild("WheelSpin") :: ModuleScript)

local targets: { Instance | string } = {}

local mainGui = playerGui:FindFirstChild("Main") or playerGui:WaitForChild("Main", 5)
if mainGui ~= nil then
	for _, descendant in mainGui:GetDescendants() do
		table.insert(targets, descendant)
	end
end

local fullGui = playerGui:FindFirstChild("Full") or playerGui:WaitForChild("Full", 5)
if fullGui ~= nil then
	for _, descendant in fullGui:GetDescendants() do
		table.insert(targets, descendant)
	end
end

local assets = ReplicatedStorage:FindFirstChild("Assets") or ReplicatedStorage:WaitForChild("Assets", 10)
if assets ~= nil then
	for _, descendant in assets:GetDescendants() do
		table.insert(targets, descendant)
	end
end

for _, info in DailyRewardsConfig do
	table.insert(targets, `rbxassetid://{info.Icon}`)
end
for _, info in PlaytimeRewardsConfig.Rewards do
	table.insert(targets, `rbxassetid://{info.Icon}`)
end
for _, info in WheelSpinConfig.Rewards do
	table.insert(targets, `rbxassetid://{info.Icon}`)
end
for _, id in PromotionConfig.Packs do
	table.insert(targets, `rbxassetid://{id}`)
end
for _, id in PromotionConfig.Passes do
	table.insert(targets, `rbxassetid://{id}`)
end
for _, id in PromotionConfig.Products do
	table.insert(targets, `rbxassetid://{id}`)
end

local totalAssets = #targets
local loadedAssets = 0
local PRELOAD_BATCH_SIZE = 25

for firstIndex = 1, totalAssets, PRELOAD_BATCH_SIZE do
	if skipped then
		break
	end

	local batch: { Instance | string } = {}
	local lastIndex = math.min(firstIndex + PRELOAD_BATCH_SIZE - 1, totalAssets)
	for index = firstIndex, lastIndex do
		table.insert(batch, targets[index])
	end

	pcall(function()
		-- PreloadAsync's real signature accepts a mixed array of Instances
		-- and "rbxassetid://" strings (Roblox's own documented behavior);
		-- luau-lsp isn't available in this environment to confirm the
		-- bundled type definition agrees, hence the narrow boundary cast.
		ContentProvider:PreloadAsync(batch :: any)
	end)

	loadedAssets += #batch
	local progress = if totalAssets > 0 then loadedAssets / totalAssets else 1

	TweenService:Create(progressBar, progressTween, { Size = UDim2.fromScale(progress, 1) }):Play()

	task.wait()
end

if not game:IsLoaded() and not skipped then
	game.Loaded:Wait()
end

TweenService:Create(
	progressBar,
	TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	{ Size = UDim2.fromScale(1, 1) }
):Play()

task.wait(0.4)

local originalFov = if camera ~= nil then camera.FieldOfView else nil
if camera ~= nil then
	camera.FieldOfView = 45
end

local blur = Instance.new("BlurEffect")
blur.Name = "LoadingScreenBlur"
blur.Size = 24
blur.Parent = Lighting

if camera ~= nil and originalFov ~= nil then
	TweenService
		:Create(
			camera,
			TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ FieldOfView = originalFov }
		)
		:Play()
end
TweenService:Create(blur, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = 0 }):Play()

for _, obj in loadingScreenUi:GetDescendants() do
	if obj:IsA("Frame") or obj:IsA("CanvasGroup") then
		TweenService:Create(obj, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
	elseif obj:IsA("TextLabel") or obj:IsA("TextButton") then
		TweenService:Create(obj, TweenInfo.new(0.4), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
	elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		TweenService:Create(obj, TweenInfo.new(0.4), { ImageTransparency = 1, BackgroundTransparency = 1 }):Play()
	elseif obj:IsA("UIStroke") then
		TweenService:Create(obj, TweenInfo.new(0.4), { Transparency = 1 }):Play()
	end
end

task.wait(1)

blur:Destroy()
loadingScreenUi:Destroy()

-- See header comment: this is the handshake, not a direct
-- UIKitController.OpenFrame("DailyRewards") call, because Controllers do
-- not exist yet from this script's point of view.
ReplicatedFirst:SetAttribute("UISystemOpenFrame", "DailyRewards")
