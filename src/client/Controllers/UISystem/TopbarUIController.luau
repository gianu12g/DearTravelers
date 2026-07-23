--!strict
--[[
	One topbar icon that opens the Settings frame. Ported from the source's
	Controllers/TopbarController.luau (18 lines).

	The source used a vendored `Icon` package (ReplicatedStorage.Packages
	.Icon); this repo has no such vendored package, only the Wally
	TopbarPlus dependency already used by DevConsoleController
	(ReplicatedStorage.Packages.TopbarPlus, wally.toml) -- an
	API-compatible family (PORT-SPEC.md §4), so the call shape below is
	unchanged from the source, just re-pointed.

	TopbarPlus's own module is `--!nonstrict` and its returned Icon objects
	have no exported strict type surface DevConsoleController relies on
	either (it types its own icon local as `any`) -- matched here for the
	same reason: this is a narrow, documented boundary with one third-party
	package, not `any` spreading through this module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icon = require(ReplicatedStorage.Packages.TopbarPlus)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local Log = require(ReplicatedStorage.Shared.Log)
local UIKitController = require(script.Parent.UIKitController)

local log = Log.new("TopbarUIController")

local TOPBAR_IMAGE = Images.TopbarSettings

local TopbarUIController = {}

function TopbarUIController.Start()
	-- Split from the source's method-chain-off-a-call-result (quality-gate.md):
	-- Icon.new() goes to a temp local, then each setter is its own statement.
	local icon: any = Icon.new()
	icon:setImage(TOPBAR_IMAGE)
	icon:setImageScale(0.8)
	icon:setImageRatio(1)
	icon:align("Right")
	icon:bindEvent("toggled", function()
		UIKitController.OpenFrame("Settings")
	end)

	log.info("ready")
end

return TopbarUIController
