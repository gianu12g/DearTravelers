--!strict
--[[
	Phase 3 of the merge-gameplay loop: purely cosmetic "+$X" popups over
	every owned merge object, roughly once per second, so a full pad reads as
	visibly earning. This is decoration only -- MergeService's own income
	tick (its PHASE 3 header note) is what actually grants coins; this
	controller sends nothing and reads nothing that isn't already public
	world state, so it cannot desync a balance even if it drifts or misses a
	beat entirely.

	DISCOVERY: bases are static (Workspace.MapLayout.Bases.Base1..Base8), but
	each base's "MergeObjects" folder is created and destroyed at runtime by
	MergeService.activateBase/deactivateBase, and individual MergeObject
	Parts inside it come and go on every auto-spawn, drop, and merge. So this
	watches three layers, each with its own ChildAdded/ChildRemoved:
	Bases (for bases that stream in late), each base Part (for its
	MergeObjects folder appearing/disappearing), and each MergeObjects folder
	(for the Parts themselves). `Instance:Destroy()` disconnects that
	instance's own connections, so a destroyed MergeObjects folder needs no
	explicit teardown of the ChildAdded/ChildRemoved connected on IT -- only
	`trackedParts` (keyed on the Parts, which live longer than any one
	folder's connections in Lua-table terms) needs an explicit sweep, done in
	updatePopups below.

	Every resting MergeObject Part carries a `Tier` attribute set once at
	creation and never changed afterward (materializeObject never mutates an
	existing Part's Tier -- a merge always produces a brand-new Part), so it
	is read live rather than cached, same as every other attribute-observer
	in this codebase (PromptController, CarryController), but there is
	nothing to react to changing mid-life.

	spawnMergeVfx's anchor Part is parented into the SAME MergeObjects folder
	as real objects (MergeService.luau), named "MergeVfx" rather than
	"MergeObject" and carrying no Tier attribute -- the name filter in
	trackPart below is what keeps it from being mistaken for an income
	source and defaulting to a phantom tier-1 popup.

	CARRIED OBJECTS: popups are skipped while an object is being carried,
	detected via the presence of a "CarryWeld" child (the exact WeldConstraint
	MergeService.pickUp creates and every carry-ending path destroys) --
	a purely observational signal that already exists for a different reason,
	so no new attribute or remote is needed to know "is this specific Part,
	anyone's, being carried right now". Income still accrues server-side
	either way (MergeService sums data.Merge.Objects regardless of carry
	state); this is a visual choice only, made because a popup tweening
	upward from a part that is itself moving with the carrying character
	would fight its own motion.

	SCHEDULING: one Heartbeat loop drives every tracked Part's popup timer
	(a `nextFireTime` timestamp, not a per-object task.spawn/wait loop) --
	the same "one loop, not N" shape MergeService's own Heartbeat consolidation
	uses, and for the same reason: a full 8-base server can have on the order
	of 200 tracked Parts, and 200 threads waking up every second is exactly
	the kind of cost this file exists to avoid. Each Part's first fire is
	offset by a random fraction of INCOME_INTERVAL so a freshly-filled pad's
	objects shimmer independently instead of firing in one synchronized
	burst every second -- purely a "rain, not a metronome" visual choice.

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
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)

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

local random = Random.new()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type TrackedPart = {
	nextFireTime: number,
}

local trackedParts: { [BasePart]: TrackedPart } = {}
local popupHost: Folder? = nil
-- watchBase is called both from the Start() GetChildren snapshot and from
-- basesFolder.ChildAdded -- a base already present at Start() would
-- otherwise be watched twice if ChildAdded also fired for it (observed for
-- instances that exist before the connection, on some replication timings),
-- stacking duplicate ChildAdded/ChildRemoved listeners on the same base Part.
local watchedBases: { [BasePart]: boolean } = {}

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
	label.TextColor3 = Color3.fromRGB(255, 221, 110)
	label.TextStrokeTransparency = 0.4
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

local function untrackPart(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	trackedParts[part] = nil
end

local function trackPart(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	-- Name filter, not just "any child of this folder": spawnMergeVfx's
	-- burst anchor lives in the same folder, is named "MergeVfx", and has no
	-- Tier attribute -- without this it would be tracked and popup as a
	-- phantom tier-1 object on every merge.
	if part.Name ~= "MergeObject" then
		return
	end
	if trackedParts[part] ~= nil then
		return -- already tracked (defensive; ChildAdded fires once per add)
	end

	-- Random phase offset, not a shared clock: see the header's SCHEDULING
	-- note for why a full pad should shimmer rather than fire in lockstep.
	trackedParts[part] = { nextFireTime = os.clock() + random:NextNumber() * MergeConfig.INCOME_INTERVAL }
end

local function watchMergeObjectsFolder(folder: Folder)
	for _, child in folder:GetChildren() do
		trackPart(child)
	end
	folder.ChildAdded:Connect(trackPart)
	folder.ChildRemoved:Connect(untrackPart)
end

local function watchBase(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local basePart = instance

	if watchedBases[basePart] then
		return
	end
	watchedBases[basePart] = true

	local existing = basePart:FindFirstChild("MergeObjects")
	if existing ~= nil and existing:IsA("Folder") then
		watchMergeObjectsFolder(existing)
	end

	-- Fires again on every future re-activation: MergeService.activateBase
	-- creates a brand-new Folder instance each time (never reuses one), so
	-- this one persistent connection on the (never-destroyed) base Part is
	-- enough to pick up every generation of it.
	basePart.ChildAdded:Connect(function(child: Instance)
		if child.Name == "MergeObjects" and child:IsA("Folder") then
			watchMergeObjectsFolder(child)
		end
	end)
end

--[[
	One Heartbeat tick for every tracked Part. Stale-part removal is
	collected into a list and applied AFTER the loop, not inside it -- same
	"don't remove a table's keys while a `for...in` is traversing it" rule
	MergeService.reArmSweep follows for its own disarmed-part sweep.

	Distance-gated BEFORE spawnPopup, not just left to BillboardGui.MaxDistance:
	MaxDistance only culls rendering, so without this every tracked part on
	every one of the 8 bases would still allocate a BillboardGui + two tweens
	every second regardless of whether the camera could ever see it -- on a
	full server that's ~200 creates/destroys a second, ~90% of them invisible.
	MaxDistance stays on the billboard as the visual backstop for the
	remaining case (camera whips away mid-tween).
]]
local function updatePopups()
	local now = os.clock()
	local stale: { BasePart } = {}
	local camera = Workspace.CurrentCamera

	for part, info in trackedParts do
		if part.Parent == nil then
			table.insert(stale, part) -- defensive; ChildRemoved should already have caught this
			continue
		end
		if now < info.nextFireTime then
			continue
		end

		-- Snap instead of incrementally catching up: after a multi-second
		-- hitch, `now` can be many INCOME_INTERVALs past nextFireTime, and
		-- advancing by exactly one per tick would fire a burst of one popup
		-- per frame per part until it catches up. Snapping to "one interval
		-- from now" fires once and resumes the normal cadence.
		if now - info.nextFireTime > MergeConfig.INCOME_INTERVAL then
			info.nextFireTime = now + MergeConfig.INCOME_INTERVAL
		else
			info.nextFireTime += MergeConfig.INCOME_INTERVAL
		end

		if part:FindFirstChild("CarryWeld") ~= nil then
			continue -- currently carried -- see the header's CARRIED OBJECTS note
		end

		if camera ~= nil and (camera.CFrame.Position - part.Position).Magnitude > MAX_RENDER_DISTANCE then
			continue -- off-screen (or camera lost) -- not worth the alloc
		end

		spawnPopup(part)
	end

	for _, part in stale do
		trackedParts[part] = nil
	end
end

function IncomePopupController.Start()
	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- income popups disabled")
		return
	end

	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- income popups disabled")
		return
	end

	for _, child in basesFolder:GetChildren() do
		watchBase(child)
	end
	basesFolder.ChildAdded:Connect(watchBase)

	RunService.Heartbeat:Connect(updatePopups)

	log.info("ready")
end

return IncomePopupController
