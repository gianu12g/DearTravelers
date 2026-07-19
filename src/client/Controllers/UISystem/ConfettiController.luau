--!strict
--[[
	Confetti burst effect. Ported from the source's
	Controllers/ConffetiController.luau -- typo fixed everywhere, including
	the packet name (Conffeti.Emit -> Net.confettiEmit, PORT-SPEC.md §5.4).

	Clones ReplicatedStorage.Assets.Confetti onto the character's
	PrimaryPart and auto-destroys after 5s, same as the source.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("ConfettiController")

local player = Players.LocalPlayer

local ConfettiController = {}

local function emit()
	local character = player.Character or player.CharacterAdded:Wait()
	local primaryPart = character.PrimaryPart
	if primaryPart == nil then
		log.warn(`{character.Name} has no PrimaryPart -- cannot emit confetti`)
		return
	end

	local assets = ReplicatedStorage:WaitForChild("Assets")
	local template = assets:WaitForChild("Confetti")
	local clone = template:Clone()
	if not clone:IsA("BasePart") then
		log.warn(`Assets.Confetti is a {clone.ClassName}, expected a BasePart`)
		clone:Destroy()
		return
	end

	clone.CFrame = primaryPart:GetPivot()
	clone.Parent = primaryPart

	for _, emitter in clone:GetChildren() do
		if emitter:IsA("ParticleEmitter") then
			local count = emitter:GetAttribute("EmitCount")
			emitter:Emit(if type(count) == "number" then count else 100)
		end
	end

	task.delay(5, function()
		clone:Destroy()
	end)
end

function ConfettiController.Init()
	-- confettiEmit is an unsolicited server push (a reward moment, not a
	-- reply to anything this client asked for), so the listener is
	-- registered here rather than Start() -- the same reasoning
	-- DataController.OnNew documents for Replica.
	Net.confettiEmit.listen(function()
		emit()
	end)
end

return ConfettiController
