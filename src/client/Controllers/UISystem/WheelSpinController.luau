--!strict
--[[
	Prize-wheel minigame. Ported from the source's
	Controllers/WheelSpinController.luau.

	The source's WheelSpin.Spin was an invoke (fire, get rewardIndex back
	synchronously). ByteNet is event-only, so this becomes the
	spinRequest/spinResult request/response pair (PORT-SPEC.md §3): the
	click handler only sends spinRequest; the actual spin animation starts
	when spinResult arrives. A short client-side pending-timeout (matching
	CodesController's own wedge guard) resets the request flag if the
	server never replies (e.g. it rejected the request with only a `notify`
	and no spinResult) so the button can't get stuck disabled forever.

	{"UISystem","Spins"} is a plain number in the DataService TEMPLATE
	(PORT-SPEC.md §2), not the source's {Spins, NextFreeSpin} pair -- there
	is no NextFreeSpin timestamp in the replicated shape, so the
	"next free spin in..." countdown label is left untouched (whatever
	Studio authored it with) rather than invented. Flagged as a follow-up.
]]

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local MonetizationController = require(script.Parent.MonetizationController)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)
local NotificationController = require(script.Parent.NotificationController)
local WheelSpinConfig = require(ReplicatedStorage.Shared.UISystem.Config.WheelSpin)

local log = Log.new("WheelSpinController")

local player = Players.LocalPlayer

local SEGMENT_COUNT = #WheelSpinConfig.Rewards
local SEGMENT_ANGLE = 360 / SEGMENT_COUNT
local POINTER_DEFLECT = 22
local POINTER_RETURN = TweenInfo.new(0.35, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local PENDING_TIMEOUT = 5

local isSpinning = false
local requestPending = false
local pointerTween: Tween? = nil
local playerAllowedForRPI = true
local spins = WheelSpinConfig.StartingSpins

local WheelSpinController = {}

local function bouncePointer(pointer: GuiObject)
	if pointerTween ~= nil then
		pointerTween:Cancel()
	end
	pointer.Rotation = POINTER_DEFLECT
	local tween = TweenService:Create(pointer, POINTER_RETURN, { Rotation = 0 })
	pointerTween = tween
	tween:Play()
end

local function spinTheWheel(
	wheel: GuiObject,
	pointer: GuiObject,
	tickSound: Sound,
	rewardSound: Sound,
	spinButton: GuiButton,
	rewardIndex: number
)
	if isSpinning then
		return
	end
	isSpinning = true
	spinButton.Active = false
	wheel.Rotation = 0

	local targetEffective = (rewardIndex - 1) * SEGMENT_ANGLE + math.random() * SEGMENT_ANGLE
	local currentEffective = -wheel.Rotation % 360

	local delta = (targetEffective - currentEffective + 360) % 360
	if delta == 0 then
		delta = 360
	end

	local totalAngle = WheelSpinConfig.NumberOfSpins * 360 + delta
	local targetRotation = wheel.Rotation - totalAngle

	local tweenInfo =
		TweenInfo.new(WheelSpinConfig.FullSpinDuration, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)
	local tween = TweenService:Create(wheel, tweenInfo, { Rotation = targetRotation })

	local startAbs = math.abs(wheel.Rotation)
	local lastTickCount = 0

	local tickConnection = RunService.Heartbeat:Connect(function()
		local traveled = math.abs(wheel.Rotation) - startAbs
		local tickCount = math.floor(traveled / SEGMENT_ANGLE)
		if tickCount > lastTickCount then
			lastTickCount = tickCount
			tickSound:Play()
			bouncePointer(pointer)
		end
	end)

	tween:Play()
	tween.Completed:Wait()
	tickConnection:Disconnect()
	rewardSound:Play()

	task.wait(2)
	isSpinning = false
	spinButton.Active = true
end

local function updateSpinLabel(spinButton: GuiButton)
	local label = spinButton:FindFirstChild("TextLabel")
	if label ~= nil and label:IsA("TextLabel") then
		label.Text = `SPIN (x{spins})`
	end
end

--[[
	No Init() -- spinResult only ever arrives in reply to a spinRequest THIS
	client sent, and that only happens after the Spin button below is
	wired, so there is no unsolicited-early-push race to guard against here
	(contrast DataController.OnNew / Net.devAccess, which register in
	Init() for exactly that reason). Resolving the frame requires yielding
	WaitForChild calls anyway (via Frames.get), which Init() must never do.
]]
function WheelSpinController.Start()
	local frame = Frames.get("WheelSpin")
	local spinButton = frame:WaitForChild("Spin") :: GuiButton
	local wheel = frame:WaitForChild("Wheel") :: GuiObject
	local pointer = frame:WaitForChild("Pointer") :: GuiObject
	local tickSound = frame:WaitForChild("Tick") :: Sound
	local rewardSound = frame:WaitForChild("Reward") :: Sound
	local sfxGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	tickSound.SoundGroup = sfxGroup
	rewardSound.SoundGroup = sfxGroup

	Net.spinResult.listen(function(data)
		requestPending = false
		spinTheWheel(wheel, pointer, tickSound, rewardSound, spinButton, data.rewardIndex)
	end)

	local policyOk, policyInfo = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	playerAllowedForRPI = policyOk and policyInfo ~= nil and not policyInfo.ArePaidRandomItemsRestricted

	for index, info in WheelSpinConfig.Rewards do
		local segment = wheel:FindFirstChild(tostring(index))
		if segment == nil then
			continue
		end
		local image = segment:FindFirstChild("ImageLabel")
		if image ~= nil and image:IsA("ImageLabel") then
			image.Image = `rbxassetid://{info.Icon}`
		end
		local textLabel = segment:FindFirstChild("TextLabel")
		if textLabel ~= nil and textLabel:IsA("TextLabel") then
			textLabel.Text = info.Text
		end
	end

	local buttonsFolder = frame:FindFirstChild("Buttons")
	if buttonsFolder ~= nil then
		for _, button in buttonsFolder:GetChildren() do
			if not button:IsA("GuiButton") then
				continue
			end
			button.MouseButton1Click:Connect(function()
				if not playerAllowedForRPI then
					NotificationController.Notify("Error", "You're not eligible for random paid items")
					return
				end
				MonetizationController.StartProductPrompt(`x{button.Name} Spins`)
			end)
		end
	end

	updateSpinLabel(spinButton)
	DataController.observe({ "UISystem", "Spins" }, function(value: any)
		if type(value) ~= "number" then
			return
		end
		spins = value
		updateSpinLabel(spinButton)
	end)

	spinButton.MouseButton1Click:Connect(function()
		if isSpinning or requestPending then
			return
		end
		requestPending = true
		Net.spinRequest.send()
		task.delay(PENDING_TIMEOUT, function()
			requestPending = false
		end)
	end)

	RunService.Heartbeat:Connect(function(delta)
		if isSpinning then
			return
		end
		wheel.Rotation -= 10 * delta
	end)

	log.info("ready")
end

return WheelSpinController
