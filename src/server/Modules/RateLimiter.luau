--!strict
-- Per-player token buckets for client-originated actions. Payload typing stops
-- malformed packets; this module stops well-formed packets from becoming an
-- API, replication, or logging flood.

local Players = game:GetService("Players")

export type Limiter = {
	allow: (self: Limiter, player: Player, cost: number?) -> boolean,
	forget: (self: Limiter, player: Player) -> (),
}

type Bucket = {
	tokens: number,
	updatedAt: number,
}

local allLimiters: { [Limiter]: true } = {}

local RateLimiter = {}

function RateLimiter.new(tokensPerSecond: number, burst: number?): Limiter
	assert(tokensPerSecond > 0, "tokensPerSecond must be positive")
	local capacity = burst or math.max(1, tokensPerSecond)
	assert(capacity > 0, "burst must be positive")

	local buckets: { [Player]: Bucket } = {}
	local limiter = {} :: any

	function limiter:allow(player: Player, cost: number?): boolean
		if player.Parent ~= Players then
			return false
		end
		local requested = cost or 1
		if requested <= 0 then
			return false
		end

		local now = os.clock()
		local bucket = buckets[player]
		if bucket == nil then
			bucket = { tokens = capacity, updatedAt = now }
			buckets[player] = bucket
		else
			bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.updatedAt) * tokensPerSecond)
			bucket.updatedAt = now
		end

		if bucket.tokens < requested then
			return false
		end
		bucket.tokens -= requested
		return true
	end

	function limiter:forget(player: Player)
		buckets[player] = nil
	end

	allLimiters[limiter] = true
	return limiter :: Limiter
end

Players.PlayerRemoving:Connect(function(player: Player)
	for limiter in allLimiters do
		limiter:forget(player)
	end
end)

return RateLimiter
