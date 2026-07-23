--!strict
--[[
	Server-authoritative spawning for the merge-gameplay loop (Phase 1): each
	player's base pad auto-spawns tiered objects at a free rate, persisted and
	restored across sessions. Free placement -- no grid, no slots.

	OWNERSHIP: BaseService (not modified here) publishes base ownership as the
	`AssignedBase` attribute on the Player -- see its header for why an
	attribute rather than Replica. This service treats that attribute as the
	single source of truth for "does this player have a live pad right now":
	it watches GetAttributeChangedSignal AND reads the attribute's current
	value once right after connecting, because BaseService may have already
	assigned a base before this service's Start() got around to hooking the
	player (join order between two services' Start()s is unspecified -- both
	just need every Init() to have finished, per ARCHITECTURE.md).

	ACTIVATION IS ASYNC, OWNERSHIP CAN CHANGE MID-FLIGHT: going live on a base
	means waiting for that player's profile data (waitForData, same polling
	pattern as PlaytimeRewardsService/FriendRewardService) and then creating
	Parts -- both of which yield or at least take real time. If the player
	releases (or is reassigned) their base while that is in flight, the
	in-progress activation must not win the race and materialize a pad the
	player no longer owns. `activationTokens` exists solely for this: every
	activate/deactivate bumps the player's token, and the async body checks
	its captured token still matches before each side effect. This is the
	same "can this stale work still commit" problem BaseService's header
	explains for claimBase, just solved with a token instead of a yield-free
	prefix, because unlike claimBase this genuinely has to yield.

	IDENTITY, NOT INDEX: each live pad's `parts` map is BasePart -> the exact
	entry table stored in that player's Merge.Squishies array (the SAME table,
	not a copy -- profile.Data flows through untouched, same as everywhere
	else in this codebase). table.clone(Squishies) when appending copies the
	array wrapper but not the entry tables inside it, so this identity survives
	every future write. Phase 2's drag/merge/remove must key off these table
	identities (e.g. table.find(currentObjects, entry)) and never off a
	remembered numeric index -- table.remove shifts every later index, but a
	table reference does not move.

	CAPACITY: auto-spawn simply stops writing once a pad holds MAX_OBJECTS.
	No error, no queue -- the pad just waits until Phase 2 frees a slot.

	PHASE 2 -- CARRY/MERGE/DROP:

	Pickup is server-side .Touched on each resting MergeObject part, wired
	once by spawnRestingPart (the single choke point every resting part is
	created through -- auto-spawned, restored on activation, or produced by a
	merge). Touched was chosen over a heartbeat proximity scan for pickup
	specifically because the classic case -- a MOVING character walking into
	a stationary anchored, non-collide part -- is exactly the case Touched
	fires reliably for (this is the standard Roblox "walk over the coin"
	idiom). It is NOT used for merge detection below, where both parts are
	effectively kinematic relative to each other (see that note for why).

	Carry state (`carries`) is deliberately NOT part of LiveBase or persisted
	data: the entry stays in Merge.Squishies at its ORIGINAL X/Z the entire time
	it is carried (see the IDENTITY note above -- `carries[player].entry` is
	the same table as the one inside data.Merge.Squishies), so a crash or a
	pad reassignment mid-carry needs no special-case restore -- the object is
	already exactly where the next activateBase will put it. Only a
	successful drop or merge ever writes a new X/Z.

	Merge detection is a single Heartbeat loop over `carries`, not Touched:
	the carried part is welded (kinematic relative to the character) and the
	target part is anchored (kinematic, full stop), so two kinematic bodies
	overlapping never generates the velocity-driven contact Touched relies
	on -- Touched between two parts that never truly collide is unreliable in
	practice. Distance polling has no such dependency. It stays cheap because
	`carries` only ever holds players actively carrying something (usually
	zero or one at a time per server), and the inner scan is bounded by
	MAX_OBJECTS on that one player's own pad.

	CarryingTier is published as a Player Attribute, not through
	DataService/Replica: it is public info (Phase 1's OWNERSHIP note makes the
	same call for AssignedBase) -- anyone standing nearby can already see what
	a player is carrying, so there is nothing to keep private, and an
	Attribute is the cheap, no-persistence-needed way to tell the client
	CarryController when to show its DROP button.

	Every carry-ending path (drop, launch, merge, character removing, pad
	deactivation) clears `carries[player]` and the attribute before doing
	anything else, so a second signal arriving for the same player
	(e.g. CharacterRemoving firing while a merge is also mid-Heartbeat) finds
	nothing left to act on rather than double-processing.

	No remotes in Phase 1: every decision was made on the server with Parts
	replicating automatically. Phase 2 adds a no-payload "drop request"
	because "which spot" is a server decision
	(see Net.luau's mergeDropRequest comment) but "the player wants to drop
	now" genuinely is client-originated input. Launching adds a bounded map
	X/Z target request; the server still owns its source, surface height,
	damage, radius, flight, and return state.

	DISARM/RE-ARM (walk-off-to-re-arm, no grab cooldowns): a part placed by
	dropCarried, cancelCarry, finishLaunch, or commitMerge's result lands at or right next
	to the owning player, so without this it would be instantly re-Touched
	and re-picked-up -- the player could never actually put anything down.
	markDisarmed adds the part to `live.disarmed`; the pickup Touched handler
	refuses a disarmed part outright; reArmSweep (same Heartbeat as merge
	detection) clears it once re-armed.

	Re-arming requires the owner's character to have stood CONTINUOUSLY
	outside MergeConfig.REARM_CLEARANCE (+ the part's own half-size) for
	MergeConfig.REARM_OUTSIDE_SECONDS, not merely instantly-outside-right-now
	-- `live.disarmed[part]` holds the accumulated continuous-outside
	seconds, reset to 0 the instant the owner is back inside the radius or
	has no character at all. An instant check is NOT enough, and this
	distinction exists specifically because of a real failure mode: at the
	moment commitMerge runs, the ramming player's root is already past
	halfSize + CARRY_GAP (the carry offset) plus 2*halfSize + MERGE_EPSILON
	(the merge threshold) from the result's position -- comfortably outside
	REARM_CLEARANCE on the very first Heartbeat -- and the player's own
	ramming momentum then carries them straight back over the part their own
	merge just re-armed. Do not "simplify" this back to a boolean disarmed
	flag; that regresses exactly this bug.

	Freshly auto-spawned/restored parts are never disarmed in the first
	place -- spawning under your feet giving a free pickup was never the
	complaint. Every path that destroys a possibly-disarmed part (currently
	just commitMerge, consuming the target) clears its `live.disarmed` entry
	too, so no key ever outlives the Part it points at.

	PHASE 3 -- PASSIVE INCOME: see runIncomeTick's own header note for the
	full reasoning. In one line: one aggregated CoinsService.add() per player
	per second, summed over data.Merge.Squishies (not live.parts and not a
	per-object write), riding the same Heartbeat connection as Phase 2 rather
	than spawning a loop per player. After a successful grant, one transient
	mergeIncomePulse event tells that owning client to display every resting
	model's "+$X" popup in the same frame. Coins remains Replica-owned; the
	event carries no balance state.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local CoinsService = require(script.Parent.CoinsService)
local DataService = require(script.Parent.DataService)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local LaunchTrailRuntime = require(ReplicatedStorage.Shared.LaunchTrailRuntime)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local SafePlayerAdded = require(ServerStorage.Modules.UISystem.SafePlayerAdded)
local SquishyProgress = require(ServerStorage.Modules.SquishyProgress)

local log = Log.new("MergeService")

-- Same tolerance and bound as BaseService: a base whose pieces never stream
-- in must not hang Start() (and therefore every player join) forever.
local WAIT_TIMEOUT = 10

local random = Random.new()

-- Mirrors the shape written into DataService's TEMPLATE.Merge.Squishies
-- exactly (DataService.luau, Merge field) -- kept local rather than shared
-- for the same "DataService stays generic" reason documented there.
type MergeObjectEntry = {
	Tier: number,
	X: number,
	Z: number,
	Health: number,
}

type BaseRecord = {
	part: BasePart,
	spawnArea: BasePart,
}

type LaunchMapBounds = {
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
}

type LiveBase = {
	baseName: string,
	spawnArea: BasePart,
	objectsFolder: Folder,
	-- See the header's IDENTITY note: keys are the Parts this service
	-- created, values are the exact entry table each Part represents.
	parts: { [BasePart]: MergeObjectEntry },
	--[[
		Phase 2 UX fix: parts placed where the owner could otherwise
		instantly re-grab them (a drop, a cancelled carry, a merge result)
		start here and leave once the owner has stood CONTINUOUSLY outside
		MergeConfig.REARM_CLEARANCE for MergeConfig.REARM_OUTSIDE_SECONDS --
		see markDisarmed and reArmSweep. Presence = disarmed; the value is
		accumulated continuous-outside seconds, reset to 0 on every frame the
		owner is inside the radius (or has no character at all).

		A plain Lua map, not an Attribute: nothing client-side needs to see
		this, same call `parts` above already makes for server-only
		bookkeeping.
	]]
	disarmed: { [BasePart]: number },
}

-- Phase 2. `entry` is the SAME table referenced from data.Merge.Squishies and
-- from `live.parts[part]` (see the header's IDENTITY note). Drop and damage
-- replace that entry transactionally and update both references together;
-- merge consumes it.
type CarryState = {
	live: LiveBase,
	part: BasePart,
	entry: MergeObjectEntry,
	weld: WeldConstraint,
}

type LaunchState = {
	live: LiveBase,
	part: BasePart,
	entry: MergeObjectEntry,
	trailAttachment0: Attachment?,
	trailAttachment1: Attachment?,
}

type MushBoostState = {
	humanoid: Humanoid,
	originalWalkSpeed: number,
}

-- Populated once during Start(); read-only afterwards.
local bases: { [string]: BaseRecord } = {}
local launchMapLayout: Instance? = nil
local launchMapBounds: LaunchMapBounds? = nil
local launchFallbackSurfaceY = 0
local defaultLaunchTrailTemplate: Model? = nil

local liveBases: { [Player]: LiveBase } = {}
local attributeConnections: { [Player]: RBXScriptConnection } = {}
-- See the header's ACTIVATION IS ASYNC note.
local activationTokens: { [Player]: number } = {}

-- Phase 2. At most one entry per player (capacity is exactly one).
local carries: { [Player]: CarryState } = {}
-- A launched squishy remains the owner's persisted entry and returns to its
-- saved pad position after impact. This state locks only that exact projectile;
-- the owner may keep picking up, dropping, and merging every other squishy
-- while it is in flight.
local activeLaunches: { [Player]: LaunchState } = {}
local mushBoosts: { [Player]: MushBoostState } = {}
-- Drives cancelCarry on death/respawn/leaving -- reverse-indexed by Player
-- for the same reason attributeConnections is (PlayerRemoving only hands us
-- a Player).
local characterRemovingConnections: { [Player]: RBXScriptConnection } = {}

-- Phase 3. Accumulated Heartbeat dt, driving one aggregated income tick per
-- INCOME_INTERVAL -- see runIncomeTick's own header note for why this rides
-- the existing Heartbeat connection instead of a loop per player.
local incomeAccumulator = 0
local activityCheckpointAccumulator = 0

local MUSH_BOOST_AMOUNT = 5
local MUSH_BOOST_DURATION = 5
local mergeInputLimiter = RateLimiter.new(8, 12)
local launchInputLimiter = RateLimiter.new(2, 3)

local MergeService = {}

local function clearCarryingAttributes(player: Player)
	player:SetAttribute("CarryingTier", nil)
	player:SetAttribute("CarryingLaunchReadyAt", nil)
end

local function publishCarryingAttributes(player: Player, tier: number, part: BasePart)
	player:SetAttribute("CarryingTier", tier)
	local readyAt = part:GetAttribute("LaunchReadyAt")
	player:SetAttribute("CarryingLaunchReadyAt", if typeof(readyAt) == "number" then readyAt else nil)
end

local function destroyLaunchTrail(launch: LaunchState)
	local attachment0 = launch.trailAttachment0
	local attachment1 = launch.trailAttachment1
	launch.trailAttachment0 = nil
	launch.trailAttachment1 = nil
	LaunchTrailRuntime.destroy(attachment0, attachment1)
end

-- The one physical Workspace model is the source of truth. Each launch gets
-- cloned attachments and visuals so projectiles never share mutable state.
local function attachDefaultLaunchTrail(launch: LaunchState)
	local template = defaultLaunchTrailTemplate
	if template == nil or launch.part.Parent == nil then
		return
	end

	local ok, err = xpcall(function()
		local attachment0, attachment1 = LaunchTrailRuntime.attach(launch.part, template)
		if attachment0 == nil or attachment1 == nil then
			return
		end
		launch.trailAttachment0 = attachment0
		launch.trailAttachment1 = attachment1
	end, debug.traceback)

	if not ok then
		destroyLaunchTrail(launch)
		log.warn(`default launch trail could not be attached: {err}`)
	end
end

--[[
	Clamps `tier` into [1, MAX_TIER] and floors it, defaulting to 1 for
	anything that isn't a real number (NaN included -- every comparison
	against NaN is false, so it must be caught before the clamp, same trap
	Progression.sanitizeLevel guards against). Profile data for this field is
	only ever written by trySpawnObject below today, but the dev console can
	still plant a bad value directly, and a corrupted Tier must not propagate
	into an out-of-bounds MergeConfig.Tiers lookup.
]]
local function sanitizeTier(tier: number): number
	if type(tier) ~= "number" or tier ~= tier then
		return 1
	end
	return math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitizeHealth(health: number, tier: number): number
	local maxHealth = MergeConfig.healthForTier(tier)
	if type(health) ~= "number" or health ~= health or health == math.huge or health == -math.huge then
		return maxHealth
	end
	return math.clamp(health, 0, maxHealth)
end

local function tierDefFor(tier: number): MergeConfig.TierDef
	return MergeConfig.Tiers[sanitizeTier(tier)]
end

local function calculateLaunchMapBounds(mapLayout: Instance): LaunchMapBounds?
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false

	for _, descendant in mapLayout:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		found = true
		local half = descendant.Size / 2
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = descendant.CFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
					minimum = Vector3.new(
						math.min(minimum.X, corner.X),
						math.min(minimum.Y, corner.Y),
						math.min(minimum.Z, corner.Z)
					)
					maximum = Vector3.new(
						math.max(maximum.X, corner.X),
						math.max(maximum.Y, corner.Y),
						math.max(maximum.Z, corner.Z)
					)
				end
			end
		end
	end

	if not found then
		return nil
	end
	return {
		minX = minimum.X,
		maxX = maximum.X,
		minY = minimum.Y,
		maxY = maximum.Y,
		minZ = minimum.Z,
		maxZ = maximum.Z,
	}
end

local function resolveLaunchTarget(worldX: number, worldZ: number, squishyHalfSize: number): Vector3?
	local mapLayout = launchMapLayout
	local bounds = launchMapBounds
	if mapLayout == nil or bounds == nil or not isFiniteNumber(worldX) or not isFiniteNumber(worldZ) then
		return nil
	end
	if worldX < bounds.minX - 1 or worldX > bounds.maxX + 1 or worldZ < bounds.minZ - 1 or worldZ > bounds.maxZ + 1 then
		return nil
	end

	local safeX = math.clamp(worldX, bounds.minX, bounds.maxX)
	local safeZ = math.clamp(worldZ, bounds.minZ, bounds.maxZ)
	local rayHeight = bounds.maxY + 50
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { mapLayout }
	params.IgnoreWater = false
	local result =
		Workspace:Raycast(Vector3.new(safeX, rayHeight, safeZ), Vector3.new(0, bounds.minY - rayHeight - 50, 0), params)
	local surfaceY = if result ~= nil then result.Position.Y else launchFallbackSurfaceY
	return Vector3.new(safeX, surfaceY + squishyHalfSize, safeZ)
end

-- Keeps the public attributes and the replicated in-world bar in lockstep.
-- The attributes make health available to future effects without requiring
-- them to understand this Gui hierarchy; the Gui itself stays disabled at
-- full health so healthy pads remain visually quiet.
local function updateHealthVisual(part: BasePart, tier: number, health: number)
	local maxHealth = MergeConfig.healthForTier(tier)
	local safeHealth = sanitizeHealth(health, tier)
	part:SetAttribute("Health", safeHealth)
	part:SetAttribute("MaxHealth", maxHealth)

	local statusBillboard = part:FindFirstChild("IncomeLabel")
	local healthBar = if statusBillboard ~= nil then statusBillboard:FindFirstChild("HealthBar", true) else nil
	if healthBar == nil or not healthBar:IsA("GuiObject") then
		return
	end
	healthBar.Visible = safeHealth < maxHealth

	local fill = healthBar:FindFirstChild("Fill", true)
	if fill ~= nil and fill:IsA("Frame") then
		fill.Size = UDim2.fromScale(safeHealth / maxHealth, 1)
	end

	local healthText = healthBar:FindFirstChild("HealthText", true)
	if healthText ~= nil and healthText:IsA("TextLabel") then
		local percentage = math.round((safeHealth / maxHealth) * 100)
		healthText.Text = `♥ {percentage}%`
	end
end

local function createHealthBar(part: BasePart, statusBillboard: BillboardGui, tier: number, health: number)
	local healthBar = Instance.new("Frame")
	healthBar.Name = "HealthBar"
	healthBar.Size = UDim2.fromScale(1, 22 / 52)
	healthBar.BackgroundTransparency = 1
	healthBar.Visible = false
	healthBar.Parent = statusBillboard

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Position = UDim2.fromOffset(0, 3)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = Color3.fromRGB(117, 55, 83)
	shadow.BackgroundTransparency = 0.45
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	shadow.Parent = healthBar

	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(1, 0)
	shadowCorner.Parent = shadow

	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.Size = UDim2.fromScale(1, 1)
	bubble.BackgroundColor3 = Color3.fromRGB(255, 244, 249)
	bubble.BorderSizePixel = 0
	bubble.ZIndex = 2
	bubble.Parent = healthBar

	local bubbleCorner = Instance.new("UICorner")
	bubbleCorner.CornerRadius = UDim.new(1, 0)
	bubbleCorner.Parent = bubble

	local bubbleStroke = Instance.new("UIStroke")
	bubbleStroke.Color = Color3.fromRGB(255, 139, 180)
	bubbleStroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- 2px on the billboard's 116x52 design grid; the bubble's shortest axis there is 22px.
	bubbleStroke.Thickness = 2 / 22
	bubbleStroke.Parent = bubble

	local track = Instance.new("Frame")
	track.Name = "Track"
	-- Keep a slim cream inset so the red HP fill reads more prominently while
	-- retaining the soft inner outline that makes the bar feel bubbly.
	track.Position = UDim2.fromOffset(2, 2)
	track.Size = UDim2.new(1, -4, 1, -4)
	track.BackgroundColor3 = Color3.fromRGB(255, 214, 228)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 3
	track.Parent = bubble

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(255, 106, 154)
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local fillGradient = Instance.new("UIGradient")
	fillGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 126, 170)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 86, 126)),
	})
	fillGradient.Parent = fill

	-- A tiny glossy bubble gives the pill-shaped bar a toy-like finish without
	-- adding an image asset that would need separate loading/failure handling.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Position = UDim2.fromOffset(8, 2)
	shine.Size = UDim2.fromOffset(6, 4)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.35
	shine.BorderSizePixel = 0
	shine.ZIndex = 4
	shine.Parent = fill

	local shineCorner = Instance.new("UICorner")
	shineCorner.CornerRadius = UDim.new(1, 0)
	shineCorner.Parent = shine

	local healthText = Instance.new("TextLabel")
	healthText.Name = "HealthText"
	healthText.Size = UDim2.fromScale(1, 1)
	healthText.BackgroundTransparency = 1
	healthText.Font = Enum.Font.FredokaOne
	healthText.TextColor3 = Color3.fromRGB(255, 255, 255)
	healthText.TextStrokeColor3 = Color3.fromRGB(126, 48, 76)
	healthText.TextStrokeTransparency = 0.35
	healthText.TextScaled = true
	healthText.ZIndex = 5
	healthText.Parent = bubble

	updateHealthVisual(part, tier, health)
end

local function createLaunchCooldownCounter(part: BasePart, statusBillboard: BillboardGui)
	local statusWidth = statusBillboard.Size.X.Scale
	local statusHeight = statusBillboard.Size.Y.Scale
	local counterHeight = math.max(0.8, statusHeight * 0.52)
	local counterBillboard = Instance.new("BillboardGui")
	counterBillboard.Name = "LaunchCooldownBillboard"
	counterBillboard.Size = UDim2.fromScale(statusWidth * 0.76, counterHeight)
	counterBillboard.StudsOffset =
		Vector3.new(0, statusBillboard.StudsOffset.Y + statusHeight / 2 + counterHeight / 2 + 0.12, 0)
	counterBillboard.AlwaysOnTop = true
	counterBillboard.LightInfluence = 0
	counterBillboard.Enabled = false
	counterBillboard.Parent = part

	local counter = Instance.new("TextLabel")
	counter.Name = "LaunchCooldownText"
	counter.Size = UDim2.fromScale(1, 1)
	counter.BackgroundTransparency = 1
	counter.BorderSizePixel = 0
	counter.Font = Enum.Font.FredokaOne
	counter.Text = ""
	counter.TextColor3 = Color3.fromRGB(255, 244, 249)
	counter.TextScaled = true
	counter.TextStrokeColor3 = Color3.fromRGB(255, 86, 136)
	counter.TextStrokeTransparency = 0
	counter.ZIndex = 2
	counter.Parent = counterBillboard

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = Color3.fromRGB(126, 48, 76)
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- 1.5px at the status billboard's 116x52 design reference. The counter's
	-- shortest axis is its height: counterHeight studs at (116 / statusWidth)
	-- px-per-stud on that grid.
	stroke.Thickness = 1.5 / (counterHeight * (116 / statusWidth))
	stroke.Parent = counter
end

local function setLaunchCooldownCounter(part: BasePart, secondsRemaining: number)
	local counterBillboard = part:FindFirstChild("LaunchCooldownBillboard")
	local counter = if counterBillboard ~= nil then counterBillboard:FindFirstChild("LaunchCooldownText") else nil
	if counter == nil or not counter:IsA("TextLabel") then
		return
	end

	local wholeSeconds = math.max(0, math.ceil(secondsRemaining))
	if counterBillboard:IsA("BillboardGui") then
		counterBillboard.Enabled = wholeSeconds > 0
	end
	counter.Text = if wholeSeconds > 0 then `{wholeSeconds}s` else ""
end

local function startLaunchCooldown(player: Player, part: BasePart)
	local duration = MergeConfig.LAUNCH_COOLDOWN_SECONDS
	if duration <= 0 or part.Parent == nil then
		return
	end

	local readyAt = Workspace:GetServerTimeNow() + duration
	part:SetAttribute("LaunchReadyAt", readyAt)
	setLaunchCooldownCounter(part, duration)

	task.spawn(function()
		local lastWholeSeconds = -1
		while part.Parent ~= nil and part:GetAttribute("LaunchReadyAt") == readyAt do
			local remaining = math.max(0, readyAt - Workspace:GetServerTimeNow())
			local wholeSeconds = math.ceil(remaining)
			if wholeSeconds ~= lastWholeSeconds then
				lastWholeSeconds = wholeSeconds
				setLaunchCooldownCounter(part, remaining)
			end
			if remaining <= 0 then
				break
			end
			task.wait(math.min(0.2, remaining))
		end

		if part.Parent ~= nil and part:GetAttribute("LaunchReadyAt") == readyAt then
			part:SetAttribute("LaunchReadyAt", nil)
			setLaunchCooldownCounter(part, 0)
			local carry = carries[player]
			if carry ~= nil and carry.part == part then
				player:SetAttribute("CarryingLaunchReadyAt", nil)
			end
		end
	end)
end

--[[
	One authoritative MergeObject root Part for `entry`, NOT yet parented.
	Replaceable artwork is cloned under that root by MergeObjectVisuals, keeping
	all gameplay code keyed to one stable BasePart regardless of model shape.
	Factored out so Phase 2 (drag/merge) can call it again when a merge result
	needs a fresh object instead of duplicating this instancing code.

	Position is pad-local by construction: spawnArea.CFrame * CFrame.new(x,
	yOffset, z) is correct regardless of which of the 8 differently-rotated
	bases `spawnArea` belongs to -- the whole reason Squishies is stored in
	pad-local coordinates in the first place (DataService.luau's Merge
	comment).
]]
local function materializeObject(spawnArea: BasePart, entry: MergeObjectEntry): BasePart
	local tierDef = tierDefFor(entry.Tier)

	local part = Instance.new("Part")
	part.Name = "MergeObject"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(tierDef.Size, tierDef.Size, tierDef.Size)
	part.Color = tierDef.Color
	part:SetAttribute("Tier", entry.Tier)

	local yOffset = spawnArea.Size.Y / 2 + tierDef.Size / 2
	part.CFrame = spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)

	if MergeObjectVisuals.attach(part, sanitizeTier(entry.Tier)) then
		part.Transparency = 1
		part.CastShadow = false
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "IncomeLabel"
	-- Scale in world-space studs, not fixed screen pixels. The entire readout
	-- now follows the same camera perspective as its squishy instead of looking
	-- proportionally huge at a distance and tiny up close.
	local statusWidth = math.clamp(tierDef.Size * 1.25, 3, 8)
	local statusHeight = statusWidth * (52 / 116)
	billboard.Size = UDim2.fromScale(statusWidth, statusHeight)
	billboard.StudsOffset = Vector3.new(0, tierDef.Size / 2 + 0.85, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = part

	-- The permanent label is a clean progression value (1, 2, 4, 8...) rather
	-- than currency. incomeForTier remains the single source of truth for that
	-- doubling curve and for the separate floating "+$X" income popups.
	local incomeText = Instance.new("TextLabel")
	incomeText.Name = "IncomeText"
	incomeText.AnchorPoint = Vector2.new(0.5, 1)
	incomeText.Position = UDim2.fromScale(0.5, 1)
	incomeText.Size = UDim2.fromScale(80 / 116, 24 / 52)
	incomeText.BackgroundTransparency = 1
	incomeText.Font = Enum.Font.FredokaOne
	incomeText.TextScaled = true
	incomeText.TextColor3 = Color3.fromRGB(255, 248, 231)
	incomeText.TextStrokeColor3 = Color3.fromRGB(58, 38, 31)
	incomeText.TextStrokeTransparency = 0.15
	incomeText.Text = Format.FormatNumber(MergeConfig.incomeForTier(entry.Tier))
	incomeText.Parent = billboard

	createHealthBar(part, billboard, entry.Tier, entry.Health)
	createLaunchCooldownCounter(part, billboard)

	return part
end

--[[
	Rejection-sampling search for a free spot on `spawnArea`, inset by
	PAD_MARGIN + the new object's own half-size, rejecting any candidate
	closer than (both half-sizes + MIN_GAP) to an already-placed object.
	Returns nil, nil if MAX_PLACEMENT_ATTEMPTS all land on an occupied spot,
	or if `tierDef` is too large to fit the pad at all.
]]
local function findOpenSpot(
	spawnArea: BasePart,
	tierDef: MergeConfig.TierDef,
	existing: { [BasePart]: MergeObjectEntry }
): (number?, number?)
	local halfSize = tierDef.Size / 2
	local rangeX = spawnArea.Size.X / 2 - MergeConfig.PAD_MARGIN - halfSize
	local rangeZ = spawnArea.Size.Z / 2 - MergeConfig.PAD_MARGIN - halfSize
	if rangeX <= 0 or rangeZ <= 0 then
		return nil, nil
	end

	for _ = 1, MergeConfig.MAX_PLACEMENT_ATTEMPTS do
		local x = (random:NextNumber() * 2 - 1) * rangeX
		local z = (random:NextNumber() * 2 - 1) * rangeZ

		local fits = true
		for _, entry in existing do
			local otherHalf = tierDefFor(entry.Tier).Size / 2
			local minDistance = halfSize + otherHalf + MergeConfig.MIN_GAP
			local dx = x - entry.X
			local dz = z - entry.Z
			if dx * dx + dz * dz < minDistance * minDistance then
				fits = false
				break
			end
		end

		if fits then
			return x, z
		end
	end

	return nil, nil
end

-- Same polling wait as PlaytimeRewardsService/FriendRewardService/etc:
-- DataService.getData(player) returns nil until that player's ProfileStore
-- session finishes loading (async, started from DataService.Start()).
local function waitForData(player: Player): DataService.PlayerData?
	if not DataService.awaitData(player, 120) then
		return nil
	end
	return DataService.getData(player)
end

--[[
	Puts `part` back to being a plain resting object at `entry`'s persisted
	pad-local spot -- the exact CFrame math materializeObject uses, so a
	re-anchored object sits identically to one that was never picked up.
	Used by every carry-cancel path (drop, character removing, pad
	deactivation); those paths never destroy and recreate the part, only
	this.
]]
local function reAnchorPart(live: LiveBase, part: BasePart, entry: MergeObjectEntry)
	if part.Parent == nil then
		return -- already destroyed (e.g. the pad's folder was torn down first)
	end

	local tierDef = tierDefFor(entry.Tier)
	local yOffset = live.spawnArea.Size.Y / 2 + tierDef.Size / 2
	-- Split the object from its former carry assembly before restoring the
	-- resting transform. Setting CFrame while it is still unanchored can move
	-- it to the right position but let the physics assembly keep the player's
	-- carried rotation for the rest of that frame.
	part.Anchored = true
	part.CFrame = live.spawnArea.CFrame * CFrame.new(entry.X, yOffset, entry.Z)
	part.Massless = false
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = true
end

--[[
	Marks `part` not-yet-pickup-eligible, with a fresh (zero) continuous-
	outside accumulator. Called by every path that places a resting part
	somewhere the owning player could otherwise instantly re-grab it
	(dropCarried, cancelCarry, commitMerge's result) -- see the
	LiveBase.disarmed field comment and MergeConfig.REARM_OUTSIDE_SECONDS for
	the re-arm rule that eventually clears it.
]]
local function markDisarmed(live: LiveBase, part: BasePart)
	live.disarmed[part] = 0
end

local EXPLOSION_LIFETIME = 1.5
local EXPLOSION_PARTICLE_COUNT = 40
local SQUISHY_POP_LIFETIME = 1
local SQUISHY_POP_PARTICLE_COUNT = 18

--[[
	Placeholder-quality mini explosion at a merge's target (mergee) position --
	ParticleEmitter burst only, no Sound (spec calls it optional and there is
	no existing SFX asset id in this codebase to reuse without guessing one).
	Parented under the pad's own MergeObjects folder per the naming rules
	(model-naming-style.md), so it is destroyed along with everything else if
	the pad deactivates mid-burst instead of leaking into Workspace.
]]
local function spawnMergeVfx(objectsFolder: Folder, position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "MergeVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = objectsFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Burst"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.35, 0.75)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.6)
	emitter.Parent = anchor
	emitter:Emit(EXPLOSION_PARTICLE_COUNT)

	Debris:AddItem(anchor, EXPLOSION_LIFETIME)
end

-- A light, bubbly death burst that survives after the authoritative squishy
-- Part is destroyed. It is purely visual: the invisible anchor cannot touch,
-- query, collide, or apply force, and Debris guarantees cleanup.
local function spawnSquishyPopVfx(objectsFolder: Folder, position: Vector3, color: Color3, squishySize: number)
	local anchor = Instance.new("Part")
	anchor.Name = "SquishyPopVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = objectsFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Bubbles"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.65))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.clamp(squishySize * 0.16, 0.35, 1.1)),
		NumberSequenceKeypoint.new(0.55, math.clamp(squishySize * 0.24, 0.5, 1.6)),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.6)
	emitter.Speed = NumberRange.new(4 + squishySize * 0.35, 7 + squishySize * 0.55)
	emitter.Drag = 4
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-100, 100)
	emitter.LightEmission = 0.65
	emitter.Parent = anchor
	emitter:Emit(SQUISHY_POP_PARTICLE_COUNT)

	Debris:AddItem(anchor, SQUISHY_POP_LIFETIME)
end

local function spawnLaunchImpactVfx(objectsFolder: Folder, position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "LaunchImpactVfx"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = objectsFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "ImpactBurst"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	emitter.Lifetime = NumberRange.new(0.45, 0.8)
	emitter.Speed = NumberRange.new(12, 24)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(0.7, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.LightEmission = 0.75
	emitter.Parent = anchor
	emitter:Emit(EXPLOSION_PARTICLE_COUNT)

	Debris:AddItem(anchor, EXPLOSION_LIFETIME)
end

--[[
	Attaches `part` (a resting object on `live`'s pad) to `player`'s torso,
	floating in front of it, offset by the object's own half-size so bigger
	tiers don't clip into the character.

	WeldConstraint locks the CURRENT relative transform at creation time (it
	has no offset of its own), which is why the CFrame is set FIRST, then the
	weld is created -- reversing the order would weld it wherever it
	physically happened to be instead of the carry pose.

	Network ownership is not set explicitly: an unanchored part rigidly
	welded into a character's assembly automatically follows that
	character's network owner (this is the same mechanism that makes a held
	Tool move smoothly for its holder), which is exactly "network ownership
	follows the character automatically" from the spec.
]]
local function pickUp(player: Player, part: BasePart)
	if carries[player] ~= nil then
		return -- capacity is exactly one; a second Touched this tick is a no-op
	end
	local activeLaunch = activeLaunches[player]
	if activeLaunch ~= nil and activeLaunch.part == part then
		return -- only the projectile itself is unavailable while it is flying
	end

	local live = liveBases[player]
	local entry = if live ~= nil then live.parts[part] else nil
	if live == nil or entry == nil then
		return -- pad went stale between the Touched firing and this running
	end

	local character = player.Character
	local attachPoint = if character ~= nil
		then (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso"))
		else nil
	if attachPoint == nil or not attachPoint:IsA("BasePart") then
		return -- no rig to carry it in front of (character streaming in/out)
	end

	local tierDef = tierDefFor(entry.Tier)
	local offset = tierDef.Size / 2 + MergeConfig.CARRY_GAP
	local carryRotation = MergeObjectVisuals.getCarryRotation(sanitizeTier(entry.Tier))
	part.CFrame = attachPoint.CFrame * CFrame.new(0, 0, -offset) * carryRotation
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = attachPoint
	weld.Part1 = part
	weld.Parent = part

	carries[player] = { live = live, part = part, entry = entry, weld = weld }
	publishCarryingAttributes(player, entry.Tier, part)
end

--[[
	Server-side pickup detection: .Touched on the resting Part itself. See the
	header's PHASE 2 note for why Touched (not a heartbeat scan) is the right
	tool here -- a moving character walking into a stationary, anchored,
	non-collide Part is the textbook reliable case for it.
]]
local function wirePickupTouched(player: Player, live: LiveBase, part: BasePart)
	part.Touched:Connect(function(hit: BasePart)
		if liveBases[player] ~= live then
			return -- pad no longer live for this player; part is on its way out
		end
		if carries[player] ~= nil then
			return -- already carrying -- walking over other objects does nothing
		end
		if live.disarmed[part] ~= nil then
			return -- not yet re-armed -- see LiveBase.disarmed's comment
		end

		-- Ancestry, not .Parent: a hat/tool/accessory part touching this Part
		-- has the character somewhere ABOVE it, not as its direct parent, and
		-- .Parent alone would silently miss the pickup for those cases.
		local character = hit:FindFirstAncestorOfClass("Model")
		if character == nil or not character:IsA("Model") then
			return
		end
		if character:FindFirstChildOfClass("Humanoid") == nil then
			return -- not a character limb (a dropped tool, a projectile, ...)
		end

		-- Own pad only: a touch from anyone but the pad's owner is ignored.
		local touchingPlayer = Players:GetPlayerFromCharacter(character)
		if touchingPlayer ~= player then
			return
		end

		pickUp(player, part)
	end)
end

--[[
	The single choke point every resting MergeObject Part is created through
	-- auto-spawned (trySpawnObject), restored on activation (activateBase),
	or produced by a merge (commitMerge). Centralising it here is what
	guarantees pickup detection is wired onto every one of them without each
	call site remembering to do it itself.
]]
local function spawnRestingPart(player: Player, live: LiveBase, entry: MergeObjectEntry): BasePart
	local part = materializeObject(live.spawnArea, entry)
	part.Parent = live.objectsFolder
	live.parts[part] = entry
	wirePickupTouched(player, live, part)
	return part
end

local function trySpawnObject(player: Player, live: LiveBase)
	local data = DataService.getData(player)
	if data == nil then
		return
	end

	if #data.Merge.Squishies >= MergeConfig.MAX_OBJECTS then
		return -- pad full; auto-spawn just waits
	end

	local tier = sanitizeTier(data.Merge.SpawnLevel)
	local tierDef = MergeConfig.Tiers[tier]

	local x, z = findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x == nil or z == nil then
		-- Crowded-but-under-cap: skip this tick, try again next one.
		return
	end

	-- Rounded to ~2 decimals at write time (spec) so saved coordinates don't
	-- accumulate float noise across sessions.
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100

	local entry: MergeObjectEntry = {
		Tier = tier,
		X = roundedX,
		Z = roundedZ,
		Health = MergeConfig.healthForTier(tier),
	}

	-- Append incrementally: auto-spawn runs every few seconds, so replacing the
	-- entire growing array here would turn one small entry into O(n) replicated
	-- payload over the life of every pad.
	if DataService.tableInsert(player, { "Merge", "Squishies" }, entry) == nil then
		return
	end

	spawnRestingPart(player, live, entry)
end

local function runAutoSpawnLoop(player: Player, live: LiveBase)
	-- `liveBases[player] == live` (identity, not just non-nil) is what makes
	-- this loop exit both on the player leaving/releasing the base AND on a
	-- later re-activation replacing this LiveBase with a new one -- either
	-- way, this exact loop's job is done.
	while player.Parent == Players and liveBases[player] == live do
		task.wait(MergeConfig.SPAWN_INTERVAL)
		if liveBases[player] ~= live then
			break
		end
		trySpawnObject(player, live)
	end
end

--[[
	Ends a carry without a merge or a deliberate drop: character removing
	(death/respawn/leaving) or the pad going away underneath the player. The
	entry's X/Z never changed while carried (see the header's PHASE 2 note),
	so this needs no DataService write -- putting the SAME part back where it
	already persists is enough.

	Safe to call when nothing is being carried (every caller does, rather
	than checking first) and safe to call right before the pad's whole
	objectsFolder gets destroyed a moment later -- reAnchorPart's own
	Parent-nil guard covers that.
]]
local function cancelCarry(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	carries[player] = nil
	clearCarryingAttributes(player)

	carry.weld:Destroy()
	reAnchorPart(carry.live, carry.part, carry.entry)
	-- The respawned player can land right on top of this spot (base center)
	-- -- see MergeConfig.REARM_CLEARANCE's comment.
	markDisarmed(carry.live, carry.part)
end

local function cancelLaunch(player: Player)
	local launch = activeLaunches[player]
	if launch == nil then
		return
	end
	activeLaunches[player] = nil
	destroyLaunchTrail(launch)

	if liveBases[player] == launch.live and launch.part.Parent ~= nil then
		reAnchorPart(launch.live, launch.part, launch.entry)
		markDisarmed(launch.live, launch.part)
	end
end

local function deactivateBase(player: Player)
	-- Bumped unconditionally, even if no pad is live yet, so an
	-- activateBase() still waiting on waitForData/materializing for this
	-- player sees its token invalidated the instant release happens.
	activationTokens[player] = (activationTokens[player] or 0) + 1

	-- Before the objectsFolder (and therefore the carried Part) disappears --
	-- see cancelCarry's own header note on why this is safe either way.
	cancelCarry(player)
	cancelLaunch(player)

	local live = liveBases[player]
	if live == nil then
		return
	end
	liveBases[player] = nil
	-- Destroys every MergeObject Part and its BillboardGui child in one call.
	live.objectsFolder:Destroy()
end

local function activateBase(player: Player, baseName: string)
	local existing = liveBases[player]
	if existing ~= nil then
		if existing.baseName == baseName then
			return -- already live on this exact base -- nothing to do
		end
		-- Not expected given BaseService's claim/release contract (a base
		-- change always clears the attribute first), but never assume a
		-- second system's invariant from here -- release the stale pad first.
		deactivateBase(player)
	end

	local record = bases[baseName]
	if record == nil then
		log.warn(`{player.Name} was assigned {baseName}, which has no usable SpawnArea -- merge pad will not go live`)
		return
	end

	local token = (activationTokens[player] or 0) + 1
	activationTokens[player] = token

	task.spawn(function()
		local data = waitForData(player)
		if data == nil or activationTokens[player] ~= token then
			-- Player left before data loaded, or superseded while waiting --
			-- see the header's ACTIVATION IS ASYNC note.
			return
		end

		local folder = Instance.new("Folder")
		folder.Name = "MergeObjects"
		folder.Parent = record.part

		local live: LiveBase = {
			baseName = baseName,
			spawnArea = record.spawnArea,
			objectsFolder = folder,
			parts = {},
			disarmed = {},
		}
		-- Set BEFORE the restore loop below: spawnRestingPart's Touched wiring
		-- closes over `live` and checks `liveBases[player] == live` on every
		-- fire, so it must already be published before any part exists to be
		-- touched.
		liveBases[player] = live

		-- Capped at MAX_OBJECTS even though a compliant writer never exceeds
		-- it: profile data is attacker-influenced over a long enough time
		-- horizon (dev console, a future migration bug), and a planted
		-- oversized array must not materialize hundreds of Parts.
		local restoreCount = math.min(#data.Merge.Squishies, MergeConfig.MAX_OBJECTS)
		for i = 1, restoreCount do
			spawnRestingPart(player, live, data.Merge.Squishies[i])
		end

		runAutoSpawnLoop(player, live)
	end)
end

--[[
	Commits a ram-to-merge: `carry` (tier t, still attached to the player)
	touched `targetPart`/`targetEntry` (also tier t, resting on the same
	pad). Rebuilds Squishies removing BOTH entries and appending one {t+1,
	targetEntry.X, targetEntry.Z} in a single DataService.set -- no yields
	between the read and the write (quality-gate.md trap #5), so this cannot
	race a second commit for the same player (there is only ever one
	Heartbeat loop, and carries[player] is cleared before this returns).
]]
local function commitMerge(player: Player, carry: CarryState, targetPart: BasePart, targetEntry: MergeObjectEntry)
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but a merge must not vanish the carried
		-- object into thin air if it somehow happens -- leave everything as
		-- it is and let the next Heartbeat tick try again.
		return
	end

	local newEntry: MergeObjectEntry = {
		Tier = carry.entry.Tier + 1,
		X = targetEntry.X,
		Z = targetEntry.Z,
		Health = MergeConfig.healthForTier(carry.entry.Tier + 1),
	}

	local updated = table.create(#data.Merge.Squishies)
	for _, existingEntry in data.Merge.Squishies do
		if existingEntry ~= carry.entry and existingEntry ~= targetEntry then
			table.insert(updated, existingEntry)
		end
	end
	table.insert(updated, newEntry)
	DataService.set(player, { "Merge", "Squishies" }, updated)

	-- Captured before Destroy: the VFX plays at the mergee's position, and
	-- reading .Position after Destroy is not something to rely on.
	local vfxPosition = targetPart.Position
	local serverNow = Workspace:GetServerTimeNow()
	local carryReadyAt = carry.part:GetAttribute("LaunchReadyAt")
	local targetReadyAt = targetPart:GetAttribute("LaunchReadyAt")
	local restartLaunchCooldown = (typeof(carryReadyAt) == "number" and carryReadyAt > serverNow)
		or (typeof(targetReadyAt) == "number" and targetReadyAt > serverNow)

	carries[player] = nil
	clearCarryingAttributes(player)
	carry.weld:Destroy()

	live.parts[carry.part] = nil
	live.parts[targetPart] = nil
	-- Cleared rather than left to dangle: carry.part is never disarmed while
	-- actively carried, but targetPart (a resting object) could have been
	-- rammed while still disarmed itself -- merges don't check armed state,
	-- only pickup does. Either way, both are about to be destroyed, and a
	-- stale key pointing at a destroyed Part is exactly the leak the
	-- LiveBase.disarmed comment promises not to have.
	live.disarmed[carry.part] = nil
	live.disarmed[targetPart] = nil
	carry.part:Destroy()
	targetPart:Destroy()

	spawnMergeVfx(live.objectsFolder, vfxPosition)
	-- The result appears wherever the target sat -- which the carrying
	-- player was, by definition, standing right next to. Same instant-
	-- re-grab problem as a drop, same fix.
	local newPart = spawnRestingPart(player, live, newEntry)
	markDisarmed(live, newPart)
	if restartLaunchCooldown then
		startLaunchCooldown(player, newPart)
	end
end

--[[
	One carrying player's merge check for this Heartbeat tick. See the
	header's PHASE 2 note for why this is distance polling and not Touched.
]]
local function tryMergeCarry(player: Player, carry: CarryState)
	local entry = carry.entry
	if entry.Tier >= MergeConfig.MAX_TIER then
		return -- tier+1 wouldn't exist -- two max-tier objects never merge (spec)
	end

	local halfSize = tierDefFor(entry.Tier).Size / 2
	local threshold = halfSize + halfSize + MergeConfig.MERGE_EPSILON -- same tier -> same size
	local carryPosition = carry.part.Position

	-- Horizontal-only, matching findOpenSpot/computeDropSpot's 2D model of
	-- the pad: the carried part floats at torso height, well above a resting
	-- object's center, so 3D distance would let that vertical gap eat most
	-- of the threshold -- worst for small tiers, whose whole size is close
	-- to the gap itself.
	local target: BasePart? = nil
	local targetEntry: MergeObjectEntry? = nil
	local activeLaunch = activeLaunches[player]
	for otherPart, otherEntry in carry.live.parts do
		if
			otherPart == carry.part
			or (activeLaunch ~= nil and otherPart == activeLaunch.part)
			or otherEntry.Tier ~= entry.Tier
		then
			continue
		end

		local dx = carryPosition.X - otherPart.Position.X
		local dz = carryPosition.Z - otherPart.Position.Z
		if dx * dx + dz * dz <= threshold * threshold then
			target = otherPart
			targetEntry = otherEntry
			break
		end
	end

	-- Committed AFTER the loop closes, not inside it: commitMerge's
	-- spawnRestingPart inserts a NEW key into this same live.parts table
	-- (the merge result), and mutating a table while a `for...in` is still
	-- traversing it is undefined behaviour in Luau.
	if target ~= nil and targetEntry ~= nil then
		commitMerge(player, carry, target, targetEntry)
	end
end

local function checkAllCarriesForMerge()
	for player, carry in carries do
		tryMergeCarry(player, carry)
	end
end

--[[
	Phase 3: passive income. One grant per player per INCOME_INTERVAL, summed
	over every entry in THEIR data.Merge.Squishies (not live.parts) -- data is
	the source of truth, and reading it directly is what makes this include a
	currently-carried object for free: carry.entry is the SAME table as its
	entry in data.Merge.Squishies the entire time it's carried (the header's
	PHASE 2 note), so there is nothing special to do here for that case.

	liveBases (not Players:GetPlayers()) is the population: a player with no
	live pad -- not yet activated, data still loading, base released -- earns
	nothing and errors nothing, because they were never iterated.

	One CoinsService.add() call per player, not one per object: that is the
	entire reason this is a sum-then-grant instead of a loop of individual
	grants, per the perf budget (8 players * 25 objects must not mean 200
	writes a second).

	The sum is capped at MAX_OBJECTS entries, same rationale as activateBase's
	restore loop (restoreCount, above): profile data is attacker-influenced
	over a long enough time horizon (dev console, a future migration bug),
	and a planted oversized array must not earn income for entries beyond
	what could ever legitimately exist on one pad.
]]
local function runIncomeTick()
	for player in liveBases do
		local data = DataService.getData(player)
		if data == nil then
			continue -- not expected once a pad is live, but never error over it
		end

		local total = SquishyProgress.incomePerPulse(data.Merge.Squishies)

		if total > 0 and CoinsService.add(player, total) then
			Net.mergeIncomePulse.sendTo(nil, player)
		end
	end
end

-- Periodically moves the trusted activity timestamp forward for every loaded
-- player. Clean leaves write an exact timestamp in DataService; this cheaper
-- checkpoint bounds duplicate earnings if a session ends uncleanly.
local function checkpointLastActive()
	local now = os.time()
	for _, player in Players:GetPlayers() do
		if DataService.getData(player) ~= nil then
			DataService.set(player, { "Merge", "LastActiveAt" }, now)
		end
	end
end

--[[
	Re-arms disarmed parts once the OWNING player's character has stood
	CONTINUOUSLY outside REARM_CLEARANCE (horizontal, same 2D model as
	everywhere else in this module) for REARM_OUTSIDE_SECONDS. See
	LiveBase.disarmed and MergeConfig.REARM_OUTSIDE_SECONDS's comment for why
	an instant-outside check is not enough: a merge result's own ramming
	momentum satisfies "instantly outside" on the very next Heartbeat,
	before the player has actually moved away, and carries them straight
	back over it.

	`dt` is threaded through from the shared Heartbeat connection in Start()
	rather than read from RunService here, keeping this a pure function of
	its arguments like the rest of this module's Heartbeat-driven code.

	`liveBases` is bounded by the server's discovered base count, so iterating all of it every
	Heartbeat is cheap on its own; the `next(live.disarmed) == nil` check
	skips the character lookup and inner scan entirely for the (usual) case
	of a pad with nothing disarmed on it right now.
]]
local function reArmSweep(dt: number)
	for player, live in liveBases do
		if next(live.disarmed) == nil then
			continue
		end

		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil

		if root == nil or not root:IsA("BasePart") then
			-- No character to measure from (dead/respawning): every
			-- accumulator resets and every part stays disarmed -- the spawn
			-- point can land the respawned player right back on top of one.
			-- Only VALUES change here, no keys added or removed, so mutating
			-- mid-traversal is fine (unlike the insert/remove below).
			for part, _ in live.disarmed do
				live.disarmed[part] = 0
			end
			continue
		end
		local rootPosition = root.Position

		-- Removals collected then applied after the loop, not inside it --
		-- the same "don't mutate a table's KEYS while traversing it" rule
		-- tryMergeCarry's own restructure above exists for. Updating an
		-- EXISTING key's value mid-traversal (the accumulator) is fine and
		-- done directly below.
		local toRearm: { BasePart } = {}
		for part, outsideSeconds in live.disarmed do
			if part.Parent == nil then
				table.insert(toRearm, part) -- destroyed elsewhere; stop tracking it
				continue
			end

			local entry = live.parts[part]
			local halfSize = if entry ~= nil then tierDefFor(entry.Tier).Size / 2 else 0
			local clearance = halfSize + MergeConfig.REARM_CLEARANCE

			local dx = rootPosition.X - part.Position.X
			local dz = rootPosition.Z - part.Position.Z
			if dx * dx + dz * dz > clearance * clearance then
				local accumulated = outsideSeconds + dt
				if accumulated >= MergeConfig.REARM_OUTSIDE_SECONDS then
					table.insert(toRearm, part)
				else
					live.disarmed[part] = accumulated
				end
			else
				live.disarmed[part] = 0 -- back inside -- momentum overrun, reset the window
			end
		end

		for _, part in toRearm do
			live.disarmed[part] = nil
		end
	end
end

--[[
	Where a dropped object should land: the character's CURRENT world
	position projected into the pad's local space (never a client-sent
	coordinate -- see Net.luau's mergeDropRequest comment), clamped to the
	same PAD_MARGIN inset auto-spawn uses. Falls back to the object's own
	prior spot if there is no character to read a position from, or if the
	pad is too crowded for findOpenSpot to find anything at all.
]]
local function computeDropSpot(live: LiveBase, carry: CarryState, character: Model?): (number, number)
	local tierDef = tierDefFor(carry.entry.Tier)
	local halfSize = tierDef.Size / 2
	local rangeX = live.spawnArea.Size.X / 2 - MergeConfig.PAD_MARGIN - halfSize
	local rangeZ = live.spawnArea.Size.Z / 2 - MergeConfig.PAD_MARGIN - halfSize

	local wantX, wantZ = carry.entry.X, carry.entry.Z
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") and rangeX > 0 and rangeZ > 0 then
		local localPosition = live.spawnArea.CFrame:PointToObjectSpace(root.Position)
		wantX = math.clamp(localPosition.X, -rangeX, rangeX)
		wantZ = math.clamp(localPosition.Z, -rangeZ, rangeZ)
	end

	local fits = true
	for _, otherEntry in live.parts do
		if otherEntry == carry.entry then
			continue
		end
		local otherHalf = tierDefFor(otherEntry.Tier).Size / 2
		local minDistance = halfSize + otherHalf + MergeConfig.MIN_GAP
		local dx = wantX - otherEntry.X
		local dz = wantZ - otherEntry.Z
		if dx * dx + dz * dz < minDistance * minDistance then
			fits = false
			break
		end
	end
	if fits then
		return wantX, wantZ
	end

	local x, z = findOpenSpot(live.spawnArea, tierDef, live.parts)
	if x ~= nil and z ~= nil then
		return x, z
	end

	-- Pad fully crowded -- put it back where it started rather than losing it.
	return carry.entry.X, carry.entry.Z
end

--[[
	Handles Net.mergeDropRequest. A no-op if the sender isn't carrying
	anything, which covers a stale/duplicate/malicious send with zero work
	beyond the table lookup.
]]
local function dropCarried(player: Player)
	local carry = carries[player]
	if carry == nil then
		return
	end
	local live = carry.live

	local data = DataService.getData(player)
	if data == nil then
		-- Not expected mid-session, but never strand the object mid-air --
		-- put it back exactly where it already persists and stop.
		cancelCarry(player)
		return
	end

	local x, z = computeDropSpot(live, carry, player.Character)
	local roundedX = math.round(x * 100) / 100
	local roundedZ = math.round(z * 100) / 100
	local newEntry: MergeObjectEntry = {
		Tier = carry.entry.Tier,
		X = roundedX,
		Z = roundedZ,
		Health = carry.entry.Health,
	}

	-- Splice the fresh entry in place of the old one rather than mutating
	-- carry.entry's fields directly -- ARCHITECTURE.md's "never touch
	-- profile.Data directly" rule applies even though carry.entry IS a
	-- profile.Data table (see the header's IDENTITY note); only a
	-- DataService.set call may change what a client sees.
	local entryIndex = table.find(data.Merge.Squishies, carry.entry)
	if entryIndex == nil then
		log.warn(`carried squishy disappeared from {player.Name}'s profile -- drop cancelled`)
		cancelCarry(player)
		return
	end
	DataService.set(player, { "Merge", "Squishies", entryIndex }, newEntry)

	carries[player] = nil
	clearCarryingAttributes(player)
	carry.weld:Destroy()

	live.parts[carry.part] = newEntry
	reAnchorPart(live, carry.part, newEntry)
	-- Dropped at (or near) the player's own feet -- see
	-- MergeConfig.REARM_CLEARANCE's comment.
	markDisarmed(live, carry.part)
end

local function animateLaunchArc(player: Player, launch: LaunchState, targetPosition: Vector3): boolean
	local part = launch.part
	local startPosition = part.Position
	local horizontalDelta = Vector3.new(targetPosition.X - startPosition.X, 0, targetPosition.Z - startPosition.Z)
	local distance = horizontalDelta.Magnitude
	local duration = math.clamp(
		distance / MergeConfig.LAUNCH_STUDS_PER_SECOND,
		MergeConfig.LAUNCH_MIN_FLIGHT_SECONDS,
		MergeConfig.LAUNCH_MAX_FLIGHT_SECONDS
	)
	local arcHeight = math.clamp(
		distance * MergeConfig.LAUNCH_ARC_DISTANCE_SCALE,
		MergeConfig.LAUNCH_MIN_ARC_HEIGHT,
		MergeConfig.LAUNCH_MAX_ARC_HEIGHT
	)
	local startingRotation = part.CFrame.Rotation
	local elapsed = 0

	while elapsed < duration do
		if activeLaunches[player] ~= launch or part.Parent == nil then
			return false
		end

		elapsed += RunService.Heartbeat:Wait()
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local position = startPosition:Lerp(targetPosition, alpha)
		position += Vector3.new(0, 4 * arcHeight * alpha * (1 - alpha), 0)
		local spin = CFrame.Angles(alpha * math.pi * 4, alpha * math.pi * 2, alpha * math.pi * 3)
		part.CFrame = CFrame.new(position) * spin * startingRotation
	end

	part.CFrame = CFrame.new(targetPosition) * startingRotation
	return true
end

local function finishLaunch(player: Player, launch: LaunchState, startCooldown: boolean)
	if activeLaunches[player] ~= launch then
		return
	end
	activeLaunches[player] = nil
	destroyLaunchTrail(launch)

	if liveBases[player] == launch.live and launch.part.Parent ~= nil then
		reAnchorPart(launch.live, launch.part, launch.entry)
		markDisarmed(launch.live, launch.part)
		if startCooldown then
			startLaunchCooldown(player, launch.part)
		end
	end
end

local function runLaunch(player: Player, launch: LaunchState, targetPosition: Vector3)
	if not animateLaunchArc(player, launch, targetPosition) then
		return
	end

	local tier = sanitizeTier(launch.entry.Tier)
	local attackerLevel = MergeConfig.healthForTier(tier)
	local damage = attackerLevel * MergeConfig.LAUNCH_DAMAGE_FRACTION
	spawnLaunchImpactVfx(launch.live.objectsFolder, targetPosition, tierDefFor(tier).Color)

	-- A launch is allowed to land anywhere, including empty and unclaimed map
	-- space. Every other player's live squishies are checked spatially; an empty
	-- landing simply produces the impact visual and damages nothing.
	for targetPlayer in liveBases do
		if targetPlayer ~= player then
			MergeService.damageSquishiesNear(targetPlayer, targetPosition, MergeConfig.LAUNCH_IMPACT_RADIUS, damage)
		end
	end

	task.wait(MergeConfig.LAUNCH_IMPACT_PAUSE)
	finishLaunch(player, launch, true)
end

-- Validates one overview selection and starts a server-owned flight. The
-- client chooses only a bounded map X/Z point; it cannot choose the source
-- object, damage, radius, surface height, arc, or duration.
local function launchCarried(player: Player, worldX: number, worldZ: number): (boolean, string)
	local carry = carries[player]
	if carry == nil then
		return false, "Pick up a Squishy first"
	end
	if activeLaunches[player] ~= nil then
		return false, "A Squishy is already in flight"
	end
	local cooldownAttribute = carry.part:GetAttribute("LaunchReadyAt")
	if typeof(cooldownAttribute) == "number" then
		local remaining = cooldownAttribute - Workspace:GetServerTimeNow()
		if remaining > 0 then
			return false, `This Squishy can launch again in {math.ceil(remaining)}s`
		end
		carry.part:SetAttribute("LaunchReadyAt", nil)
		player:SetAttribute("CarryingLaunchReadyAt", nil)
	end
	local halfSize = tierDefFor(carry.entry.Tier).Size / 2
	local targetPosition = resolveLaunchTarget(worldX, worldZ, halfSize)
	if targetPosition == nil then
		return false, "Choose a point inside the map"
	end

	local launch: LaunchState = {
		live = carry.live,
		part = carry.part,
		entry = carry.entry,
		trailAttachment0 = nil,
		trailAttachment1 = nil,
	}
	activeLaunches[player] = launch
	carries[player] = nil
	clearCarryingAttributes(player)
	carry.weld:Destroy()
	carry.part.Anchored = true
	carry.part.Massless = false
	carry.part.CanCollide = false
	carry.part.CanTouch = false
	carry.part.CanQuery = false
	attachDefaultLaunchTrail(launch)

	task.spawn(function()
		local ok, err = xpcall(function()
			runLaunch(player, launch, targetPosition)
		end, debug.traceback)
		if not ok then
			log.error(`launch for {player.Name} failed: {err}`)
			finishLaunch(player, launch, false)
		end
	end)

	return true, "Launch accepted"
end

local function clearMushBoost(player: Player)
	local state = mushBoosts[player]
	if state == nil then
		return
	end

	mushBoosts[player] = nil
	player:SetAttribute("MushBoostActive", nil)
	player:SetAttribute("MushBoostEndsAt", nil)
	if state.humanoid.Parent ~= nil then
		state.humanoid.WalkSpeed = state.originalWalkSpeed
	end
end

local function activateMush(player: Player)
	local carry = carries[player]
	if carry == nil or mushBoosts[player] ~= nil then
		return
	end

	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end

	local state: MushBoostState = {
		humanoid = humanoid,
		originalWalkSpeed = humanoid.WalkSpeed,
	}
	mushBoosts[player] = state
	player:SetAttribute("MushBoostEndsAt", Workspace:GetServerTimeNow() + MUSH_BOOST_DURATION)
	player:SetAttribute("MushBoostActive", true)
	humanoid.WalkSpeed = state.originalWalkSpeed + MUSH_BOOST_AMOUNT

	local tier = sanitizeTier(carry.entry.Tier)
	local soundId, soundVolume = MergeObjectVisuals.getMushSound(tier)
	local direction = MergeObjectVisuals.getMushDirection(tier)
	Net.mergeMushActivated.sendTo(
		{ tier = tier, soundId = soundId, soundVolume = soundVolume, direction = direction },
		player
	)

	task.delay(MUSH_BOOST_DURATION, function()
		if mushBoosts[player] == state then
			clearMushBoost(player)
		end
	end)
end

local function onAssignedBaseChanged(player: Player)
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) == "string" then
		activateBase(player, baseName)
	else
		deactivateBase(player)
	end
end

local function onPlayerAdded(player: Player)
	if attributeConnections[player] ~= nil then
		-- Already hooked -- nothing to do. Same guard BaseService.onPlayerAdded
		-- uses for the analogous case: a second call here would leak the old
		-- connection and double-drive onAssignedBaseChanged for one player.
		return
	end

	local changedSignal = player:GetAttributeChangedSignal("AssignedBase")
	attributeConnections[player] = changedSignal:Connect(function()
		onAssignedBaseChanged(player)
	end)
	-- BaseService may have already assigned a base before this connection
	-- existed -- read the attribute's current value once, right after
	-- connecting, so that case isn't silently missed (see header).
	onAssignedBaseChanged(player)

	-- Phase 2: cancel a carry on death/respawn/leaving. CharacterRemoving
	-- fires for the player's whole session regardless of how many characters
	-- they go through, so one connection per player (not per character) is
	-- enough -- same shape as attributeConnections above.
	local removingSignal = player.CharacterRemoving
	characterRemovingConnections[player] = removingSignal:Connect(function()
		cancelCarry(player)
		clearMushBoost(player)
	end)
end

local function onPlayerRemoving(player: Player)
	local connection = attributeConnections[player]
	if connection ~= nil then
		attributeConnections[player] = nil
		connection:Disconnect()
	end

	local characterRemovingConnection = characterRemovingConnections[player]
	if characterRemovingConnection ~= nil then
		characterRemovingConnections[player] = nil
		characterRemovingConnection:Disconnect()
	end

	deactivateBase(player)
	clearMushBoost(player)
	activationTokens[player] = nil
end

--[[
	Read-only copy of `player`'s merge objects, or nil if their data isn't
	loaded. Deep-copies each entry (not just the array) so a caller cannot
	reach back into profile.Data through the returned tables -- returning the
	live entry tables directly would let external code mutate saved data
	without going through DataService.set, silently desyncing the replica.
]]
function MergeService.getSquishies(player: Player): { MergeObjectEntry }?
	local data = DataService.getData(player)
	if data == nil then
		return nil
	end

	local copy: { MergeObjectEntry } = {}
	for _, entry in data.Merge.Squishies do
		table.insert(copy, { Tier = entry.Tier, X = entry.X, Z = entry.Z, Health = entry.Health })
	end
	return copy
end

type DamageForEntry = (MergeObjectEntry) -> number

-- One transactional damage path shared by the developer test and real launch
-- combat. `eligibleEntries == nil` means every squishy; launch combat passes a
-- set built from actual live part positions so the landing point matters.
local function applySquishyDamage(
	player: Player,
	damageForEntry: DamageForEntry,
	eligibleEntries: { [any]: true }?
): (number?, number)
	local data = DataService.getData(player)
	if data == nil then
		return nil, 0
	end

	local updated: { MergeObjectEntry } = table.create(#data.Merge.Squishies)
	local replacements: { [any]: MergeObjectEntry } = {}
	local deadEntries: { [any]: true } = {}
	local damagedCount = 0
	local killedCount = 0

	for _, entry in data.Merge.Squishies do
		if eligibleEntries ~= nil and eligibleEntries[entry] == nil then
			table.insert(updated, entry)
			continue
		end

		local damage = math.max(0, damageForEntry(entry))
		local oldHealth = sanitizeHealth(entry.Health, entry.Tier)
		local newHealth = math.max(0, oldHealth - damage)

		if oldHealth <= 0 or newHealth <= 0 then
			deadEntries[entry] = true
			killedCount += 1
			if oldHealth > 0 then
				damagedCount += 1
			end
			continue
		end

		local newEntry: MergeObjectEntry = {
			Tier = entry.Tier,
			X = entry.X,
			Z = entry.Z,
			Health = newHealth,
		}
		table.insert(updated, newEntry)
		replacements[entry] = newEntry
		if newHealth ~= oldHealth then
			damagedCount += 1
		end
	end

	if damagedCount == 0 and killedCount == 0 then
		return 0, 0
	end

	-- One transaction removes every dead entry and updates every survivor,
	-- keeping Replica's numeric array compact at every point clients can see.
	DataService.set(player, { "Merge", "Squishies" }, updated)

	local carry = carries[player]
	if carry ~= nil then
		local replacement = replacements[carry.entry]
		if replacement ~= nil then
			carry.entry = replacement
		elseif deadEntries[carry.entry] then
			carries[player] = nil
			clearCarryingAttributes(player)
			carry.weld:Destroy()
		end
	end

	local launch = activeLaunches[player]
	if launch ~= nil then
		local replacement = replacements[launch.entry]
		if replacement ~= nil then
			launch.entry = replacement
		elseif deadEntries[launch.entry] then
			-- The live-part cleanup below destroys the projectile. Clear the
			-- state now so its animation exits without permanently blocking pickup.
			activeLaunches[player] = nil
			destroyLaunchTrail(launch)
		end
	end

	local live = liveBases[player]
	if live ~= nil then
		local deadParts: { BasePart } = {}
		for part, oldEntry in live.parts do
			local replacement = replacements[oldEntry]
			if replacement ~= nil then
				live.parts[part] = replacement
				updateHealthVisual(part, replacement.Tier, replacement.Health)
			elseif deadEntries[oldEntry] then
				table.insert(deadParts, part)
			end
		end

		-- Remove table keys after traversal; mutating keys during a `for...in`
		-- walk is undefined in Luau. Each VFX anchor outlives its destroyed Part.
		for _, part in deadParts do
			local deadEntry = live.parts[part]
			live.parts[part] = nil
			live.disarmed[part] = nil

			if part.Parent ~= nil and deadEntry ~= nil then
				local tierDef = tierDefFor(deadEntry.Tier)
				spawnSquishyPopVfx(live.objectsFolder, part.Position, tierDef.Color, tierDef.Size)
				part:Destroy()
			end
		end
	end

	return damagedCount, killedCount
end

-- Server-side all-squishy damage entry point used by the authenticated
-- developer console. The real launch path below uses flat attacker-owned
-- damage rather than a fraction of each victim's own max health.
function MergeService.damageSquishies(player: Player, maxHealthFraction: number): (number?, number)
	if not isFiniteNumber(maxHealthFraction) or maxHealthFraction <= 0 then
		return 0, 0
	end

	local damageFraction = math.min(maxHealthFraction, 1)
	return applySquishyDamage(player, function(entry: MergeObjectEntry): number
		return MergeConfig.healthForTier(entry.Tier) * damageFraction
	end, nil)
end

-- Applies one flat damage amount to every live squishy whose horizontal
-- center falls inside the selected landing radius. The launch service chooses
-- `damageAmount`; no client-supplied damage reaches this function.
function MergeService.damageSquishiesNear(
	player: Player,
	worldPosition: Vector3,
	radius: number,
	damageAmount: number
): (number?, number)
	if
		typeof(worldPosition) ~= "Vector3"
		or not isFiniteNumber(worldPosition.X)
		or not isFiniteNumber(worldPosition.Y)
		or not isFiniteNumber(worldPosition.Z)
		or not isFiniteNumber(radius)
		or radius <= 0
		or not isFiniteNumber(damageAmount)
		or damageAmount <= 0
	then
		return 0, 0
	end

	local live = liveBases[player]
	if live == nil then
		return 0, 0
	end

	local eligibleEntries: { [any]: true } = {}
	local radiusSquared = radius * radius
	for part, entry in live.parts do
		if part.Parent == nil then
			continue
		end
		local dx = part.Position.X - worldPosition.X
		local dz = part.Position.Z - worldPosition.Z
		if dx * dx + dz * dz <= radiusSquared then
			eligibleEntries[entry] = true
		end
	end

	if next(eligibleEntries) == nil then
		return 0, 0
	end

	return applySquishyDamage(player, function(_entry: MergeObjectEntry): number
		return damageAmount
	end, eligibleEntries)
end

--[[
	Registered here, not Start(): NETWORKING-AND-DATA.md's rule for packet
	listeners applies on the server the same as the client -- a listener that
	doesn't exist yet cannot lose a packet that a fast Start() elsewhere
	provokes. Requiring Shared.Net above is also what publishes this
	namespace's packet IDs server-side in the first place (Net.luau's own
	header note).
]]
function MergeService.Init()
	Net.mergeDropRequest.listen(function(_data, player)
		if player ~= nil and mergeInputLimiter:allow(player) then
			dropCarried(player)
		end
	end)

	Net.mergeLaunchRequest.listen(function(data, player)
		if player == nil then
			return
		end
		if not launchInputLimiter:allow(player) then
			Net.mergeLaunchResult.sendTo({ ok = false, message = "Please wait before launching again" }, player)
			return
		end

		local ok, message = launchCarried(player, data.worldX, data.worldZ)
		Net.mergeLaunchResult.sendTo({ ok = ok, message = message }, player)
	end)

	Net.mergeMushRequest.listen(function(_data, player)
		if player ~= nil and mergeInputLimiter:allow(player) then
			activateMush(player)
		end
	end)
end

function MergeService.Start()
	local trailTemplate =
		ReplicatedStorage.Assets.VFX.LaunchTrails:FindFirstChild(MergeConfig.DEFAULT_LAUNCH_TRAIL_MODEL_NAME)
	if
		trailTemplate ~= nil
		and trailTemplate:IsA("Model")
		and trailTemplate:FindFirstChildWhichIsA("Trail", true) ~= nil
	then
		defaultLaunchTrailTemplate = trailTemplate
	else
		log.warn(
			`Workspace.{MergeConfig.DEFAULT_LAUNCH_TRAIL_MODEL_NAME} is missing or malformed -- launches have no cosmetic`
		)
	end

	local mapLayout = Workspace:WaitForChild("MapLayout", WAIT_TIMEOUT)
	if mapLayout == nil then
		log.error("Workspace.MapLayout did not appear within timeout -- MergeService disabled")
		return
	end
	launchMapLayout = mapLayout
	launchMapBounds = calculateLaunchMapBounds(mapLayout)
	if launchMapBounds == nil then
		log.warn("MapLayout has no BaseParts -- launch targeting disabled")
	end
	local centerMap = mapLayout:FindFirstChild("CenterMap")
	if centerMap ~= nil and centerMap:IsA("BasePart") then
		launchFallbackSurfaceY = centerMap.Position.Y + centerMap.Size.Y / 2
	end

	local basesFolder = mapLayout:WaitForChild("Bases", WAIT_TIMEOUT)
	if basesFolder == nil then
		log.error("Workspace.MapLayout.Bases did not appear within timeout -- MergeService disabled")
		return
	end

	local baseCount = 0
	for _, part in basesFolder:GetChildren() do
		if string.match(part.Name, "^Base%d+$") == nil then
			continue
		end
		local baseName = part.Name
		if not part:IsA("BasePart") then
			log.warn(`Bases.{baseName} is not a BasePart -- excluded from merge spawning`)
			continue
		end
		local basePart: BasePart = part

		local spawnAreaInstance = basePart:FindFirstChild("SpawnArea")
		if spawnAreaInstance == nil or not spawnAreaInstance:IsA("BasePart") then
			log.warn(`{baseName}.SpawnArea is missing or not a BasePart -- excluded from merge spawning`)
			continue
		end
		local spawnArea: BasePart = spawnAreaInstance

		bases[baseName] = { part = basePart, spawnArea = spawnArea }
		baseCount += 1
	end

	if baseCount == 0 then
		log.error("no base has a usable SpawnArea -- MergeService disabled")
		return
	end

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	SafePlayerAdded(onPlayerAdded)

	-- Phase 2 merge detection + re-arm sweep, and Phase 3's income tick, all
	-- share this one Heartbeat connection rather than each getting its own
	-- loop: liveBases/carries are already bounded and cheap to sweep every
	-- frame (see reArmSweep's own note), and an accumulator is all a 1-second
	-- cadence needs -- there is no reason for the income tick in particular
	-- to be its own task.spawn loop (let alone one per player) when it is
	-- exactly as bursty-free sitting here.
	RunService.Heartbeat:Connect(function(dt: number)
		checkAllCarriesForMerge()
		reArmSweep(dt)

		incomeAccumulator += dt
		while incomeAccumulator >= MergeConfig.INCOME_INTERVAL do
			incomeAccumulator -= MergeConfig.INCOME_INTERVAL
			runIncomeTick()
		end

		activityCheckpointAccumulator += dt
		if activityCheckpointAccumulator >= MergeConfig.ACTIVITY_CHECKPOINT_INTERVAL then
			activityCheckpointAccumulator %= MergeConfig.ACTIVITY_CHECKPOINT_INTERVAL
			checkpointLastActive()
		end
	end)

	log.info(`ready ({baseCount} bases)`)
end

return MergeService
