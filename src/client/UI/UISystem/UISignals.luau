--!strict
--[[
	Cross-controller UI pub/sub. Ported from the source's
	StarterPlayerScripts.Utils.GlobalSignals ("GlobalSignals.UI.OpenFrame" /
	".CloseFrame"), minus LemonSignal (PORT-SPEC.md §4 -- see Signal.luau
	next to this file) and minus the redundant ".UI" nesting: this whole
	module already lives under the UISystem namespace folder, so
	UISignals.OpenFrame reads the same as GlobalSignals.UI.OpenFrame did.

	Any controller can open/close a UIKitController frame by firing these
	without requiring UIKitController itself -- e.g. MarketplaceController's
	gifting flow opens "GiftConfirm" this way. UIKitController.Init() is the
	one listener that turns a fire into an actual OpenFrame/CloseCurrentFrame
	call.

	A plain module (name ends in neither Service nor Controller), so the
	Loader ignores it (ARCHITECTURE.md Recipe 3). Require it directly.
]]

local Signal = require(script.Parent.Signal)

export type OpenFrameSignal = Signal.Signal<string, boolean?>
export type CloseFrameSignal = Signal.Signal<boolean>

local UISignals = {
	-- (frameName, noBlur?)
	OpenFrame = Signal.new() :: OpenFrameSignal,
	-- (tween)
	CloseFrame = Signal.new() :: CloseFrameSignal,
}

return UISignals
