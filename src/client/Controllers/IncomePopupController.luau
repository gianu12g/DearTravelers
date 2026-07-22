--!strict
--[[
	Phase 3 of the merge-gameplay loop: purely cosmetic "+$X" popups over
	every resting merge object on the local player's base. MergeService grants
	the authoritative aggregated income first, then sends one
	mergeIncomePulse event to that player. Handling one event by walking that
	base's current MergeObjects children makes every popup start in the same
	frame. A model created between pulses automatically joins the next one;
	there is no per-model phase, timer, task, or connection to synchronize.

	The packet carries no amount or balance. Persistent Coins still replicate
	through DataService/Replica; missing this transient packet can only omit a
	visual flourish and can never desync currency.

	Every resting MergeObject Part carries a `Tier` attribute set once at
	creation and never changed afterward (materializeObject never mutates an
	existing Part's Tier -- a merge always produces a brand-new Part), so it
	is read live rather than cached, same as every other attribute-observer
	in this codebase (PromptController, CarryController), but there is
	nothing to react to changing mid-life.

	spawnMergeVfx's anchor Part is parented into the SAME MergeObjects folder
	as real objects (MergeService.luau), named "MergeVfx" rather than
	"MergeObject" and carrying no Tier attribute -- the pulse's name filter
	keeps it from becoming a phantom tier-1 popup.

	CARRIED OBJECTS: popups are skipped while an object is being carried,
	detected via the presence of a "CarryWeld" child (the exact WeldConstraint
	MergeService.pickUp creates and every carry-ending path destroys) --
	a purely observational signal that already exists for a different reason,
	so no new attribute or remote is needed to know "is this specific Part,
	anyone's, being carried right now". Income still accrues server-side
	either way (MergeService sums data.Merge.Squishies regardless of carry
	state); this is a visual choice only, made because a popup tweening
	upward from a part that is itself moving with the carrying character
	would fight its own motion.

	PARENTING: popups are BillboardGuis parented under a client-owned Folder
	in PlayerGui (the same container CarryController's HUD lives under) with
	`Adornee` set to the target Part, NOT parented as children of the Parts
	themselves. A BillboardGui renders relative to its Adornee regardless of
	where it's actually parented, so this keeps every client-created instance
	out of the server-replicated MergeObjects folder -- that folder and its
	Parts are destroyed and recreated constantly (every merge, every pad
	(de)activation), and a popup parented inside it would be yanked away
	mid-tween instead of finishing its own independent fade-and-destroy on
	schedule. Once spawned, a popup's lifetime is entirely decoupled from its
	target Part's: if the Part is destroyed mid-tween (the object it was
	celebrating just got merged into something else), the popup simply loses
	its Adornee and stops rendering, but the Lua-side tween/cleanup was never
	relying on the Part being alive to finish, so nothing errors and nothing
	leaks.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("IncomePopupController")

-- Same tolerance as MergeService/BaseService's own map-hierarchy waits: a
-- base whose pieces never stream in must not hang this controller forever.
local WAIT_TIMEOUT = 10

local RISE_DISTANCE = 3.5 -- studs the popup tweens upward before destroying itself
local POPUP_LIFETIME = 0.9 -- seconds -- tween AND fade duration together
local POPUP_TWEEN_INFO = TweenInfo.new(POPUP_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Generous rather than tuned to the map's actual base spacing (unknown to
-- this file, and MergeConfig doesn't track world-space base layout) -- far
-- enough that a player standing on their own pad always sees its popups,
-- short enough that a full 8-base server isn't rendering all of them at once.
local MAX_RENDER_DISTANCE = 90

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local basesFolder: Instance? = nil
local popupHost: Folder? = nil

local IncomePopupController = {}

local function getPopupHost(): Folder
	local host = popupHost
	if host ~= nil then
		return host
	end

	local folder = Instance.new("Folder")
	folder.Name = "IncomePopups"
	folder.Parent = playerGui
	popupHost = folder
	return folder
end

-- Same NaN/range guard as MergeService.sanitizeTier and
-- MergeConfig.incomeForTier -- this Part's Tier attribute is `any` from
-- Luau's perspective, and MergeConfig.incomeForTier already re-guards it
-- internally, but MergeConfig.Tiers[tier] below is indexed directly and
-- needs the same clamp to stay in bounds.
local function sanitizeTier(tier: unknown): number
	-- Ternary form, not a guard-clause early return: same shape
	-- InventoryService uses for narrowing an unknown-typed value inline
	-- (InventoryService.luau's held-count reads), which keeps the
	-- narrowing entirely inside one expression instead of relying on
	-- flow-typing across two statements.
	local raw = if type(tier) == "number" and tier == tier then tier else 1
	return math.clamp(math.floor(raw), 1, MergeConfig.MAX_TIER)
end

local function spawnPopup(part: BasePart)
	local tier = sanitizeTier(part:GetAttribute("Tier"))
	local tierDef = MergeConfig.Tiers[tier]
	local amount = MergeConfig.incomeForTier(tier)

	local startOffset = Vector3.new(0, tierDef.Size / 2 + 0.5, 0)
	local endOffset = startOffset + Vector3.new(0, RISE_DISTANCE, 0)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "IncomePopup"
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(100, 32)
	billboard.StudsOffset = startOffset
	-- Deliberately false, unlike the resting object's own IncomeLabel: that
	-- label is persistent HUD-ish info that must always read through
	-- geometry, but a popup is a one-shot flourish -- letting it occlude
	-- normally reads as more "in the world" and cheaper to render at scale.
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = MAX_RENDER_DISTANCE
	billboard.Parent = getPopupHost()

	local label = Instance.new("TextLabel")
	label.Name = "AmountText"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(118, 255, 102)
	label.TextStrokeColor3 = Color3.fromRGB(24, 78, 35)
	label.TextStrokeTransparency = 0.2
	label.Text = "+$" .. Format.FormatNumber(amount)
	label.Parent = billboard

	local destroyed = false
	local function destroyPopup()
		if destroyed then
			return
		end
		destroyed = true
		billboard:Destroy()
	end

	local riseTween = TweenService:Create(billboard, POPUP_TWEEN_INFO, { StudsOffset = endOffset })
	local fadeTween = TweenService:Create(label, POPUP_TWEEN_INFO, { TextTransparency = 1, TextStrokeTransparency = 1 })

	riseTween.Completed:Once(destroyPopup)
	riseTween:Play()
	fadeTween:Play()

	-- Belt-and-suspenders: Completed also fires on Cancel with a non-
	-- Completed PlaybackState, and this popup has no owner that would ever
	-- cancel it, but a bare timeout means it is IMPOSSIBLE for a popup to
	-- outlive its own animation regardless of how TweenService's signal
	-- behaves.
	task.delay(POPUP_LIFETIME + 0.5, destroyPopup)
end

--[[
	One authoritative pulse, one snapshot of the local player's current base.
	No cached Part list is needed: MAX_OBJECTS bounds this to 25 children once
	per second, and reading the folder live is what makes a newly spawned or
	merged model automatically share the next pulse.

	Distance is checked before allocation, not left only to MaxDistance, so a
	remote camera cannot create invisible BillboardGuis and tweens.
]]
local function showIncomePulse()
	local currentBasesFolder = basesFolder
	if currentBasesFolder == nil then
		return -- Start has not resolved the streamed map hierarchy yet
	end

	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return
	end

	local base = currentBasesFolder:FindFirstChild(baseName)
	local mergeObjects = if base ~= nil then base:FindFirstChild("MergeObjects") else nil
	if mergeObjects == nil then
		return
	end

	local camera = Workspace.CurrentCamera
	for _, part in mergeObjects:GetChildren() do
		if not part:IsA("BasePart") or part.Name ~= "MergeObject" then
			continue
		end
		if part:FindFirstChild("CarryWeld") ~= nil then
			continue -- currently carried -- see the header's CARRIED OBJECTS note
		end

		if camera ~= nil and (camera.CFrame.Position - part.Position).Magnitude > MAX_RENDER_DISTANCE then
			continue -- off-screen (or camera lost) -- not worth the alloc
		end

		spawnPopup(part)
	end
end

function IncomePopupController.Init()
	Net.mergeIncomePulse.listen(showIncomePulse)
end

function IncomePopupController.Start()
	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- income popups disabled")
		return
	end

	local foundBasesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if foundBasesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- income popups disabled")
		return
	end
	basesFolder = foundBasesFolder

	log.info("ready")
end

return IncomePopupController
