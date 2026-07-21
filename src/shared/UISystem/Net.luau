--!strict
--[[
	Packet definitions for the ported UISystem feature set (gifting, daily /
	playtime / wheel-spin rewards, group reward, friend invites, redeem
	codes, settings, notifications + confetti).

	A SEPARATE ByteNet namespace from Shared/Net.luau ("Game") -- this one is
	"UISystem" -- so the two never collide and either half can be required
	independently. This is a plain module (name doesn't end in
	Service/Controller), so the Loader ignores it (ARCHITECTURE.md, Recipe
	3). Require it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMESPACE = "UISystem"

-- On the CLIENT this require yields until the server has created
-- ReplicatedStorage.BytenetStorage. That's ByteNet's own WaitForChild.
local ByteNet = require(ReplicatedStorage.Packages.ByteNet)

--[[
	Why this guard exists -- do not delete it.

	ByteNet waits for the BytenetStorage *folder*, but looks up the individual
	namespace with FindFirstChild, NOT WaitForChild
	(Packages/_Index/ffrostflame_bytenet@0.4.6/bytenet/src/replicated/values.luau).
	If our namespace's StringValue hasn't replicated yet, access() returns nil and
	defineNamespace immediately indexes it -> "attempt to index nil with 'read'".

	The folder existing does NOT imply our namespace inside it exists. That gap is
	the whole bug, and it only opens on a cold boot (Studio Play, or the first
	player into a fresh server), which is exactly when you'd blame something else.
]]
if RunService:IsClient() then
	local storage = ReplicatedStorage:WaitForChild("BytenetStorage")
	if storage:WaitForChild(NAMESPACE, 10) == nil then
		error(
			`[UISystem.Net] namespace "{NAMESPACE}" never replicated.\n`
				.. "The server never required Shared.UISystem.Net, so it never published the packet IDs.\n"
				.. "Fix: require it from any UISystem *Service (a require at file scope is enough).",
			0
		)
	end
end

--[[
	targetUserId is float64, not uint32 -- uint32 tops out around 4.3 billion,
	which real Roblox UserIds have already exceeded for newer accounts. float64
	represents every UserId Roblox can issue exactly (same reasoning as
	Shared/Net.luau's devSnapshot).

	ByteNet is event-only, so the source's RemoteFunction-style invokes
	(GroupReward.ClaimReward, WheelSpin.Spin, Codes.RedeemCode) become a
	request packet the client fires plus a matching result packet the server
	fires back -- the same request/response shape Shared/Net.luau already
	uses for devRequestSnapshot/devSnapshot.

	Empty-payload packets (promptStart, confettiEmit, friendClaim,
	groupClaimRequest, spinRequest) use ByteNet.nothing: the sender only
	needs to say "this happened", the recipient is already implicit (the
	firing player server-side, or the subscribed client client-side), so
	there is nothing to put in a struct.

	Server side validates every client packet (index bounds, string length
	caps, rate limits on spin/redeem) -- the client only ever ASKS.
]]
return ByteNet.defineNamespace(NAMESPACE, function()
	return {
		-- client -> server. Ask to gift an owned item to another player; the
		-- server is the sole authority on ownership/eligibility.
		giftStart = ByteNet.definePacket({
			value = ByteNet.struct({
				targetUserId = ByteNet.float64,
				itemKind = ByteNet.string,
				itemName = ByteNet.string,
			}),
		}),

		-- server -> client. Tells the recipient's client to open the native
		-- purchase/gift prompt the server already validated.
		promptStart = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- server -> client. Generic toast/banner push.
		notify = ByteNet.definePacket({
			value = ByteNet.struct({ kind = ByteNet.string, message = ByteNet.string }),
		}),

		-- server -> client. Fire the confetti burst effect.
		confettiEmit = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- client -> server. Claim a playtime-reward slot by index; the
		-- server re-checks elapsed playtime and claim state before paying
		-- out. Result is visible via the replicated ClaimedRewards table;
		-- rejection is surfaced via `notify`.
		playtimeClaim = ByteNet.definePacket({
			value = ByteNet.struct({ index = ByteNet.uint8 }),
		}),

		-- client -> server. Claim a daily-reward slot by index. Same
		-- re-validation and result-via-replication contract as
		-- playtimeClaim.
		dailyClaim = ByteNet.definePacket({
			value = ByteNet.struct({ index = ByteNet.uint8 }),
		}),

		-- client -> server. Claim the "invited N friends" reward.
		friendClaim = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- client -> server. Request half of the group-reward request/result
		-- pair: ask to claim the group-membership reward.
		groupClaimRequest = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- server -> client. Result half of the group-reward pair.
		groupClaimResult = ByteNet.definePacket({
			value = ByteNet.struct({ ok = ByteNet.bool }),
		}),

		-- client -> server. Request half of the wheel-spin pair: ask the
		-- server to spend a spin. The server rolls the reward -- the client
		-- never picks it.
		spinRequest = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- server -> client. Result half of the wheel-spin pair: the rolled
		-- reward index.
		spinResult = ByteNet.definePacket({
			value = ByteNet.struct({ rewardIndex = ByteNet.uint8 }),
		}),

		-- client -> server. Request half of the redeem-code pair.
		codeRedeemRequest = ByteNet.definePacket({
			value = ByteNet.struct({ code = ByteNet.string }),
		}),

		-- server -> client. Result half of the redeem-code pair.
		codeRedeemResult = ByteNet.definePacket({
			value = ByteNet.struct({ ok = ByteNet.bool, message = ByteNet.string }),
		}),

		-- client -> server. Update a settings volume slider. value is
		-- ALWAYS a number (Music/SFX/keyboard volume) -- unlike the source's
		-- Packet.Any, the wire type itself rules out any other payload
		-- shape reaching the server.
		settingUpdate = ByteNet.definePacket({
			value = ByteNet.struct({ key = ByteNet.string, value = ByteNet.float64 }),
		}),
	}
end)
