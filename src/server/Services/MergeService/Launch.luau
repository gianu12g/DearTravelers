--!strict
--[[
	Phase 2 launch: picking a carried squishy up into a scaled, falling
	projectile and running its whole spawn-squish/descent/impact sequence.
	See the MergeService init.luau header's PHASE 2 note (Touched vs
	Heartbeat) and DISARM/RE-ARM note for the surrounding design; this module
	is the launch half of Phase 2, the carry/merge/drop half lives in Carry.

	`liveBases`, `carries`, and `activeLaunches` are owned by init.luau and
	handed to this module once via Launch.setup() -- see Spawning.luau's own
	note on the same pattern. Launch never requires Carry.luau: it only reads
	and clears `carries[player]` directly (the pickup -> launch hand-off),
	which needs the shared table, not any of Carry's functions.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Assets = require(script.Parent.Assets)
local BaseService = require(script.Parent.Parent.BaseService)
local Damage = require(script.Parent.Damage)
local LaunchBeamRuntime = require(ReplicatedStorage.Shared.LaunchBeamRuntime)
local LaunchEffects = require(script.Parent.LaunchEffects)
local Log = require(ReplicatedStorage.Shared.Log)
local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local MergeObjectVisuals = require(ServerStorage.Modules.MergeObjectVisuals)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)
local Spawning = require(script.Parent.Spawning)
local StatusUI = require(script.Parent.StatusUI)
local Types = require(script.Parent.Types)
local UINotificationService = require(script.Parent.Parent.UISystem.UINotificationService)
local Vfx = require(script.Parent.Vfx)

local log = Log.new("MergeService")

type Deps = {
	liveBases: { [Player]: Types.LiveBase },
	carries: { [Player]: Types.CarryState },
	activeLaunches: { [Player]: Types.LaunchState },
}

-- Set once by Launch.setup(), called from init.Init(). See Spawning.luau's
-- own header note on why these are references to init-owned tables.
local liveBases: { [Player]: Types.LiveBase } = nil :: any
local carries: { [Player]: Types.CarryState } = nil :: any
local activeLaunches: { [Player]: Types.LaunchState } = nil :: any

local LAUNCH_SOUND_LIFETIME = 10
-- Touchdown thud, played whether the drop hit the map surface or was stopped
-- by a base forcefield -- both resolve to the same landing frame below. Its
-- head trim lives on the AssetIds/Sounds entry, not here.
local LAUNCH_LAND_SOUND_VOLUME = 2

-- Drop spawn squish: the same press feel Mush gives a carried squishy
-- (MushController's COMPRESS_SCALE/SPREAD_SCALE/SQUASH_IN/SQUASH_HOLD/
-- SQUASH_OUT), replayed here so every observer sees the giant squishy press
-- itself the instant it materializes above the landing point.
local LAUNCH_SPAWN_SQUASH_COMPRESS_SCALE = 0.55
local LAUNCH_SPAWN_SQUASH_SPREAD_SCALE = 1.12
local LAUNCH_SPAWN_SQUASH_IN = TweenInfo.new(0.16, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local LAUNCH_SPAWN_SQUASH_HOLD = 0.08
local LAUNCH_SPAWN_SQUASH_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

-- Landing impact squash: a harder, slower bottom-anchored flatten than the
-- spawn squish, so the drop reads as a heavier hit. The flatten is slow and weighty,
-- then it pops back with a quick, snappy bounce.
local LAUNCH_IMPACT_SQUASH_COMPRESS_SCALE = 0.3
local LAUNCH_IMPACT_SQUASH_SPREAD_SCALE = 1.4
local LAUNCH_IMPACT_SQUASH_IN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LAUNCH_IMPACT_SQUASH_HOLD = 0.15
local LAUNCH_IMPACT_SQUASH_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- How far through the rebound (LAUNCH_IMPACT_SQUASH_OUT) the impact burst
-- fires. The explosion has to land just BEFORE the squishy finishes popping
-- back up, not after it has already settled -- so this is a fraction of that
-- phase's raw (un-eased) progress, not of the whole squash. Lower it to fire
-- earlier in the rebound, raise it toward 1 to fire later.
local LAUNCH_IMPACT_EXPLOSION_PROGRESS = 0.8
-- Authored on the tier models to place the body-centered Explosion effect.
-- GroundHit reuses MergeObjectVisuals.getBeamAnchorOffset instead of reading
-- the live beamModelPosAtt; see launchGroundHitPoint.
local LAUNCH_EXPLOSION_ATTACHMENT_NAME = "explosionPosAtt"

local Launch = {}

function Launch.setup(deps: Deps)
	liveBases = deps.liveBases
	carries = deps.carries
	activeLaunches = deps.activeLaunches
end

function Launch.cancelLaunch(player: Player)
	local launch = activeLaunches[player]
	if launch == nil then
		return
	end
	activeLaunches[player] = nil
	LaunchEffects.destroyLaunchBeams(launch)
	-- Must run before reAnchorPart: that recomputes yOffset from tierDefFor's
	-- ORIGINAL tier size, so a still-scaled root would settle at the wrong
	-- height.
	LaunchEffects.restoreLaunchScale(launch)

	if liveBases[player] == launch.live and launch.part.Parent ~= nil then
		Spawning.reAnchorPart(launch.live, launch.part, launch.entry)
		Spawning.markDisarmed(launch.live, launch.part)
	end
end

function Launch.startCooldown(player: Player, part: BasePart)
	local duration = MergeConfig.LAUNCH_COOLDOWN_SECONDS
	if duration <= 0 or part.Parent == nil then
		return
	end

	local readyAt = Workspace:GetServerTimeNow() + duration
	part:SetAttribute("LaunchReadyAt", readyAt)
	StatusUI.setLaunchCooldownCounter(part, duration)

	task.spawn(function()
		local lastWholeSeconds = -1
		while part.Parent ~= nil and part:GetAttribute("LaunchReadyAt") == readyAt do
			local remaining = math.max(0, readyAt - Workspace:GetServerTimeNow())
			local wholeSeconds = math.ceil(remaining)
			if wholeSeconds ~= lastWholeSeconds then
				lastWholeSeconds = wholeSeconds
				StatusUI.setLaunchCooldownCounter(part, remaining)
			end
			if remaining <= 0 then
				break
			end
			task.wait(math.min(0.2, remaining))
		end

		if part.Parent ~= nil and part:GetAttribute("LaunchReadyAt") == readyAt then
			part:SetAttribute("LaunchReadyAt", nil)
			StatusUI.setLaunchCooldownCounter(part, 0)
			local carry = carries[player]
			if carry ~= nil and carry.part == part then
				player:SetAttribute("CarryingLaunchReadyAt", nil)
			end
		end
	end)
end

-- Server-side mirror of MushController.playMushSound: the part is Anchored
-- for the whole drop, so a Sound parented to it replicates and plays for
-- every client the same way the projectile's own CFrame changes already do
-- -- unlike Mush's player-triggered version, this needs no Net event. A fresh
-- Sound per call lets the launch's sounds overlap instead of cutting each
-- other off; the caller applies the id, since the mush sounds are authored
-- per tier while the rest are AssetIds entries.
local function newLaunchSound(part: BasePart, name: string, volume: number): Sound?
	if part.Parent == nil then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.Volume = math.clamp(volume, 0, 10)
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	sound.Parent = part
	Debris:AddItem(sound, LAUNCH_SOUND_LIFETIME)
	return sound
end

-- Per-tier mush sound: id and volume come off the model template's own
-- attributes (MergeObjectVisuals.getMushSound), not from AssetIds, so there is
-- no entry to carry a head trim -- these are authored to start on their hit.
local function playLaunchMushSound(part: BasePart, soundId: string, volume: number)
	if soundId == "" then
		return
	end

	local sound = newLaunchSound(part, "MushSound", volume)
	if sound == nil then
		return
	end
	SoundKit.applyId(sound, soundId, nil)
	sound:Play()
end

local function playLaunchEntrySound(part: BasePart, name: string, entry: Sounds.Entry, volume: number)
	local sound = newLaunchSound(part, name, volume)
	if sound == nil then
		return
	end
	SoundKit.apply(sound, entry)
	sound:Play()
end

-- Same six-direction geometry as MushController.squashGeometry: `scale` is
-- the per-axis Size multiplier, `anchor` is the local point (relative to
-- `size`'s own center) that must not move while that scale is applied.
local function launchSquashGeometry(
	size: Vector3,
	direction: string,
	compressScale: number,
	spreadScale: number
): (Vector3, Vector3)
	if direction == "Bottom" then
		return Vector3.new(spreadScale, compressScale, spreadScale), Vector3.new(0, size.Y / 2, 0)
	elseif direction == "Left" then
		return Vector3.new(compressScale, spreadScale, spreadScale), Vector3.new(size.X / 2, 0, 0)
	elseif direction == "Right" then
		return Vector3.new(compressScale, spreadScale, spreadScale), Vector3.new(-size.X / 2, 0, 0)
	elseif direction == "Front" then
		return Vector3.new(spreadScale, spreadScale, compressScale), Vector3.new(0, 0, size.Z / 2)
	elseif direction == "Back" then
		return Vector3.new(spreadScale, spreadScale, compressScale), Vector3.new(0, 0, -size.Z / 2)
	end

	-- Top is both the default and the invalid-value fallback, same rule as
	-- MushController.squashGeometry.
	return Vector3.new(spreadScale, compressScale, spreadScale), Vector3.new(0, -size.Y / 2, 0)
end

type LaunchSquashVisualState = {
	part: BasePart,
	weld: Weld,
	size: Vector3,
	c0: CFrame,
	targetSize: Vector3,
	targetC0: CFrame,
}

-- Mirrors MushController.collectVisualStates -- same Visual/VisualWeld walk,
-- same anchor-then-lerp technique -- just server-side, so the drop's spawn
-- squish and landing squash replicate to every observer instead of only
-- playing back locally for whoever triggers Mush.
local function collectLaunchVisualStates(
	root: BasePart,
	direction: string,
	compressScale: number,
	spreadScale: number
): { LaunchSquashVisualState }
	local visual = root:FindFirstChild("Visual")
	if visual == nil then
		return {}
	end

	local scale, anchor = launchSquashGeometry(root.Size, direction, compressScale, spreadScale)
	local states: { LaunchSquashVisualState } = {}
	local candidates = if visual:IsA("BasePart") then { visual } else visual:GetDescendants()

	for _, candidate in candidates do
		if not candidate:IsA("BasePart") then
			continue
		end
		local weld = candidate:FindFirstChild("VisualWeld")
		if weld == nil or not weld:IsA("Weld") then
			continue
		end

		local c0 = weld.C0
		local targetPosition = anchor + (c0.Position - anchor) * scale
		table.insert(states, {
			part = candidate,
			weld = weld,
			size = candidate.Size,
			c0 = c0,
			targetSize = candidate.Size * scale,
			targetC0 = CFrame.new(targetPosition) * c0.Rotation,
		})
	end

	return states
end

type LaunchSquashRootState = {
	size: Vector3,
	position: Vector3,
	targetSize: Vector3,
	targetPosition: Vector3,
}

--[[
	FALLBACK CUBE PATH: MergeObjectVisuals.attach returned false for this tier
	(no Visual/VisualWeld children -- the colored root cube itself is what
	players see), so the root has to squash directly. Computes a fixed world
	anchor point from the root's own CURRENT (already drop-scaled) size and
	position once, up front -- the same "anchor once, lerp toward it"
	technique the weld path uses -- so the anchored plane never drifts across
	the animation.
]]
local function collectLaunchRootState(
	root: BasePart,
	direction: string,
	compressScale: number,
	spreadScale: number
): LaunchSquashRootState
	local size = root.Size
	local position = root.Position
	local scale, anchor = launchSquashGeometry(size, direction, compressScale, spreadScale)
	local targetSize = size * scale
	local _, targetAnchor = launchSquashGeometry(targetSize, direction, compressScale, spreadScale)
	local worldAnchor = position + anchor
	local targetPosition = worldAnchor - targetAnchor

	return {
		size = size,
		position = position,
		targetSize = targetSize,
		targetPosition = targetPosition,
	}
end

--[[
	One squash-and-settle beat (spawn squish or landing impact), run as a
	Heartbeat loop in the same style as animateDropDescent: accumulate dt,
	recheck every frame that this is still the active launch and the part
	still exists. Prefers the Visual/VisualWeld cosmetic children
	(MushController.squashVisual's own technique, replayed server-side);
	falls back to squashing the root cube itself via collectLaunchRootState
	for tiers with no attached artwork.

	Returns false the instant an abort condition is hit -- callers use that to
	skip the rest of the sequence. This function does NOT restore anything
	itself on abort; restoreLaunchScale is the actual safety net and restores
	true pre-launch values regardless of which phase was interrupted.
]]
local function runLaunchSquash(
	player: Player,
	launch: Types.LaunchState,
	direction: string,
	compressScale: number,
	spreadScale: number,
	squashIn: TweenInfo,
	hold: number,
	squashOut: TweenInfo,
	-- Fired once, mid-rebound, at LAUNCH_IMPACT_EXPLOSION_PROGRESS through the
	-- squashOut phase. Driven off the animation's own progress rather than a
	-- parallel task.delay so it stays pinned to the frame the squishy is
	-- actually on, even if the server hitches. Must not yield -- it runs inside
	-- the animation loop.
	onRebound: (() -> ())?
): boolean
	local part = launch.part
	local visualStates = collectLaunchVisualStates(part, direction, compressScale, spreadScale)
	local rootState: LaunchSquashRootState? = if #visualStates == 0
		then collectLaunchRootState(part, direction, compressScale, spreadScale)
		else nil

	local function apply(alpha: number)
		for _, state in visualStates do
			if state.part.Parent ~= nil and state.weld.Parent ~= nil then
				state.part.Size = state.size:Lerp(state.targetSize, alpha)
				state.weld.C0 = state.c0:Lerp(state.targetC0, alpha)
			end
		end
		if rootState ~= nil then
			part.Size = rootState.size:Lerp(rootState.targetSize, alpha)
			part.CFrame = CFrame.new(rootState.position:Lerp(rootState.targetPosition, alpha))
		end
	end

	local function runPhase(
		tweenInfo: TweenInfo,
		fromAlpha: number,
		toAlpha: number,
		onProgress: ((number) -> ())?
	): boolean
		local duration = tweenInfo.Time
		local elapsed = 0
		while elapsed < duration do
			if activeLaunches[player] ~= launch or part.Parent == nil then
				return false
			end
			elapsed += RunService.Heartbeat:Wait()
			local rawAlpha = math.clamp(elapsed / duration, 0, 1)
			local eased = TweenService:GetValue(rawAlpha, tweenInfo.EasingStyle, tweenInfo.EasingDirection)
			apply(fromAlpha + (toAlpha - fromAlpha) * eased)
			if onProgress ~= nil then
				onProgress(rawAlpha)
			end
		end
		apply(toAlpha)
		return true
	end

	if not runPhase(squashIn, 0, 1) then
		return false
	end

	local holdElapsed = 0
	while holdElapsed < hold do
		if activeLaunches[player] ~= launch or part.Parent == nil then
			return false
		end
		holdElapsed += RunService.Heartbeat:Wait()
	end

	-- The final loop iteration always clamps rawAlpha to exactly 1 (elapsed has
	-- reached duration by then), so the threshold below is guaranteed to be
	-- crossed while the phase is still running -- onRebound cannot be skipped by
	-- a long frame, only pulled earlier in the rebound.
	local rebounded = false
	return runPhase(squashOut, 1, 0, function(rawAlpha)
		if rebounded or onRebound == nil or rawAlpha < LAUNCH_IMPACT_EXPLOSION_PROGRESS then
			return
		end
		rebounded = true
		onRebound()
	end)
end

--[[
	Vertical-only fall from dropStart (read straight off the part -- launchCarried
	teleports it there before this ever runs) down to the map surface. Every
	server Heartbeat re-resolves the forcefield at this X/Z and checks the whole
	frame's movement segment, so a dome activated during the fall catches the
	projectile as long as its bottom has not already crossed the dome surface.

	The resolved impact position and owner are returned to runLaunch so the
	GroundHit, explosion, and damage decision all use the same physical contact.
	No rotation at all: the giant squishy stays upright so it reads as a
	deliberate drop onto the target rather than a tumbling projectile.
]]
local function animateDropDescent(
	player: Player,
	launch: Types.LaunchState,
	groundTargetPosition: Vector3,
	projectileHalfHeight: number
): (boolean, Vector3, Player?)
	local part = launch.part
	local dropStart = part.Position
	local duration = MergeConfig.LAUNCH_DROP_SECONDS
	local elapsed = 0

	while elapsed < duration do
		if activeLaunches[player] ~= launch or part.Parent == nil then
			return false, groundTargetPosition, nil
		end

		local previousPosition = part.Position
		elapsed += RunService.Heartbeat:Wait()
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local nextPosition = dropStart:Lerp(groundTargetPosition, alpha * alpha * alpha)
		local shieldImpact, shieldOwner =
			BaseService.resolveForcefieldImpact(groundTargetPosition.X, groundTargetPosition.Z, projectileHalfHeight)
		if shieldImpact ~= nil and previousPosition.Y >= shieldImpact.Y and nextPosition.Y <= shieldImpact.Y then
			part.CFrame = CFrame.new(shieldImpact)
			return true, shieldImpact, shieldOwner
		end
		part.CFrame = CFrame.new(nextPosition)
	end

	part.CFrame = CFrame.new(groundTargetPosition)
	return true, groundTargetPosition, nil
end

-- Uses the exact same template-space anchor calculation as attachLaunchBeams.
-- Reading beamModelPosAtt.WorldPosition from the live clone is wrong after
-- MergeObjectVisuals.attach assigns a PrimaryPart and the launch scales the
-- welded visual: on Tier 2 it moves the nominal floor anchor toward the model
-- center. The template offset remains stable, and scaling it alongside the
-- projectile keeps GroundHit pinned where the falling beams actually ended.
local function launchGroundHitPoint(launch: Types.LaunchState, fallback: Vector3): Vector3
	local anchorOffset = MergeObjectVisuals.getBeamAnchorOffset(Types.sanitizeTier(launch.entry.Tier))
	if anchorOffset == nil then
		return fallback
	end

	local bottomCenter = Vector3.new(0, -launch.part.Size.Y / 2, 0)
	local localAnchor = bottomCenter + anchorOffset * launch.sizeMultiplier
	return launch.part.CFrame:PointToWorldSpace(localAnchor)
end

-- Explosion intentionally follows its live, body-centered attachment.
local function launchVfxPoint(launch: Types.LaunchState, attachmentName: string, fallback: Vector3): Vector3
	local visual = launch.part:FindFirstChild("Visual")
	local attachment = if visual ~= nil then visual:FindFirstChild(attachmentName, true) else nil
	if attachment ~= nil and attachment:IsA("Attachment") then
		return attachment.WorldPosition
	end
	return fallback
end

-- Explosion fires during the landing rebound at explosionPosAtt. GroundHit is
-- sent separately at touchdown, before the landing squash begins.
local function explodeDroppedSquishy(launch: Types.LaunchState, position: Vector3)
	local explosionPosition = launchVfxPoint(launch, LAUNCH_EXPLOSION_ATTACHMENT_NAME, position)
	LaunchEffects.hideLaunchVisual(launch)
	-- Every client renders both the particles and spatial pop from this event.
	-- The sound is locally created at explosionPosition with short rolloff.
	Vfx.spawnLaunchImpactVfx(explosionPosition)
end

local function finishLaunch(player: Player, launch: Types.LaunchState, startCooldown: boolean)
	if activeLaunches[player] ~= launch then
		return
	end
	activeLaunches[player] = nil
	LaunchEffects.destroyLaunchBeams(launch)
	-- Must run before reAnchorPart: that recomputes yOffset from tierDefFor's
	-- ORIGINAL tier size, so a still-scaled root would settle at the wrong
	-- height.
	LaunchEffects.restoreLaunchScale(launch)

	if liveBases[player] == launch.live and launch.part.Parent ~= nil then
		Spawning.reAnchorPart(launch.live, launch.part, launch.entry)
		Spawning.markDisarmed(launch.live, launch.part)
		if startCooldown then
			Launch.startCooldown(player, launch.part)
		end
	end
end

--[[
	Runs after launchCarried has already teleported+scaled the projectile to
	dropStart: spawn squish, the fall, the landing impact squash, then the
	explosion/damage moment. Each phase's own
	animation function returns false the instant activeLaunches[player] stops
	being this exact launch (or the part is gone -- see applySquishyDamage's
	mid-flight death branch), and runLaunch just stops there; finishLaunch and
	restoreLaunchScale are what actually clean up on every other exit path.
]]
local function runLaunch(player: Player, launch: Types.LaunchState, targetPosition: Vector3)
	local tier = Types.sanitizeTier(launch.entry.Tier)
	local direction = MergeObjectVisuals.getMushDirection(tier)
	local soundId, soundVolume = MergeObjectVisuals.getMushSound(tier)
	playLaunchMushSound(launch.part, soundId, soundVolume)

	local spawnSquishOk = runLaunchSquash(
		player,
		launch,
		direction,
		LAUNCH_SPAWN_SQUASH_COMPRESS_SCALE,
		LAUNCH_SPAWN_SQUASH_SPREAD_SCALE,
		LAUNCH_SPAWN_SQUASH_IN,
		LAUNCH_SPAWN_SQUASH_HOLD,
		LAUNCH_SPAWN_SQUASH_OUT
	)
	if not spawnSquishOk then
		return
	end

	-- Beams belong to the descent, so they go on here, once the spawn squish
	-- has finished. The fade runs alongside animateDropDescent instead of
	-- gating it: both are bounded by the same launch, and destroyLaunchBeams
	-- stops the fade on every exit path, so this thread cannot outlive the
	-- projectile.
	LaunchEffects.attachLaunchBeams(launch, tier)
	local beams = launch.beams
	if beams ~= nil then
		task.spawn(LaunchBeamRuntime.fadeIn, beams, MergeConfig.LAUNCH_BEAM_FADE_IN_SECONDS)
	end

	local projectileHalfHeight = Types.tierDefFor(tier).Size / 2 * launch.sizeMultiplier
	local descentOk, resolvedTargetPosition, shieldOwner =
		animateDropDescent(player, launch, targetPosition, projectileHalfHeight)
	if not descentOk then
		return
	end
	targetPosition = resolvedTargetPosition
	launch.blockedByForcefield = shieldOwner

	-- The beams read as the descent itself, so they end with it: cut at
	-- touchdown rather than waiting for finishLaunch, which only runs after the
	-- impact squash, the explosion, and LAUNCH_IMPACT_PAUSE. This also cancels
	-- the fade thread above, in case a very short fall left it still running.
	-- finishLaunch still calls destroyLaunchBeams, which is a no-op once
	-- launch.beams is nil.
	LaunchEffects.destroyLaunchBeams(launch)

	-- GroundHit marks the exact touchdown frame, before the squishy compresses.
	-- The thud rides the projectile itself rather than the GroundHit broadcast:
	-- spawnGroundHitVfx is skipped entirely when its template is missing, and a
	-- landing should still be audible.
	local bottomCenter = targetPosition - Vector3.new(0, launch.part.Size.Y / 2, 0)
	playLaunchEntrySound(launch.part, "LandSound", Sounds.SquishyLand, LAUNCH_LAND_SOUND_VOLUME)
	Vfx.spawnGroundHitVfx(launchGroundHitPoint(launch, bottomCenter))

	-- Landing impact is always bottom-anchored ("Top" -- see
	-- launchSquashGeometry's fallback branch) so it flattens onto the ground,
	-- regardless of which direction that tier's spawn squish used.
	-- The burst fires from inside the rebound (see LAUNCH_IMPACT_EXPLOSION_PROGRESS)
	-- rather than after this call returns: it has to hit just before the squishy
	-- finishes popping back up, and waiting for the squash to finish put it a
	-- full 0.18s late, after the pop had already settled.
	local impactSquishOk = runLaunchSquash(
		player,
		launch,
		"Top",
		LAUNCH_IMPACT_SQUASH_COMPRESS_SCALE,
		LAUNCH_IMPACT_SQUASH_SPREAD_SCALE,
		LAUNCH_IMPACT_SQUASH_IN,
		LAUNCH_IMPACT_SQUASH_HOLD,
		LAUNCH_IMPACT_SQUASH_OUT,
		function()
			explodeDroppedSquishy(launch, targetPosition)
		end
	)
	if not impactSquishOk then
		return
	end

	local attackerLevel = MergeConfig.healthForTier(tier)
	local damage = attackerLevel * MergeConfig.LAUNCH_DAMAGE_FRACTION

	-- A launch is allowed to land anywhere, including empty and unclaimed map
	-- space. Every other player's live squishies are checked spatially; an empty
	-- landing simply produces the impact visual and damages nothing.
	for targetPlayer in liveBases do
		if targetPlayer ~= player and targetPlayer ~= launch.blockedByForcefield then
			Damage.damageSquishiesNear(targetPlayer, targetPosition, MergeConfig.LAUNCH_IMPACT_RADIUS, damage)
		end
	end

	task.wait(MergeConfig.LAUNCH_IMPACT_PAUSE)
	finishLaunch(player, launch, true)
end

-- Validates one overview selection and starts a server-owned drop. The
-- client chooses only a bounded map X/Z point; it cannot choose the source
-- object, damage, radius, surface height, drop scale, or fall duration.
function Launch.launchCarried(player: Player, worldX: number, worldZ: number): (boolean, string)
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
	local tier = Types.sanitizeTier(carry.entry.Tier)
	-- Resolved once here and carried on the LaunchState: the artwork may set its
	-- own LaunchSize, and the landing solve below, applyLaunchScale, and the
	-- beam anchor all have to use the same number.
	local sizeMultiplier = MergeObjectVisuals.getLaunchSizeMultiplier(tier) or MergeConfig.LAUNCH_DROP_SIZE_MULTIPLIER
	local halfSize = Types.tierDefFor(tier).Size / 2
	-- Resolved with the SCALED half-size (see applyLaunchScale below) so the
	-- enlarged squishy actually rests ON the surface once it lands, instead of
	-- floating or sinking by the difference between its real and drop sizes.
	local targetPosition = Assets.resolveLaunchTarget(worldX, worldZ, halfSize * sizeMultiplier)
	if targetPosition == nil then
		return false, "Choose a point inside the map"
	end
	local _, initialShieldOwner = BaseService.resolveForcefieldImpact(worldX, worldZ, halfSize * sizeMultiplier)
	local targetOwner = BaseService.getOwnerAtPosition(worldX, worldZ) or initialShieldOwner

	local launch: Types.LaunchState = {
		live = carry.live,
		part = carry.part,
		entry = carry.entry,
		beamTemplate = Vfx.equippedLaunchBeamTemplate(player),
		beams = nil,
		scale = nil,
		sizeMultiplier = sizeMultiplier,
		blockedByForcefield = nil,
	}
	activeLaunches[player] = launch
	carries[player] = nil
	Types.clearCarryingAttributes(player)
	carry.weld:Destroy()
	carry.part.Anchored = true
	carry.part.Massless = false
	carry.part.CanCollide = false
	carry.part.CanTouch = false
	carry.part.CanQuery = false

	-- Teleport above the landing point and scale up here, before runLaunch's
	-- spawn squish plays: applyLaunchScale must run before attachLaunchBeams
	-- (beams read launch.part.Size to place their anchor, see its own header
	-- note), which is why beams themselves attach later, in runLaunch.
	local dropStart = targetPosition + Vector3.new(0, MergeConfig.LAUNCH_DROP_HEIGHT, 0)
	carry.part.CFrame = CFrame.new(dropStart)
	LaunchEffects.applyLaunchScale(launch)

	for _, recipient in Players:GetPlayers() do
		local message: string
		if targetOwner == nil then
			message = if recipient == player
				then "You launched a Squishy!"
				else `{player.DisplayName} launched a Squishy!`
		elseif targetOwner == player then
			message = if recipient == player
				then "You launched a Squishy at your own base!"
				else `{player.DisplayName} launched a Squishy at their own base!`
		elseif recipient == targetOwner then
			message = `{player.DisplayName} launched a Squishy at your base!`
		elseif recipient == player then
			message = `You launched a Squishy at {targetOwner.DisplayName}'s base!`
		else
			message = `{player.DisplayName} launched a Squishy at {targetOwner.DisplayName}'s base!`
		end
		UINotificationService.SendNotification(recipient, "Info", message)
	end

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

return Launch
