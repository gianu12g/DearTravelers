--!strict
--[[
	The Actions tab: buttons that act on the target's economy, squishies and
	cosmetics, plus a handful of LOCAL debug affordances that always act on this
	client's own character (see the comment above localHumanoid below).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local Snapshot = require(script.Parent.Snapshot)
local Style = require(script.Parent.Style)
local Widgets = require(script.Parent.Widgets)

local player = Players.LocalPlayer

-- Client-only WalkSpeed presets, cycled by the Actions tab's speed button. 16
-- is Roblox's default, so the cycle always returns to a normal character.
local WALK_SPEEDS = { 16, 40, 90 }

export type Deps = {
	getTarget: () -> Player,
	setStatus: (boolean, string) -> (),
	registerPage: (string, Frame) -> (),
}

local ActionsTab = {}

local deps: Deps? = nil

local radiusDebugButton: TextButton? = nil
local spawnTierButton: TextButton? = nil
local walkSpeedButton: TextButton? = nil

local walkSpeedIndex = 1

function ActionsTab.setup(newDeps: Deps)
	deps = newDeps
end

local function sendAdd(path: { string }, amount: number)
	local currentDeps = deps :: Deps
	Net.devAdd.send({ targetPlayer = currentDeps.getTarget(), path = path, amount = amount })
end

local function onZeroCoinsClicked()
	local currentDeps = deps :: Deps
	Net.devSet.send({ targetPlayer = currentDeps.getTarget(), path = { "Coins" }, kind = "number", value = "0" })
end

function ActionsTab.refreshSpawnTierButton()
	local button = spawnTierButton
	if button == nil then
		return
	end

	local tier = Snapshot.number("Merge.SpawnLevel")
	if tier == nil then
		button.Text = "Spawn tier: --"
		return
	end

	local clamped = math.clamp(math.floor(tier), 1, MergeConfig.MAX_TIER)
	local tierDef = MergeConfig.Tiers[clamped]
	button.Text = `Tier {clamped}: {if tierDef ~= nil then tierDef.Name else "?"}`
end

--[[
	The one adjustment that has to know the current value client-side, because
	the range it clamps to (1..MAX_TIER) is a client-side fact and devAdd only
	bounds magnitude. A stale snapshot can overshoot by one; MergeService
	sanitizes SpawnLevel on read, and the next click corrects it.
]]
local function nudgeSpawnTier(delta: number)
	local currentDeps = deps :: Deps
	local tier = Snapshot.number("Merge.SpawnLevel")
	if tier == nil then
		currentDeps.setStatus(false, "no snapshot yet -- try again in a moment")
		return
	end

	local wanted = math.clamp(math.floor(tier) + delta, 1, MergeConfig.MAX_TIER)
	if wanted == tier then
		currentDeps.setStatus(
			false,
			if delta > 0 then `already at tier {MergeConfig.MAX_TIER}` else "already at tier 1"
		)
		return
	end

	sendAdd({ "Merge", "SpawnLevel" }, wanted - tier)
end

local function onSpawnSquishiesClicked(count: number)
	local currentDeps = deps :: Deps
	Net.devSpawnSquishies.send({ targetPlayer = currentDeps.getTarget(), count = count })
end

local function onClearSquishiesClicked()
	local currentDeps = deps :: Deps
	Net.devClearSquishies.send({ targetPlayer = currentDeps.getTarget() })
end

local function onDamageSquishiesClicked()
	local currentDeps = deps :: Deps
	Net.devDamageSquishies.send({ targetPlayer = currentDeps.getTarget() })
end

local function onGrantAllCosmeticsClicked()
	local currentDeps = deps :: Deps
	Net.devGrantAllCosmetics.send({ targetPlayer = currentDeps.getTarget() })
end

function ActionsTab.updateRadiusDebugButton()
	local button = radiusDebugButton
	if button == nil then
		return
	end

	local enabled = player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
	button.Text = `Blast radius bounds: {if enabled then "ON" else "OFF"}  (R={MergeConfig.LAUNCH_IMPACT_RADIUS})`
	button.BackgroundColor3 = if enabled then Style.GRANT_COLOR else Style.FIELD_COLOR
end

local function onRadiusDebugClicked()
	local enabled = player:GetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE) == true
	player:SetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE, not enabled)
	ActionsTab.updateRadiusDebugButton()
end

--[[
	The three actions below are LOCAL and always act on this client's own
	character, never on the target. They work without a packet because a client
	already owns its own character: its CFrame and its Humanoid's properties
	replicate outward from here. Pointing them at another player would be a
	server action, and a different feature.
]]
local function localHumanoid(): Humanoid?
	local character = player.Character
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function onTeleportToTargetClicked()
	local currentDeps = deps :: Deps
	local target = currentDeps.getTarget()
	if target == player then
		currentDeps.setStatus(false, "you are the target -- pick someone else first")
		return
	end

	local character = player.Character
	local targetCharacter = target.Character
	if character == nil or targetCharacter == nil then
		currentDeps.setStatus(false, "one of you has no character right now")
		return
	end

	local pivot = targetCharacter.PrimaryPart
	if pivot == nil then
		currentDeps.setStatus(false, `{target.Name} has no root part yet`)
		return
	end

	-- Beside them, not inside them: a shared pivot spawns the two characters
	-- clipped together and physics resolves it by launching one.
	character:PivotTo(pivot.CFrame * CFrame.new(0, 0, 5))
	currentDeps.setStatus(true, `teleported to {target.Name}`)
end

local function onRespawnClicked()
	local currentDeps = deps :: Deps
	local humanoid = localHumanoid()
	if humanoid == nil then
		currentDeps.setStatus(false, "no character to respawn")
		return
	end
	humanoid.Health = 0
	currentDeps.setStatus(true, "killed your character -- respawning")
end

local function refreshWalkSpeedButton()
	local button = walkSpeedButton
	if button == nil then
		return
	end
	local speed = WALK_SPEEDS[walkSpeedIndex]
	button.Text = `My speed: {speed}`
	button.BackgroundColor3 = if walkSpeedIndex == 1 then Style.FIELD_COLOR else Style.GRANT_COLOR
end

local function onWalkSpeedClicked()
	local currentDeps = deps :: Deps
	walkSpeedIndex = walkSpeedIndex % #WALK_SPEEDS + 1
	refreshWalkSpeedButton()

	local humanoid = localHumanoid()
	if humanoid == nil then
		currentDeps.setStatus(false, "no character -- speed applies on your next spawn")
		return
	end

	humanoid.WalkSpeed = WALK_SPEEDS[walkSpeedIndex]
	currentDeps.setStatus(true, `walkspeed {WALK_SPEEDS[walkSpeedIndex]}`)
end

function ActionsTab.build(parent: Frame)
	local currentDeps = deps :: Deps
	local list = Widgets.newPage(parent, "Actions", currentDeps.registerPage)
	local scrollList = Widgets.newScrollList(list, "ActionsList", UDim2.new(), UDim2.fromScale(1, 1))

	Widgets.addSectionHeader(scrollList, 1, "TARGET ECONOMY  (writes the target's profile)")
	Widgets.addButtonRow(scrollList, 2, {
		{
			text = "+1K coins",
			onClick = function()
				sendAdd({ "Coins" }, 1000)
			end,
		},
		{
			text = "+10K",
			onClick = function()
				sendAdd({ "Coins" }, 10000)
			end,
		},
		{
			text = "+100K",
			onClick = function()
				sendAdd({ "Coins" }, 100000)
			end,
		},
		{
			text = "+1M",
			onClick = function()
				sendAdd({ "Coins" }, 1000000)
			end,
		},
	})
	Widgets.addButtonRow(scrollList, 3, {
		{ text = "Coins -> 0", color = Style.DANGER_COLOR, onClick = onZeroCoinsClicked },
		{
			text = "+1 level",
			onClick = function()
				sendAdd({ "Level" }, 1)
			end,
		},
		{
			text = "+1K XP",
			onClick = function()
				sendAdd({ "Experience" }, 1000)
			end,
		},
		{
			text = "+5 spins",
			onClick = function()
				sendAdd({ "UISystem", "Spins" }, 5)
			end,
		},
	})

	Widgets.addSectionHeader(scrollList, 4, "TARGET SQUISHIES")
	Widgets.addButtonRow(scrollList, 5, {
		{
			text = "Spawn 1",
			onClick = function()
				onSpawnSquishiesClicked(1)
			end,
		},
		{
			text = "Spawn 5",
			onClick = function()
				onSpawnSquishiesClicked(5)
			end,
		},
		{
			text = "Fill pad",
			onClick = function()
				onSpawnSquishiesClicked(Snapshot.number("Merge.MaxSpawns") or UpgradeConfig.DEFAULT_MAX_SPAWNS)
			end,
		},
		{ text = "Clear all", color = Style.DANGER_COLOR, onClick = onClearSquishiesClicked },
	})
	local tierRow = Widgets.addButtonRow(scrollList, 6, {
		{
			text = "- tier",
			onClick = function()
				nudgeSpawnTier(-1)
			end,
		},
		{ text = "Spawn tier: --", onClick = ActionsTab.refreshSpawnTierButton },
		{
			text = "+ tier",
			onClick = function()
				nudgeSpawnTier(1)
			end,
		},
	})
	spawnTierButton = tierRow[2]
	ActionsTab.refreshSpawnTierButton()

	Widgets.addButtonRow(scrollList, 7, {
		{ text = "Damage all squishies  -25% max HP", color = Style.DANGER_COLOR, onClick = onDamageSquishiesClicked },
	})

	Widgets.addSectionHeader(scrollList, 8, "TARGET COSMETICS")
	Widgets.addButtonRow(scrollList, 9, {
		{ text = "Grant all cosmetics", color = Style.ACCENT_COLOR, onClick = onGrantAllCosmeticsClicked },
	})

	Widgets.addSectionHeader(scrollList, 10, "LOCAL DEBUG  (affects YOU, never the target)")
	local radiusRow = Widgets.addButtonRow(scrollList, 11, {
		{ text = "Blast radius bounds: OFF", onClick = onRadiusDebugClicked },
	})
	radiusDebugButton = radiusRow[1]
	ActionsTab.updateRadiusDebugButton()

	local localRow = Widgets.addButtonRow(scrollList, 12, {
		{ text = "Teleport to target", onClick = onTeleportToTargetClicked },
		{ text = "Respawn me", onClick = onRespawnClicked },
		{ text = "My speed: 16", onClick = onWalkSpeedClicked },
	})
	walkSpeedButton = localRow[3]
	refreshWalkSpeedButton()
end

function ActionsTab.cleanup()
	radiusDebugButton = nil
	spawnTierButton = nil
	walkSpeedButton = nil

	player:SetAttribute(MergeConfig.LAUNCH_RADIUS_DEBUG_ATTRIBUTE, nil)
end

return ActionsTab
