--!strict
--[[
	Swells resting squishies in proportion to their squeeze pot, so a loaded one
	is readable from across the pad with no UI at all -- and deflates them again
	as Mush drains the pot.

	DERIVED LOCALLY, NEVER REPLICATED. The server publishes only the two raw pot
	fields as Part attributes (Spawning.publishPot), and those change solely when
	the pot is written: mush, merge, drop. This controller turns them into a live
	scale on its own. Replicating the scale itself would be one write per squishy
	per second, which is the exact cost the pot's timestamp design exists to
	avoid -- see Types.MergeObjectEntry's Pot field.

	VISUAL ONLY. Only the Visual children's welds and sizes move; the MergeObject
	root keeps its authored size, because pad packing, drop placement, and merge
	detection all measure the root. MushController's squash follows the same rule
	for the same reason.

	Ownership of those welds is shared with MushController's squash, which
	captures its restore targets when it starts -- so a swell applied mid-squash
	would be reverted the moment the squash finished. The squash marks its model
	with a local-only "Squashing" attribute and this controller skips those.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)

local log = Log.new("SquishyPotController")

local player = Players.LocalPlayer

-- The pot takes MUSH_POT_CAP_PULSES seconds to fill, so there is nothing to
-- gain from recomputing every frame; this is still far smoother than the swell
-- itself moves.
local UPDATE_INTERVAL = 0.15
-- Skip a rewrite when the scale has barely moved. In the steady state (a full
-- pot, or an empty one) this makes the whole pass a handful of comparisons.
local APPLY_EPSILON = 0.004
-- How long before the wall-clock anchor below is refreshed.
local CLOCK_RESYNC = 30

type VisualState = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
}

type RootState = {
	visuals: { VisualState },
	anchor: Vector3,
	applied: number,
}

local SquishyPotController = {}

local roots: { [BasePart]: RootState } = {}
local accumulator = 0
local timeAnchor = 0
local clockAnchor = 0

--[[
	PotSince is an os.time() stamp, but os.time() only ticks once a second --
	reading it directly would make the swell visibly step about sixty times on
	its way up. Anchor it once and advance with os.clock() for a smooth
	sub-second value, re-anchoring periodically so it cannot drift.
]]
local function wallClockNow(): number
	local clock = os.clock()
	if timeAnchor == 0 or clock - clockAnchor > CLOCK_RESYNC then
		timeAnchor = os.time()
		clockAnchor = clock
	end
	return timeAnchor + (clock - clockAnchor)
end

local function findObjectsFolder(): Folder?
	local baseName = player:GetAttribute("AssignedBase")
	if typeof(baseName) ~= "string" then
		return nil
	end

	local mapLayout = Workspace:FindFirstChild("MapLayout")
	local bases = if mapLayout ~= nil then mapLayout:FindFirstChild("Bases") else nil
	local base = if bases ~= nil then bases:FindFirstChild(baseName) else nil
	local folder = if base ~= nil then base:FindFirstChild("MergeObjects") else nil
	return if folder ~= nil and folder:IsA("Folder") then folder :: Folder else nil
end

--[[
	Records each visual piece's authored size and weld offset, which every later
	scale is computed from. Captured on first sight, while the model is still at
	its authored scale -- nothing else ever writes these welds except the squash,
	which restores what it found.

	Returns nil when the artwork has not been welded on yet, so the caller simply
	retries on the next pass rather than caching a half-built model.
]]
local function captureRoot(root: BasePart): RootState?
	local visual = root:FindFirstChild("Visual")
	if visual == nil then
		return nil
	end

	local candidates = if visual:IsA("BasePart") then { visual } else visual:GetDescendants()
	local visuals: { VisualState } = {}
	for _, candidate in candidates do
		if not candidate:IsA("BasePart") then
			continue
		end
		local weld = candidate:FindFirstChild("VisualWeld")
		if weld ~= nil and weld:IsA("Weld") then
			table.insert(visuals, {
				part = candidate,
				weld = weld,
				size = candidate.Size,
				c0 = weld.C0,
			})
		end
	end

	if #visuals == 0 then
		return nil
	end

	return {
		visuals = visuals,
		-- Grow upward from the pad rather than about the centre, so a swollen
		-- squishy never sinks half of itself through the base it sits on.
		anchor = Vector3.new(0, -root.Size.Y / 2, 0),
		applied = 1,
	}
end

local function applyScale(state: RootState, scale: number)
	for _, visual in state.visuals do
		if visual.part.Parent == nil or visual.weld.Parent == nil then
			continue
		end
		visual.part.Size = visual.size * scale
		local position = state.anchor + (visual.c0.Position - state.anchor) * scale
		visual.weld.C0 = CFrame.new(position) * visual.c0.Rotation
	end
	state.applied = scale
end

local function update()
	local folder = findObjectsFolder()
	if folder == nil then
		return
	end

	local now = wallClockNow()
	for _, child in folder:GetChildren() do
		if not child:IsA("BasePart") or child.Name ~= "MergeObject" then
			continue
		end
		-- MushController owns these welds while it is squashing. See the header.
		if child:GetAttribute("Squashing") == true then
			continue
		end

		local tier = child:GetAttribute("Tier")
		if type(tier) ~= "number" then
			continue
		end

		local state = roots[child]
		if state == nil then
			state = captureRoot(child)
			if state == nil then
				continue
			end
			roots[child] = state
		end

		local pot = MergeConfig.potFor(child:GetAttribute("PotBanked"), child:GetAttribute("PotSince"), tier, now)
		local scale = MergeConfig.potScaleFor(pot, tier)
		if math.abs(scale - state.applied) >= APPLY_EPSILON then
			applyScale(state, scale)
		end
	end

	-- Squishies are destroyed on merge, launch, and death, and the pad is torn
	-- down entirely on leave. Drop their captures rather than holding the last
	-- reference to every Part the player has ever owned this session.
	for root in roots do
		if root.Parent == nil then
			roots[root] = nil
		end
	end
end

function SquishyPotController.Init() end

function SquishyPotController.Start()
	RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulator += deltaTime
		if accumulator < UPDATE_INTERVAL then
			return
		end
		accumulator = 0
		update()
	end)

	log.info("ready (pot swell on resting squishies)")
end

return SquishyPotController
