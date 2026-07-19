--!strict
--[[
	Touch-to-light-up floor keys under Workspace.LightUpKeys.

	Replaces the old per-key server Scripts (2 per key) and their duplicate
	Sound instances entirely -- both are being deleted from the place. Doing
	the tween client-side is the point: a server-driven tween only replicates
	its end pose, which is why the old keys looked choppy. Everything here --
	the press/release pose, the glow, the sound -- is local-only and never
	touches the server.

	Every BasePart child of the folder is treated as a key. The keys are being
	renamed Key1..Key42 (currently all "part"), so nothing here matches by
	name -- membership in the folder is the only thing that enrolls a part.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)

local log = Log.new("LightUpKeysController")

local FOLDER_NAME = "LightUpKeys"
local FOLDER_WAIT_TIMEOUT = 10

local RELEASE_BUFFER = 0.08 -- debounces walking across a key's edge

local PRESS_DEPTH = 0.6
local PRESS_OFFSET = CFrame.new(0, -PRESS_DEPTH, 0)

local SENSOR_NAME = "TouchSensor"

local PRESS_POSITION_INFO = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_POSITION_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local GLOW_ON_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GLOW_OFF_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local GLOW_COLOR = Color3.fromRGB(53, 66, 255)

local SOUND_ID = "rbxassetid://83673675473754"
local SOUND_VOLUME = 0.5
local SOUND_LOAD_TIMEOUT = 3 -- fallback destroy if a bad SoundId never fires Ended/Stopped
local PLAYBACK_SPEED_MIN = 0.95
local PLAYBACK_SPEED_MAX = 1.05

-- Designer-tunable: cuts the clicky brightness of the raw asset (HighGain)
-- and adds a touch of warmth (LowGain) so the keys read as duller/creamier.
-- Retune here if a future asset needs a different EQ.
local EQ_HIGH_GAIN = -12
local EQ_MID_GAIN = 0
local EQ_LOW_GAIN = 2

type KeyState = {
	part: BasePart,
	-- Captured once at wire time; never re-read mid-animation (see wireKey).
	-- Authored keys are Color3.fromRGB(59, 67, 70) / SmoothPlastic, but that's
	-- read per-key rather than hardcoded so a touched key always fades back to
	-- whatever it actually looked like at rest.
	restCFrame: CFrame,
	restColor: Color3,
	restMaterial: Enum.Material,
	-- Stationary invisible part touch detection actually lives on -- see
	-- wireKey for why it can't live on `part` itself.
	sensor: BasePart,
	-- hit -> the connection watching that hit for AncestryChanged (see
	-- onTouched / onHitLeftWorkspace). The connection IS the set membership,
	-- so there is nothing separate to leak or forget to disconnect.
	touching: { [BasePart]: RBXScriptConnection },
	pressed: boolean,
	-- Flips false on unwireKey so a RELEASE_BUFFER task.delay already in
	-- flight for a removed key is a no-op instead of tweening a dead part.
	active: boolean,
	positionHandle: Motion.Handle?,
	colorHandle: Motion.Handle?,
	connections: { RBXScriptConnection },
}

local keys: { [BasePart]: KeyState } = {}

local LightUpKeysController = {}

--[[
	One transient Sound per press, parented to the key so it's positional.
	Overlapping presses of the same key each get their own Sound and layer
	instead of cutting each other off. The timeout fallback is what stops a
	Sound whose asset fails to load (Ended/Stopped never fire) from sitting
	on the key forever.
]]
local function playKeySound(part: BasePart)
	local sound = Instance.new("Sound")
	sound.SoundId = SOUND_ID
	sound.Volume = SOUND_VOLUME
	sound.PlaybackSpeed = PLAYBACK_SPEED_MIN + math.random() * (PLAYBACK_SPEED_MAX - PLAYBACK_SPEED_MIN)
	sound.Parent = part

	-- Parented to the transient Sound, so Destroy()ing it below takes the
	-- effect with it -- nothing extra to clean up.
	local equalizer = Instance.new("EqualizerSoundEffect")
	equalizer.Name = "KeyEqualizer"
	equalizer.HighGain = EQ_HIGH_GAIN
	equalizer.MidGain = EQ_MID_GAIN
	equalizer.LowGain = EQ_LOW_GAIN
	equalizer.Parent = sound

	local destroyed = false
	local function destroySound()
		if destroyed then
			return
		end
		destroyed = true
		sound:Destroy()
	end

	sound.Ended:Once(destroySound)
	sound.Stopped:Once(destroySound)
	task.delay(SOUND_LOAD_TIMEOUT, destroySound)

	sound:Play()
end

local function cancelHandles(key: KeyState)
	if key.positionHandle ~= nil then
		key.positionHandle.cancel()
		key.positionHandle = nil
	end
	if key.colorHandle ~= nil then
		key.colorHandle.cancel()
		key.colorHandle = nil
	end
end

local function pressKey(key: KeyState)
	cancelHandles(key)

	local target = key.restCFrame * PRESS_OFFSET
	key.positionHandle = Motion.tween(key.part, { CFrame = target }, PRESS_POSITION_INFO)

	key.part.Material = Enum.Material.Neon
	key.colorHandle = Motion.tween(key.part, { Color = GLOW_COLOR }, GLOW_ON_INFO)

	playKeySound(key.part)
end

local function releaseKey(key: KeyState)
	cancelHandles(key)

	key.positionHandle = Motion.tween(key.part, { CFrame = key.restCFrame }, RELEASE_POSITION_INFO)

	key.colorHandle = Motion.tween(key.part, { Color = key.restColor }, GLOW_OFF_INFO, function()
		-- Only reached on a real finish -- Motion.tween does not call back for
		-- a cancelled tween, so a press that interrupts this fade never flips
		-- the material back underneath the new glow.
		if key.active and not key.pressed then
			key.part.Material = key.restMaterial
		end
	end)
end

local function evaluate(key: KeyState)
	if not key.active then
		return
	end

	local isPressed = next(key.touching) ~= nil
	if isPressed == key.pressed then
		return
	end
	key.pressed = isPressed

	if isPressed then
		pressKey(key)
	else
		releaseKey(key)
	end
end

--[[
	Disconnects and drops `hit`'s entry if it has one. Returns whether there
	was one to drop, so callers can decide whether re-evaluating is worth it.
]]
local function forgetHit(key: KeyState, hit: BasePart): boolean
	local connection = key.touching[hit]
	if connection == nil then
		return false
	end
	connection:Disconnect()
	key.touching[hit] = nil
	return true
end

--[[
	TouchEnded is not guaranteed to fire when a touching part is destroyed
	while still overlapping the key -- the classic case is a character (this
	player's or another's) dying/resetting while standing on it. That would
	leave a stale entry in `touching` forever, and a stuck key gets no further
	Touched/TouchEnded events to notice by. AncestryChanged does not have that
	gap: it fires the moment `hit` is no longer under Workspace, so this
	re-evaluates immediately rather than waiting on an event that will never
	come.
]]
local function onHitLeftWorkspace(key: KeyState, hit: BasePart)
	if forgetHit(key, hit) then
		evaluate(key)
	end
end

local function onTouched(key: KeyState, hit: BasePart)
	local character = hit.Parent
	if character == nil then
		return
	end
	if character:FindFirstChildOfClass("Humanoid") == nil then
		return
	end

	if key.touching[hit] == nil then
		-- Touched can refire for a hit that's already being tracked (repeated
		-- contact while overlapping, not just the first frame of it), so this
		-- only wires a new watcher when there genuinely isn't one yet.
		local ancestryConnection = hit.AncestryChanged:Connect(function(_child: Instance, _parent: Instance?)
			if hit:IsDescendantOf(Workspace) then
				return
			end
			onHitLeftWorkspace(key, hit)
		end)
		key.touching[hit] = ancestryConnection
	end

	evaluate(key)
end

local function onTouchEnded(key: KeyState, hit: BasePart)
	forgetHit(key, hit)

	-- Pushed onto a task rather than evaluated inline, so a player walking
	-- across the key's edge (Touched/TouchEnded firing in quick succession)
	-- doesn't flicker the key up and back down.
	task.delay(RELEASE_BUFFER, function()
		evaluate(key)
	end)
end

local function wireKey(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	if keys[instance] ~= nil then
		-- ChildAdded and the initial GetChildren() scan in Start() can both
		-- observe the same part during the race between them; whichever runs
		-- first wins and the other is a no-op.
		return
	end

	--[[
		Touch detection lives on a stationary sensor, not on `instance` itself.
		`instance` is the part that gets tweened 0.6 studs down on press, and a
		foot only barely overlapping its edge falls out of contact the moment
		it moves -- TouchEnded fires, the release tween brings it back up,
		which re-touches the foot and presses it again, forever. The sensor
		sits at the key's rest CFrame and never moves, so its touch state is
		decoupled from the key's own animation entirely.

		Sized a bit taller than the key, extending PRESS_DEPTH further down,
		so the volume the key would occupy while pressed still touches a
		foot resting at the original surface height.
	]]
	local restCFrame = instance.CFrame
	local size = instance.Size

	local sensor = Instance.new("Part")
	sensor.Name = SENSOR_NAME
	sensor.Size = Vector3.new(size.X, size.Y + PRESS_DEPTH, size.Z)
	sensor.CFrame = restCFrame * CFrame.new(0, -PRESS_DEPTH / 2, 0)
	sensor.Anchored = true
	sensor.CanCollide = false
	sensor.CanQuery = false
	sensor.CanTouch = true
	sensor.Transparency = 1
	-- Parented to the key, not to the LightUpKeys folder -- ChildAdded on the
	-- folder only fires for direct children, so this is never mistaken for a
	-- key of its own. It also means the sensor never outlives the key.
	sensor.Parent = instance

	local key: KeyState = {
		part = instance,
		restCFrame = restCFrame,
		restColor = instance.Color,
		restMaterial = instance.Material,
		sensor = sensor,
		touching = {},
		pressed = false,
		active = true,
		positionHandle = nil,
		colorHandle = nil,
		connections = {},
	}

	local touchedConnection = sensor.Touched:Connect(function(hit: BasePart)
		onTouched(key, hit)
	end)
	local touchEndedConnection = sensor.TouchEnded:Connect(function(hit: BasePart)
		onTouchEnded(key, hit)
	end)
	key.connections = { touchedConnection, touchEndedConnection }

	keys[instance] = key
end

local function unwireKey(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end

	local key = keys[instance]
	if key == nil then
		return
	end
	keys[instance] = nil
	key.active = false

	for _, connection in key.connections do
		connection:Disconnect()
	end
	for _, touchConnection in key.touching do
		touchConnection:Disconnect()
	end
	cancelHandles(key)
	table.clear(key.touching)

	-- Explicit, not implied by the key's own fate: ChildRemoved also fires on
	-- a reparent, not just a Destroy, so the sensor could otherwise survive
	-- as an orphaned invisible part still listening for touches.
	key.sensor:Destroy()
end

function LightUpKeysController.Init()
	-- Nothing to register before Start() -- the folder isn't guaranteed to
	-- exist yet, and nothing here depends on server data arriving first.
end

function LightUpKeysController.Start()
	local folder = Workspace:WaitForChild(FOLDER_NAME, FOLDER_WAIT_TIMEOUT)
	if folder == nil then
		log.warn(`workspace.{FOLDER_NAME} not found after {FOLDER_WAIT_TIMEOUT}s -- no keys wired`)
		return
	end

	-- Connect before the initial scan (wireKey's own guard absorbs the double
	-- wire if a part lands in both the event and the GetChildren() below).
	folder.ChildAdded:Connect(wireKey)
	folder.ChildRemoved:Connect(unwireKey)

	for _, child in folder:GetChildren() do
		wireKey(child)
	end

	log.info("ready")
end

return LightUpKeysController
