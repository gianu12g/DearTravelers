--!strict
--[[
	Client-side keyboard interaction for every MeshPart tagged `Key`.

	Each key receives a random letter plus the color and material configured by
	the theme named in its `Theme` attribute. A missing or invalid Theme is
	normalized to ChocolateBar. Attribute changes are observed so themes can be
	swapped while the game is running.

	Each key's base part (key.Parent.Parent, the BasePart under KeyCaps) is
	also tinted with the theme's Colors[1] (the anchor/darkest color) by
	reading the same `Theme` attribute CosmeticsService stamps on the base --
	this side is read-only on the client, since the server is the attribute's
	only writer. Bases are tracked separately from keys so a base with many
	keys gets exactly one attribute connection, torn down and its original
	color restored once its last key is untagged.

	Press detection follows the local player's HumanoidRootPart every frame. All
	motion, UI, color selection, and audio are local-only. Sounds are created per
	press and destroyed after playback, so keys need no child Sound instances and
	overlapping presses never cut each other off.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Appearance = require(script.Appearance)
local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local KeyTracking = require(script.KeyTracking)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("LightUpKeysController")

local KEY_TAG = CosmeticsCatalog.KEY_TAG

local LightUpKeysController = {}

-- See Appearance.getThemeColors for the doc comment.
LightUpKeysController.getThemeColors = Appearance.getThemeColors

function LightUpKeysController.Init()
	CollectionService:GetInstanceAddedSignal(KEY_TAG):Connect(KeyTracking.wireKey)
	CollectionService:GetInstanceRemovedSignal(KEY_TAG):Connect(KeyTracking.unwireKey)

	for _, instance in CollectionService:GetTagged(KEY_TAG) do
		KeyTracking.wireKey(instance)
	end

	Appearance.warnCosmeticsCatalogDrift()

	RunService.Heartbeat:Connect(KeyTracking.updateKeys)
	log.info(`ready ({#CollectionService:GetTagged(KEY_TAG)} tagged instances)`)
end

return LightUpKeysController
