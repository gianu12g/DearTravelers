--!strict
--[[
	Fires an authored one-shot VFX pack: a tree of DISABLED ParticleEmitters,
	each carrying its own `EmitCount` (and optional `EmitDelay`) attribute
	written by whoever authored the effect in Studio.

	Authoring the counts as attributes rather than in code is what lets an
	artist retime a burst without a code change, and keeping every emitter
	disabled is what makes it a one-shot rather than something that keeps
	emitting for as long as the clone is parented.

	Call this on the CLIENT, on a clone you just parented. ParticleEmitter:Emit()
	is a transient request, not replicated state, so a server calling it on a
	fresh clone races replication -- observers can receive the clone after the
	burst already happened. The server broadcasts only when/where; each client
	clones and emits locally.

		local burst = template:Clone()
		burst.Parent = Workspace
		Debris:AddItem(burst, AuthoredVfx.emitBurst(burst) + LINGER)
]]

local AuthoredVfx = {}

--[[
	Emits every authored emitter under `root` (and `root` itself if it is one),
	returning how long the longest particle stays alive -- delay included -- so
	the caller can schedule cleanup without hardcoding a lifetime that outlives
	or truncates the effect.

	Returns 0 when nothing was emitted, which is what a tree with no EmitCount
	attributes looks like: usually a template authored without them rather than
	a deliberate no-op.
]]
function AuthoredVfx.emitBurst(root: Instance): number
	local longestLifetime = 0
	for _, descendant in root:GetDescendants() do
		if not descendant:IsA("ParticleEmitter") then
			continue
		end

		-- `countAttribute ~= countAttribute` is the NaN test: NaN is a number,
		-- and math.floor(NaN) stays NaN, so a plain type check lets it through
		-- into Emit().
		local countAttribute = descendant:GetAttribute("EmitCount")
		if type(countAttribute) ~= "number" or countAttribute ~= countAttribute then
			continue
		end
		local count = math.max(0, math.floor(countAttribute))
		if count == 0 then
			continue
		end

		local delayAttribute = descendant:GetAttribute("EmitDelay")
		local emitDelay = if type(delayAttribute) == "number" and delayAttribute == delayAttribute
			then math.max(0, delayAttribute)
			else 0
		longestLifetime = math.max(longestLifetime, emitDelay + descendant.Lifetime.Max)

		if emitDelay == 0 then
			descendant:Emit(count)
		else
			local emitter = descendant
			task.delay(emitDelay, function()
				-- The clone may already have been cleaned up by whoever owns
				-- its lifetime; emitting into a destroyed tree is harmless but
				-- pointless, and this also drops the upvalue sooner.
				if emitter.Parent ~= nil then
					emitter:Emit(count)
				end
			end)
		end
	end

	return longestLifetime
end

return AuthoredVfx
