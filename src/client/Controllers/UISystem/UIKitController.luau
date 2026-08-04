--!strict
--[[
	The UI framework core. Ported from the source's
	Controllers/UiController.luau (renamed: this repo already has a
	Controllers/UIController.luau -- an unrelated, Studio-authored "Screens"
	folder manager; see its own header comment. The two are independent
	systems that happen to share PlayerGui but not a frame model: this one
	drives PlayerGui.Main.Frames.* as a single-current-frame stack with
	attribute-tagged behaviors; the existing UIController drives
	StarterGui.Screens.* as a multi-screen registry with authored
	transitions. Deviation note: UIController owns NO camera blur/FOV --
	its animation is UI-local (Motion/Transitions tweening GuiObjects, never
	Lighting or the Camera) -- so there is nothing to reuse there, and this
	controller keeps the source's own blur+FOV tween.

	Declarative GUI-attribute system: instances tagged with Ui-* attributes
	(Ui-Effect, Ui-Scale, Ui-Hover, Ui-Click, Ui-Hover-Sound, Ui-Click-Sound,
	Ui-Product*, Ui-Pass*, Ui-Pack*, Ui-Gift-*, Ui-Frame, Ui-Close) get
	behavior auto-applied via PlayerGui.DescendantAdded, plus
	OpenFrame/CloseCurrentFrame (single "current frame" model with blur+FOV
	tween) and the HUD cash-counter animation.

	QueryDescendants replacement (PORT-SPEC.md §4): the source used
	Instance:QueryDescendants(cssSelector) for its one-time initial sweep
	(runBulkSetup) and relied on a per-item attribute scan (setupItem) for
	everything that arrives afterward via DescendantAdded. That API is not
	guaranteed available here, so the initial sweep uses the SAME per-item
	scan as the ongoing one (GetDescendants() once, then setupItem per
	instance) instead of six separate selector queries -- behavior-identical
	as far as which instances get which behavior, just one code path instead
	of two.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local DataController = require(script.Parent.Parent.DataController)
local Format = require(ReplicatedStorage.Shared.UISystem.Format)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local Log = require(ReplicatedStorage.Shared.Log)
local MonetizationController = require(script.Parent.MonetizationController)
local SoundKit = require(ReplicatedStorage.Shared.AssetIds.SoundKit)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)
local UISignals = require(script.Parent.Parent.Parent.UI.UISystem.UISignals)

local log = Log.new("UIKitController")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local TWEEN_DURATION = 0.2
local BLUR_SIZE = 50
local FOV_OPEN = 50
local FOV_CLOSE = 70
local SHOP_SCROLL_BOTTOM_PADDING = 15

local blur = Instance.new("BlurEffect")
blur.Name = "UIKitBlur"
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting

local currentFrame: Frames.FrameName? = nil
local currentFrameUsesBlur = false
local promptOverlayOpen = false
local activeBlurTween: Tween? = nil
local activeFovTween: Tween? = nil
local frameTransitionIds: { [GuiObject]: number } = {}

local UIKitController = {}

local function attributeString(item: Instance, name: string): string?
	local value = item:GetAttribute(name)
	if type(value) ~= "string" then
		return nil
	end
	return value
end

local function attributeNumber(item: Instance, name: string): number?
	local value = item:GetAttribute(name)
	if type(value) ~= "number" then
		return nil
	end
	return value
end

-- Built once per decorated item and replayed on every hover/click, so the
-- entry's head trim has to be a playback region rather than a per-play seek --
-- see AssetIds/SoundKit. Non-spatial (SoundKit.Profiles.UI): `item` is a
-- GuiObject, not a BasePart, so no RollOff* property would mean anything.
local function makeSound(item: Instance, entry: Sounds.Entry): Sound
	local sound = Instance.new("Sound")
	SoundKit.apply(sound, entry)
	SoundKit.applyProfile(sound, SoundKit.Profiles.UI)
	sound.SoundGroup = SoundKit.getSoundGroup("SFX")
	sound.Parent = item
	return sound
end

local function tweenBlur(targetSize: number, targetFov: number)
	local previousBlurTween = activeBlurTween
	activeBlurTween = nil
	if previousBlurTween ~= nil then
		previousBlurTween:Cancel()
	end
	local previousFovTween = activeFovTween
	activeFovTween = nil
	if previousFovTween ~= nil then
		previousFovTween:Cancel()
	end

	blur.Enabled = true

	local blurTween =
		TweenService:Create(blur, TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad), { Size = targetSize })
	local fovTween =
		TweenService:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { FieldOfView = targetFov })
	activeBlurTween = blurTween
	activeFovTween = fovTween

	blurTween.Completed:Once(function()
		if activeBlurTween ~= blurTween then
			return
		end
		activeBlurTween = nil
		if targetSize == 0 then
			blur.Enabled = false
		end
	end)
	fovTween.Completed:Once(function()
		if activeFovTween == fovTween then
			activeFovTween = nil
		end
	end)

	blurTween:Play()
	fovTween:Play()
end

local function refreshWorldEffects()
	local shouldBlur = promptOverlayOpen or (currentFrame ~= nil and currentFrameUsesBlur)
	tweenBlur(if shouldBlur then BLUR_SIZE else 0, if shouldBlur then FOV_OPEN else FOV_CLOSE)
end

local function nextFrameTransition(frame: GuiObject): number
	local transitionId = (frameTransitionIds[frame] or 0) + 1
	frameTransitionIds[frame] = transitionId
	return transitionId
end

local function scaleUDim2(u: UDim2, rate: number): UDim2
	return UDim2.new(u.X.Scale * rate, u.X.Offset * rate, u.Y.Scale * rate, u.Y.Offset * rate)
end

local function cacheOriginalSize(item: GuiObject)
	if item:GetAttribute("OriginalSize") == nil then
		item:SetAttribute("OriginalSize", item.Size)
	end
end

local function backgroundScroll(item: GuiObject, axis: "X" | "Y")
	if not item:IsA("ImageLabel") then
		return
	end

	local rate = attributeNumber(item, "Ui-Effect-Rate")
	if rate == nil or rate == 0 then
		return
	end

	local delay = attributeNumber(item, "Ui-Effect-Delay") or 0
	local tileSize = if axis == "Y" then item.TileSize.Y.Offset else item.TileSize.X.Offset
	local originPos = item.Position

	if axis == "Y" then
		item.Size += UDim2.fromOffset(0, tileSize * 3)
	else
		item.Size += UDim2.fromOffset(tileSize * 3, 0)
	end

	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		if item.Parent == nil then
			connection:Disconnect()
			return
		end

		local t = Workspace:GetServerTimeNow() + delay
		local alpha = (t / math.abs(rate)) % 1
		local offset = alpha * tileSize * (if rate < 0 then -1 else 1)

		if axis == "Y" then
			item.Position = originPos + UDim2.fromOffset(0, offset - tileSize)
		else
			item.Position = originPos + UDim2.fromOffset(offset - tileSize, 0)
		end
	end)
end

local function resolveFloatTiming(item: GuiObject, authoredSpeed: number, authoredDelay: number): (number, number)
	local ancestor: Instance? = item.Parent
	while ancestor ~= nil do
		if ancestor:GetAttribute("Ui-Float-Sync") == true then
			local syncedSpeed = attributeNumber(ancestor, "Ui-Float-Speed") or authoredSpeed
			local syncedDelay = attributeNumber(ancestor, "Ui-Float-Delay") or 0
			return math.max(syncedSpeed, 0.01), syncedDelay
		end
		ancestor = ancestor.Parent
	end

	return math.max(authoredSpeed, 0.01), authoredDelay
end

-- Ui-Effect handlers. Each reads whatever Ui-Effect-* attributes it needs
-- directly off `item` -- the source never routed a shared "rate" through
-- this group (only Scale/Hover/Click do that), so neither does this port.
local Effects: { [string]: (GuiObject) -> () } = {
	Shake = function(item)
		local rate = attributeNumber(item, "Ui-Effect-Rate") or 1
		local angle = (math.abs(rate) - 1) * 90
		item.Rotation = -angle

		local tween = TweenService:Create(
			item,
			TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true),
			{ Rotation = angle }
		)

		local delay = attributeNumber(item, "Ui-Effect-Delay")
		if delay ~= nil then
			task.delay(delay, function()
				tween:Play()
			end)
		else
			tween:Play()
		end
	end,

	Spin = function(item)
		local tween = TweenService:Create(
			item,
			TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
			{ Rotation = 360 }
		)
		tween:Play()

		local delay = attributeNumber(item, "Ui-Effect-Delay")
		if delay ~= nil and delay ~= 0 then
			tween.TimePosition = Workspace:GetServerTimeNow() % delay
		end
	end,

	Float = function(item)
		local rate = attributeNumber(item, "Ui-Effect-Rate") or 6
		local authoredDelay = attributeNumber(item, "Ui-Effect-Delay") or 0
		local authoredSpeed = attributeNumber(item, "Ui-Effect-Speed") or 2
		local speed, delay = resolveFloatTiming(item, authoredSpeed, authoredDelay)
		local originPos = item.Position
		local period = speed * 2

		-- Derive the position from the shared server clock instead of starting
		-- an independent tween per icon. Items with the same speed/delay now
		-- stay phase-locked even if their controllers initialize on different
		-- frames or they stream in later.
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			if item.Parent == nil then
				connection:Disconnect()
				return
			end

			local cycle = (Workspace:GetServerTimeNow() - delay) % period
			local alpha = if cycle <= speed then cycle / speed else (period - cycle) / speed
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			item.Position = originPos + UDim2.fromOffset(0, rate * eased)
		end)
	end,

	Bg_Y = function(item)
		backgroundScroll(item, "Y")
	end,
	Bg_X = function(item)
		backgroundScroll(item, "X")
	end,

	Shine = function(item)
		if not item:IsA("ImageLabel") then
			return
		end

		local assets = ReplicatedStorage:WaitForChild("Assets")
		local shineTemplate = assets:WaitForChild("Shine")
		local shine = shineTemplate:Clone() :: GuiObject
		shine.Position = UDim2.fromScale(0, 0.5)
		shine.AnchorPoint = Vector2.new(1, 0.5)
		shine.Parent = item

		local rate = attributeNumber(item, "Ui-Effect-Rate") or 1
		TweenService:Create(
			shine,
			TweenInfo.new(rate, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true, 5),
			{ Position = UDim2.fromScale(1, 0.5), AnchorPoint = Vector2.new(0, 0.5) }
		):Play()
	end,
}

local Scale: { [string]: (GuiObject, number?) -> () } = {
	ImageTileScale = function(item, rate)
		if not item:IsA("ImageLabel") then
			return
		end
		local parent = item.Parent
		if parent == nil or not parent:IsA("GuiObject") then
			return
		end
		local divisor = rate or 1

		local function update()
			-- Hidden/template UI can report an AbsoluteSize of zero while it is
			-- being laid out. TileSize rejects zero dimensions, so keep the
			-- temporary value valid until the next AbsoluteSize update.
			local tileSize = math.max((parent :: GuiObject).AbsoluteSize.X / divisor, 1)
			item.TileSize = UDim2.fromOffset(tileSize, tileSize)
		end

		parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
		update()
	end,
}

local HoverEffects: { [string]: (GuiObject, number?) -> () } = {
	Expand = function(item, rate)
		cacheOriginalSize(item)
		local original = item:GetAttribute("OriginalSize")
		if typeof(original) ~= "UDim2" then
			return
		end
		local expandRate = rate or 1.1

		item.MouseEnter:Connect(function()
			item:TweenSize(scaleUDim2(original, expandRate), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.1, true)
		end)
		item.MouseLeave:Connect(function()
			item:TweenSize(original, Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.1, true)
		end)
	end,

	ExpandReveal = function(item, rate)
		local parent = item.Parent
		if parent == nil then
			return
		end

		local targetName = attributeString(item, "Ui-Hover-Target")
		local labelName = attributeString(item, "Ui-Hover-Label")
		if targetName == nil or labelName == nil then
			return
		end

		local target = parent:FindFirstChild(targetName)
		local label = parent:FindFirstChild(labelName)
		if target == nil or not target:IsA("GuiObject") or label == nil or not label:IsA("TextLabel") then
			return
		end

		cacheOriginalSize(target)
		local originalSize = target:GetAttribute("OriginalSize")
		if typeof(originalSize) ~= "UDim2" then
			return
		end

		local expandRate = rate or 1.08
		local originalZIndex = target.ZIndex
		local labelStroke = label:FindFirstChildOfClass("UIStroke")
		local revealId = 0

		label.Visible = false
		label.TextTransparency = 1
		if labelStroke ~= nil then
			labelStroke.Transparency = 1
		end

		item.MouseEnter:Connect(function()
			revealId += 1
			target.ZIndex = math.max(originalZIndex, label.ZIndex + 1)
			target:TweenSize(
				scaleUDim2(originalSize, expandRate),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.1,
				true
			)

			label.Visible = true
			TweenService:Create(
				label,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextTransparency = 0 }
			):Play()
			if labelStroke ~= nil then
				TweenService:Create(
					labelStroke,
					TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Transparency = 0 }
				):Play()
			end
		end)

		item.MouseLeave:Connect(function()
			revealId += 1
			local thisRevealId = revealId
			target.ZIndex = originalZIndex
			target:TweenSize(originalSize, Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.1, true)

			TweenService:Create(
				label,
				TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextTransparency = 1 }
			):Play()
			if labelStroke ~= nil then
				TweenService:Create(
					labelStroke,
					TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Transparency = 1 }
				):Play()
			end

			task.delay(0.08, function()
				if revealId == thisRevealId then
					label.Visible = false
				end
			end)
		end)
	end,
}

local ClickEffects: { [string]: (GuiObject, number?) -> () } = {
	In = function(item, rate)
		if not item:IsA("GuiButton") then
			return
		end
		cacheOriginalSize(item)
		local original = item:GetAttribute("OriginalSize")
		if typeof(original) ~= "UDim2" then
			return
		end
		local clickRate = rate or 0.9

		item.MouseButton1Click:Connect(function()
			item:TweenSize(scaleUDim2(original, clickRate), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.1, true)
			task.delay(0.1, function()
				item:TweenSize(original, Enum.EasingDirection.Out, Enum.EasingStyle.Bounce, 0.2, true)
			end)
		end)
	end,
}

local HoverSounds: { [string]: (GuiObject) -> () } = {
	Default = function(item)
		local sound = makeSound(item, Sounds.UiHover)
		item.MouseEnter:Connect(function()
			sound:Play()
		end)
	end,
}

local ClickSounds: { [string]: (GuiObject) -> () } = {
	Default = function(item)
		if not item:IsA("GuiButton") then
			return
		end
		local sound = makeSound(item, Sounds.UiClick)
		item.MouseButton1Click:Connect(function()
			sound:Play()
		end)
	end,

	UiClose = function(item)
		if not item:IsA("GuiButton") then
			return
		end
		local sound = makeSound(item, Sounds.UiClose)
		item.MouseButton1Click:Connect(function()
			sound:Play()
		end)
	end,

	Money = function(item)
		if not item:IsA("GuiButton") then
			return
		end
		local sound = makeSound(item, Sounds.UiMoney)
		item.MouseButton1Click:Connect(function()
			sound:Play()
		end)
	end,
}

--[[
	Marketplace attribute handlers. `item` is cast to `any` at the .Text
	assignment sites only (TextLabel and TextButton both have `.Text`, but
	Luau has no structural "anything with a Text property" type to spell
	that with) -- a narrow, local cast, not a spread one.
]]
local MarketplaceAttrs: { [string]: (GuiObject, string) -> () } = {
	["Ui-Product"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetProductButton(item, value)
		end
	end,

	["Ui-Product-Robux"] = function(item, value)
		local price = MonetizationController.GetPrice("Product", value)
		local textItem = item :: any
		local prefix = attributeString(item, "Ui-Price-Prefix") or (utf8.char(0xE002) .. " ")
		local suffix = attributeString(item, "Ui-Price-Suffix") or ""
		textItem.Text = prefix .. tostring(price or "?") .. suffix
	end,

	["Ui-Pass"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetPassButton(item, value)
		end
	end,

	["Ui-Pass-Robux"] = function(item, value)
		local price = MonetizationController.GetPrice("Pass", value)
		local textItem = item :: any
		local prefix = attributeString(item, "Ui-Price-Prefix") or (utf8.char(0xE002) .. " ")
		local suffix = attributeString(item, "Ui-Price-Suffix") or ""
		textItem.Text = prefix .. tostring(price or "?") .. suffix
	end,

	["Ui-Gift-Pass"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetPassGiftButton(item, value)
		end
	end,

	["Ui-Gift-Product"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetProductGiftButton(item, value)
		end
	end,

	["Ui-Gift-Pack"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetPackGiftButton(item, value)
		end
	end,

	["Ui-Pack"] = function(item, value)
		if item:IsA("GuiButton") then
			MonetizationController.SetPackButton(item, value)
		end
	end,

	["Ui-Pack-Robux"] = function(item, value)
		local price = MonetizationController.GetPrice("Pack", value)
		local textItem = item :: any
		local prefix = attributeString(item, "Ui-Price-Prefix") or (utf8.char(0xE002) .. " ")
		local suffix = attributeString(item, "Ui-Price-Suffix") or ""
		textItem.Text = prefix .. tostring(price or "?") .. suffix
	end,
}

local function applyFrameToggle(item: GuiButton)
	local target = attributeString(item, "Ui-Frame")
	if target == nil or not Frames.isFrameName(target) then
		if target ~= nil then
			log.warn(`{item:GetFullName()}.Ui-Frame = "{target}" is not a known frame name -- ignoring`)
		end
		return
	end
	local frameTarget = target :: Frames.FrameName

	item.MouseButton1Click:Connect(function()
		if currentFrame == frameTarget then
			UIKitController.CloseCurrentFrame(true)
		else
			UIKitController.OpenFrame(frameTarget)
		end
	end)
end

local function applyCloseButton(item: GuiButton)
	item.MouseButton1Click:Connect(function()
		UIKitController.CloseCurrentFrame(true)
	end)
end

--[[
	Applies every Ui-* behavior an instance is tagged with. Called once per
	instance already present at Start(), and once per instance that shows up
	afterward via PlayerGui.DescendantAdded -- the source's setupItem, minus
	the QueryDescendants-driven duplicate initial pass (see header).
]]
local function setupItem(item: Instance)
	if not item:IsA("GuiObject") then
		return
	end

	local effectKey = attributeString(item, "Ui-Effect")
	if effectKey ~= nil then
		local handler = Effects[effectKey]
		if handler ~= nil then
			handler(item)
		end
	end

	local scaleKey = attributeString(item, "Ui-Scale")
	if scaleKey ~= nil then
		local handler = Scale[scaleKey]
		if handler ~= nil then
			handler(item, attributeNumber(item, "Ui-Scale-Rate"))
		end
	end

	local hoverKey = attributeString(item, "Ui-Hover")
	if hoverKey ~= nil then
		local handler = HoverEffects[hoverKey]
		if handler ~= nil then
			handler(item, attributeNumber(item, "Ui-Hover-Rate"))
		end
	end

	local clickKey = attributeString(item, "Ui-Click")
	if clickKey ~= nil then
		local handler = ClickEffects[clickKey]
		if handler ~= nil then
			handler(item, attributeNumber(item, "Ui-Click-Rate"))
		end
	end

	local hoverSoundKey = attributeString(item, "Ui-Hover-Sound")
	if hoverSoundKey ~= nil then
		local handler = HoverSounds[hoverSoundKey]
		if handler ~= nil then
			handler(item)
		end
	end

	local clickSoundKey = attributeString(item, "Ui-Click-Sound")
	if clickSoundKey ~= nil then
		local handler = ClickSounds[clickSoundKey]
		if handler ~= nil then
			handler(item)
		end
	end

	for attr, handler in MarketplaceAttrs do
		local value = attributeString(item, attr)
		if value ~= nil then
			handler(item, value)
		end
	end

	if item:IsA("GuiButton") then
		if item:GetAttribute("Ui-Frame") ~= nil then
			applyFrameToggle(item)
		end
		if item:GetAttribute("Ui-Close") ~= nil then
			applyCloseButton(item)
		end
	end
end

function UIKitController.CloseCurrentFrame(tween: boolean)
	if currentFrame == nil then
		return
	end

	local closingFrameName = currentFrame
	local frame = Frames.get(closingFrameName)
	currentFrame = nil
	currentFrameUsesBlur = false
	local transitionId = nextFrameTransition(frame)

	if tween then
		frame:TweenPosition(
			UDim2.fromScale(frame.Position.X.Scale, 0.6),
			Enum.EasingDirection.In,
			Enum.EasingStyle.Quad,
			TWEEN_DURATION,
			true
		)
		task.delay(TWEEN_DURATION, function()
			if frameTransitionIds[frame] == transitionId and currentFrame ~= closingFrameName then
				frame.Visible = false
			end
		end)
	else
		frame.Visible = false
	end
	refreshWorldEffects()
end

function UIKitController.OpenFrame(frameName: Frames.FrameName, noBlur: boolean?)
	if currentFrame == frameName then
		return
	end

	UIKitController.CloseCurrentFrame(false)

	local frame = Frames.get(frameName)
	nextFrameTransition(frame)
	frame.Position = UDim2.fromScale(frame.Position.X.Scale, 0.6)
	frame.Visible = true
	frame:TweenPosition(
		UDim2.fromScale(frame.Position.X.Scale, 0.5),
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Quad,
		TWEEN_DURATION,
		true
	)
	currentFrame = frameName
	currentFrameUsesBlur = not noBlur
	refreshWorldEffects()
end

-- Shared HUD counter driver for Cash and Theme Tickets. `numberPrefix` lets
-- the Cash counter and its transaction badges show "$" without leaking that
-- currency symbol into the otherwise-identical Tickets UI.
local function initCounterDisplay(
	holderName: string,
	labelName: string,
	path: { string | number },
	numberPrefix: string?
)
	local main = playerGui:WaitForChild("Main")
	local hud = main:WaitForChild("HUD")
	local holder = hud:WaitForChild(holderName)
	local counterLabel = holder:WaitForChild(labelName)
	local mainLabel = counterLabel:WaitForChild("main") :: TextLabel
	local shadowLabel = counterLabel:WaitForChild("shadow") :: TextLabel
	local transactionRoot = mainLabel:WaitForChild("Transactions")
	local addTemplate = transactionRoot:WaitForChild("Add") :: Frame
	local subTemplate = transactionRoot:WaitForChild("Subtract") :: Frame
	addTemplate.Parent = nil
	subTemplate.Parent = nil

	local activeRender: RBXScriptConnection? = nil
	local prefix = numberPrefix or ""

	local function setCounterLabel(amount: number)
		local formatted = prefix .. Format.FormatNumber(amount)
		mainLabel.Text = formatted
		shadowLabel.Text = formatted
	end

	local function tweenCounterValue(from: number, to: number, duration: number)
		if activeRender ~= nil then
			activeRender:Disconnect()
			activeRender = nil
		end

		local startTime = os.clock()
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
			setCounterLabel(math.floor(from + (to - from) * alpha))

			if alpha >= 1 then
				setCounterLabel(to)
				connection:Disconnect()
				if activeRender == connection then
					activeRender = nil
				end
			end
		end)
		activeRender = connection
	end

	local function showTransactionBadge(amount: number)
		local template = if amount > 0 then addTemplate else subTemplate
		local badge = template:Clone()
		badge.Visible = true
		badge.Parent = transactionRoot

		local originalSize = badge.Size
		badge.Size = UDim2.new(originalSize.X.Scale, originalSize.X.Offset, 0, 0)

		local sign = if amount > 0 then "+" else "-"
		local formatted = sign .. prefix .. Format.FormatNumber(math.abs(amount))
		local badgeMain = badge:WaitForChild("main") :: TextLabel
		local badgeShadow = badge:WaitForChild("shadow") :: TextLabel
		badgeMain.Text = formatted
		badgeShadow.Text = formatted

		local openInfo = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		local closeInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local collapsed = UDim2.new(originalSize.X.Scale, originalSize.X.Offset, 0, 0)

		local openTween = TweenService:Create(badge, openInfo, { Size = originalSize })
		openTween:Play()
		openTween.Completed:Wait()

		task.wait(2)

		local closeTween = TweenService:Create(badge, closeInfo, { Size = collapsed })
		closeTween:Play()
		closeTween.Completed:Wait()

		badge:Destroy()
	end

	DataController.observe(path, function(value: any, old: any?)
		if type(value) ~= "number" then
			return
		end
		if type(old) ~= "number" then
			-- First fire (old == nil): set immediately, no transaction badge
			-- for "the value we started with".
			setCounterLabel(value)
			return
		end

		local diff = value - old
		if diff == 0 then
			return
		end

		task.spawn(showTransactionBadge, diff)
		tweenCounterValue(old, value, 0.5)
	end)
end

local function initShopScrollBounds()
	local mainGui = playerGui:WaitForChild("Main")
	local frames = mainGui:WaitForChild("Frames")
	local shop = frames:WaitForChild("Shop")
	local scrolling = shop:WaitForChild("MainScrollingFrame")
	if not scrolling:IsA("ScrollingFrame") then
		log.warn("Shop.MainScrollingFrame is not a ScrollingFrame")
		return
	end

	local holder = scrolling:WaitForChild("Holder")
	local layout = holder:FindFirstChildOfClass("UIListLayout")
	if layout == nil then
		log.warn("Shop.MainScrollingFrame.Holder has no UIListLayout")
		return
	end

	-- The authored canvas is intentionally tall because the card heights use
	-- scale values relative to it. Shrinking CanvasSize would also shrink every
	-- shop card, so keep that layout canvas and clamp the user's scroll range
	-- to the actual visible content instead.
	scrolling.ElasticBehavior = Enum.ElasticBehavior.Never
	local isClamping = false
	local function clampToContent()
		if isClamping then
			return
		end

		local maxY =
			math.max(0, layout.AbsoluteContentSize.Y - scrolling.AbsoluteWindowSize.Y + SHOP_SCROLL_BOTTOM_PADDING)
		local current = scrolling.CanvasPosition
		local clampedY = math.clamp(current.Y, 0, maxY)
		if math.abs(clampedY - current.Y) < 0.01 then
			return
		end

		isClamping = true
		scrolling.CanvasPosition = Vector2.new(current.X, clampedY)
		isClamping = false
	end

	scrolling:GetPropertyChangedSignal("CanvasPosition"):Connect(clampToContent)
	scrolling:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(clampToContent)
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(clampToContent)
	clampToContent()
end

--[[
	Loading-screen handshake. LoadingScreen.client.luau runs in
	ReplicatedFirst, before any Controller exists, so it cannot require this
	module -- it signals intent by setting an attribute on the
	ReplicatedFirst service itself (persists regardless of read/write
	ordering, unlike a bare signal fire, which a listener that connects too
	late would simply miss). See LoadingScreen.client.luau's own comment.
]]
local function watchLoadingScreenHandshake()
	local ReplicatedFirst = game:GetService("ReplicatedFirst")
	local ATTRIBUTE = "UISystemOpenFrame"

	local function consume()
		local value = ReplicatedFirst:GetAttribute(ATTRIBUTE)
		if type(value) ~= "string" or not Frames.isFrameName(value) then
			return
		end
		UIKitController.OpenFrame(value :: Frames.FrameName)
	end

	if ReplicatedFirst:GetAttribute(ATTRIBUTE) ~= nil then
		consume()
		return
	end

	local connection: RBXScriptConnection
	connection = ReplicatedFirst:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
		connection:Disconnect()
		consume()
	end)
end

function UIKitController.Init()
	-- Registered before the initial sweep in Start() runs, so nothing that
	-- arrives in the gap between Init and Start's first line is missed.
	playerGui.DescendantAdded:Connect(function(item)
		task.spawn(setupItem, item)
	end)

	UISignals.OpenFrame.Connect(function(frameName, noBlur)
		if not Frames.isFrameName(frameName) then
			log.warn(`UISignals.OpenFrame fired with unknown frame name "{frameName}" -- ignoring`)
			return
		end
		UIKitController.OpenFrame(frameName, noBlur)
	end)

	UISignals.CloseFrame.Connect(function(tween)
		UIKitController.CloseCurrentFrame(tween)
	end)

	UISignals.PromptVisibilityChanged.Connect(function(isOpen)
		promptOverlayOpen = isOpen
		refreshWorldEffects()
	end)
end

function UIKitController.Start()
	for _, item in playerGui:GetDescendants() do
		setupItem(item)
	end

	initShopScrollBounds()
	initCounterDisplay("Left", "Cash", { "Coins" }, "$")
	initCounterDisplay("Right", "Tickets", { "UISystem", "Tickets" })
	watchLoadingScreenHandshake()

	log.info("ready")
end

return UIKitController
