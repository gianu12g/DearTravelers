--!strict
--[[
	Server-owned Auto Merge gamepass loop. Each eligible player can have one
	pair in flight: detection, a one-second anticipation pause, a half-second
	tween to the exact midpoint, the same persisted/VFX result as a manual
	merge, then a two-second cooldown before another pair may be selected.

	Nothing is removed from profile data until the tween finishes and the pair
	is revalidated. During the tween the two roots carry an AutoMerging
	attribute so pickup, manual merge targeting, and launch damage cannot race
	the transaction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local DataService = require(script.Parent.Parent.DataService)
local Launch = require(script.Parent.Launch)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local QuestsService = require(script.Parent.Parent.UISystem.QuestsService)
local RebirthConfig = require(ReplicatedStorage.Shared.RebirthConfig)
local Spawning = require(script.Parent.Spawning)
local Types = require(script.Parent.Types)
local Vfx = require(script.Parent.Vfx)

local log = Log.new("AutoMerge")

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
	carries: { [Player]: Types.CarryState },
	activeLaunches: { [Player]: Types.LaunchState },
}

type PairCandidate = {
	part: BasePart,
	entry: Types.MergeObjectEntry,
}

type AutoMergeJob = {
	live: Types.LiveBase,
	partA: BasePart,
	entryA: Types.MergeObjectEntry,
	partB: BasePart,
	entryB: Types.MergeObjectEntry,
	startCFrameA: CFrame,
	startCFrameB: CFrame,
	canTouchA: boolean,
	canTouchB: boolean,
	reserved: boolean,
	committed: boolean,
}

local liveBases: { [Player]: Types.LiveBase } = nil :: any
local carries: { [Player]: Types.CarryState } = nil :: any
local activeLaunches: { [Player]: Types.LaunchState } = nil :: any

local activeJobs: { [Player]: AutoMergeJob } = {}
local cooldownEndsAt: { [Player]: number } = {}
local releaseJob: (Player, AutoMergeJob) -> ()

local AutoMerge = {}

function AutoMerge.setup(deps: Deps)
	liveBases = deps.liveBases
	carries = deps.carries
	activeLaunches = deps.activeLaunches
end

function AutoMerge.clearPlayer(player: Player)
	local job = activeJobs[player]
	if job ~= nil then
		releaseJob(player, job)
	else
		activeJobs[player] = nil
	end
	cooldownEndsAt[player] = nil
end

local function pairIsCurrent(player: Player, job: AutoMergeJob): boolean
	local carry = carries[player]
	if
		player.Parent ~= Players
		or player:GetAttribute("AutoMergeEnabled") ~= true
		or liveBases[player] ~= job.live
		or (carry ~= nil and (carry.part == job.partA or carry.part == job.partB))
		or activeLaunches[player] ~= nil
		or job.partA.Parent ~= job.live.objectsFolder
		or job.partB.Parent ~= job.live.objectsFolder
		or job.live.parts[job.partA] ~= job.entryA
		or job.live.parts[job.partB] ~= job.entryB
		or job.entryA.Tier ~= job.entryB.Tier
	then
		return false
	end

	local data = DataService.getData(player)
	if
		data == nil
		or table.find(data.Merge.Squishies, job.entryA) == nil
		or table.find(data.Merge.Squishies, job.entryB) == nil
	then
		return false
	end

	return job.entryA.Tier < RebirthConfig.maxModelLevel(data.Rebirths)
end

releaseJob = function(player: Player, job: AutoMergeJob)
	if activeJobs[player] == job then
		activeJobs[player] = nil
	end
	if not job.reserved or job.committed then
		return
	end

	if job.partA.Parent ~= nil then
		job.partA:SetAttribute("AutoMerging", nil)
		if job.live.parts[job.partA] ~= nil then
			job.partA.CFrame = job.startCFrameA
			job.partA.CanTouch = job.canTouchA
		end
	end
	if job.partB.Parent ~= nil then
		job.partB:SetAttribute("AutoMerging", nil)
		if job.live.parts[job.partB] ~= nil then
			job.partB.CFrame = job.startCFrameB
			job.partB.CanTouch = job.canTouchB
		end
	end
end

local function commitPair(player: Player, job: AutoMergeJob, midpoint: Vector3): boolean
	if not pairIsCurrent(player, job) then
		return false
	end

	local data = DataService.getData(player)
	if data == nil then
		return false
	end

	local localMidpoint = job.live.spawnArea.CFrame:PointToObjectSpace(midpoint)
	local newTier = job.entryA.Tier + 1
	-- Both pots carry into the result, exactly as a manual merge does (see
	-- Carry.commitMerge's note). Auto-merge absorbing pots silently would mean
	-- the pass that is meant to save the player work also quietly spends their
	-- banked squeeze money.
	local nowSeconds = os.time()
	local mergedPot = MergeConfig.potFor(job.entryA.Pot, job.entryA.PotSince, job.entryA.Tier, nowSeconds)
		+ MergeConfig.potFor(job.entryB.Pot, job.entryB.PotSince, job.entryB.Tier, nowSeconds)

	local newEntry: Types.MergeObjectEntry = {
		Tier = newTier,
		X = math.round(localMidpoint.X * 100) / 100,
		Z = math.round(localMidpoint.Z * 100) / 100,
		Health = MergeConfig.maxHealthForTier(newTier, data.Merge.SquishyHealthMultiplier),
		Pot = math.min(mergedPot, MergeConfig.potCapForTier(newTier)),
		PotSince = nowSeconds,
	}

	local updated = table.create(#data.Merge.Squishies)
	for _, entry in data.Merge.Squishies do
		if entry ~= job.entryA and entry ~= job.entryB then
			table.insert(updated, entry)
		end
	end
	table.insert(updated, newEntry)
	DataService.set(player, { "Merge", "Squishies" }, updated)

	local serverNow = Workspace:GetServerTimeNow()
	local readyAtA = job.partA:GetAttribute("LaunchReadyAt")
	local readyAtB = job.partB:GetAttribute("LaunchReadyAt")
	local restartLaunchCooldown = (typeof(readyAtA) == "number" and readyAtA > serverNow)
		or (typeof(readyAtB) == "number" and readyAtB > serverNow)

	job.live.parts[job.partA] = nil
	job.live.parts[job.partB] = nil
	job.live.disarmed[job.partA] = nil
	job.live.disarmed[job.partB] = nil
	job.partA:Destroy()
	job.partB:Destroy()

	-- Quest metric, same as the manual merge in Carry.commitMerge: an auto-merge
	-- produces the same t+1 squishy, and paying for the Auto Merge pass must not
	-- make quests progress slower.
	QuestsService.award(player, "Merges", 1)

	Vfx.spawnMergeVfx(job.live.objectsFolder, midpoint)
	Vfx.sendMergeSquishyVfx(player, midpoint)
	local newPart = Spawning.spawnRestingPart(player, job.live, newEntry)
	Spawning.markDisarmed(job.live, newPart)
	if restartLaunchCooldown then
		Launch.startCooldown(player, newPart)
	end

	return true
end

local function runJob(player: Player, job: AutoMergeJob)
	local ok, message = pcall(function()
		task.wait(MergeConfig.AUTO_MERGE_DELAY_SECONDS)
		if activeJobs[player] ~= job or not pairIsCurrent(player, job) then
			return
		end

		job.startCFrameA = job.partA.CFrame
		job.startCFrameB = job.partB.CFrame
		job.canTouchA = job.partA.CanTouch
		job.canTouchB = job.partB.CanTouch
		job.reserved = true
		job.partA:SetAttribute("AutoMerging", true)
		job.partB:SetAttribute("AutoMerging", true)
		job.partA.CanTouch = false
		job.partB.CanTouch = false

		local midpoint = (job.partA.Position + job.partB.Position) / 2
		local tweenInfo =
			TweenInfo.new(MergeConfig.AUTO_MERGE_TWEEN_SECONDS, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)
		local tweenA =
			TweenService:Create(job.partA, tweenInfo, { CFrame = CFrame.new(midpoint) * job.partA.CFrame.Rotation })
		local tweenB =
			TweenService:Create(job.partB, tweenInfo, { CFrame = CFrame.new(midpoint) * job.partB.CFrame.Rotation })
		tweenA:Play()
		tweenB:Play()
		task.wait(MergeConfig.AUTO_MERGE_TWEEN_SECONDS)
		if activeJobs[player] ~= job then
			return
		end

		if commitPair(player, job, midpoint) then
			job.committed = true
			cooldownEndsAt[player] = Workspace:GetServerTimeNow() + MergeConfig.AUTO_MERGE_COOLDOWN_SECONDS
		end
	end)

	if not ok then
		log.warn(`auto merge failed for {player.Name}: {tostring(message)}`)
	end
	releaseJob(player, job)
end

local function findPair(player: Player, live: Types.LiveBase): (PairCandidate?, PairCandidate?)
	local data = DataService.getData(player)
	if data == nil then
		return nil, nil
	end

	local maxModelLevel = RebirthConfig.maxModelLevel(data.Rebirths)
	local carry = carries[player]
	local carriedPart = if carry ~= nil then carry.part else nil
	local firstByTier: { [number]: PairCandidate } = {}
	local bestA: PairCandidate? = nil
	local bestB: PairCandidate? = nil
	local bestTier = math.huge

	for part, entry in live.parts do
		if
			part.Parent ~= live.objectsFolder
			or part == carriedPart
			or part:GetAttribute("AutoMerging") == true
			or entry.Tier >= maxModelLevel
		then
			continue
		end

		local first = firstByTier[entry.Tier]
		if first == nil then
			firstByTier[entry.Tier] = { part = part, entry = entry }
		elseif entry.Tier < bestTier then
			bestTier = entry.Tier
			bestA = first
			bestB = { part = part, entry = entry }
		end
	end

	return bestA, bestB
end

function AutoMerge.checkAll()
	local now = Workspace:GetServerTimeNow()
	for player, live in liveBases do
		if
			player:GetAttribute("AutoMergeEnabled") ~= true
			or activeJobs[player] ~= nil
			or (cooldownEndsAt[player] or 0) > now
			or activeLaunches[player] ~= nil
		then
			continue
		end

		local candidateA, candidateB = findPair(player, live)
		if candidateA == nil or candidateB == nil then
			continue
		end

		local job: AutoMergeJob = {
			live = live,
			partA = candidateA.part,
			entryA = candidateA.entry,
			partB = candidateB.part,
			entryB = candidateB.entry,
			startCFrameA = candidateA.part.CFrame,
			startCFrameB = candidateB.part.CFrame,
			canTouchA = candidateA.part.CanTouch,
			canTouchB = candidateB.part.CanTouch,
			reserved = false,
			committed = false,
		}
		activeJobs[player] = job
		task.spawn(runJob, player, job)
	end
end

return AutoMerge
