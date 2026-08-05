--!strict
--[[
	Packet definitions. ONE namespace, required by both sides.

	This is a plain module -- the name doesn't end in Service/Controller, so the
	Loader ignores it (ARCHITECTURE.md, Recipe 3). Require it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMESPACE = "Game"

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
			`[Net] namespace "{NAMESPACE}" never replicated.\n`
				.. "The server never required Shared.Net, so it never published the packet IDs.\n"
				.. "Fix: require it from any *Service (a require at file scope is enough).",
			0
		)
	end
end

--[[
	devSet/devSnapshot move values as `kind` (a type tag) plus a plain `string`,
	never as ByteNet.unknown. That is the whole point, not a stopgap: the wire
	type itself is then the guarantee. A struct typed {kind: string, value:
	string} can only ever deserialize into two scalars, so there is no encoding
	in which a nested table reaches DevService's validator to begin with --
	parseValue() there still bounds-checks the string, but the wire shape
	already rules out the dangerous shape.

	Every dev packet names its subject as `targetPlayer` -- a ByteNet.inst
	reference to the actual Player -- rather than as a UserId number. The console
	already HOLDS the instance (it picked it out of Players:GetPlayers()), so
	encoding it as a number purely so the server can look it back up with
	Players:GetPlayerByUserId adds a mapping that can fail while looking
	perfectly valid from the client: the reply for "no player has that id" and
	the reply for a stale id are the same, and the client has no way to tell
	which it hit. A reference has no such step.

	That is NOT a trust change. `inst` decodes to `Instance?` -- nil if the
	sender referenced something the server cannot see -- and a client may
	reference any instance it likes, so DevService still validates what it
	decoded (`IsA("Player")` plus a live `Players` parent) before treating it as
	a target. The reference removes a lookup, not a check.
]]
return ByteNet.defineNamespace(NAMESPACE, function()
	return {
		-- client -> server
		devRequestSnapshot = ByteNet.definePacket({
			value = ByteNet.struct({ targetPlayer = ByteNet.inst }),
		}),

		-- server -> client
		devSnapshot = ByteNet.definePacket({
			value = ByteNet.struct({
				targetPlayer = ByteNet.inst,
				entries = ByteNet.array(ByteNet.struct({
					path = ByteNet.array(ByteNet.string),
					kind = ByteNet.string,
					value = ByteNet.string,
				})),
			}),
		}),

		-- client -> server
		devSet = ByteNet.definePacket({
			value = ByteNet.struct({
				targetPlayer = ByteNet.inst,
				path = ByteNet.array(ByteNet.string),
				kind = ByteNet.string,
				value = ByteNet.string,
			}),
		}),

		--[[
			client -> server. Adds a SIGNED amount to one existing numeric field.

			This is not sugar over devSet. The console's "+10K coins" affordance
			has to know the current balance to send an absolute value, and the
			only balance it has is a snapshot up to SNAPSHOT_INTERVAL seconds old
			-- two quick clicks then both compute from the same stale number and
			the second silently erases the first. Sending the DELTA instead moves
			the read next to the write, on the server, where nothing can
			interleave between them.

			The path is validated exactly as devSet's is, and the field must
			already hold a number: this packet cannot create a key, cannot
			overwrite a container, and cannot change a field's type.
		]]
		devAdd = ByteNet.definePacket({
			value = ByteNet.struct({
				targetPlayer = ByteNet.inst,
				path = ByteNet.array(ByteNet.string),
				amount = ByteNet.float64,
			}),
		}),

		-- client -> server. Developer-only test action; DevService re-checks
		-- access and resolves the selected in-server player before damage is
		-- applied. The amount is intentionally server-owned, not client input.
		devDamageSquishies = ByteNet.definePacket({
			value = ByteNet.struct({ targetPlayer = ByteNet.inst }),
		}),

		--[[
			client -> server. Runs `count` immediate auto-spawn attempts on the
			target's pad instead of waiting SPAWN_INTERVAL for each.

			uint8 is not a size micro-optimisation: MAX_OBJECTS is 15, so the
			wire type itself already rules out a count that could spin the
			server's spawn loop, before DevService clamps it again.
		]]
		devSpawnSquishies = ByteNet.definePacket({
			value = ByteNet.struct({
				targetPlayer = ByteNet.inst,
				count = ByteNet.uint8,
			}),
		}),

		-- client -> server. Developer-only test action; removes every squishy the
		-- target owns. Same shape as devDamageSquishies -- the only client input
		-- is which in-server player to target.
		devClearSquishies = ByteNet.definePacket({
			value = ByteNet.struct({ targetPlayer = ByteNet.inst }),
		}),

		-- client -> server. Developer-only test action; grants every
		-- CosmeticsCatalog entry (all slots) to the selected in-server player,
		-- skipping ids they already own. Same shape as devDamageSquishies --
		-- the only client input is which in-server player to target.
		devGrantAllCosmetics = ByteNet.definePacket({
			value = ByteNet.struct({ targetPlayer = ByteNet.inst }),
		}),

		-- server -> client
		devResult = ByteNet.definePacket({
			value = ByteNet.struct({ ok = ByteNet.bool, message = ByteNet.string }),
		}),

		--[[
			server -> client. "Are you a developer?" -- answered BY the server,
			never computed by the client.

			This packet exists because ConfigService is server-only ("Attempting
			to call its methods from a client script results in an error"), so the
			client physically cannot read the developers list itself. It is not a
			trust boundary: `allowed` only decides whether the console UI is drawn.
			A client that forges it gains a UI and nothing else, because DevService
			re-checks authority on every privileged packet it receives. The client
			was never trusted before either -- it just used to compute the same
			answer locally instead of being told.

			Sent on join, and again to everyone whenever the config changes, which
			is what makes adding a UserId in the dashboard take effect live.
		]]
		devAccess = ByteNet.definePacket({
			value = ByteNet.struct({ allowed = ByteNet.bool }),
		}),

		--[[
			client -> server. "Tell me my access." No payload -- the server only
			needs to know WHO asked, and it gets that for free.

			This exists because a push alone races: the server learns a player
			joined before that player's LocalScripts have run, and a RemoteEvent
			fired at a client with no listener yet is simply dropped, not queued.
			A fresh joiner would silently never get a console. Asking from the
			client's own Start() -- by which point Init() has registered the
			listener -- is the one ordering that cannot lose the reply.
		]]
		devRequestAccess = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- client -> server. Requests one coin upgrade by its small whitelisted
		-- logical name. Current level, next value, price, rebirth gate and Coins
		-- balance are all resolved again by UpgradesService.
		upgradeRequest = ByteNet.definePacket({
			value = ByteNet.struct({ upgrade = ByteNet.string }),
		}),

		-- server -> requesting client. Replicated player data remains the source
		-- of truth; this reply clears the row's pending state and explains any
		-- rejected purchase.
		upgradeResult = ByteNet.definePacket({
			value = ByteNet.struct({
				ok = ByteNet.bool,
				upgrade = ByteNet.string,
				message = ByteNet.string,
			}),
		}),

		-- client -> server. Toggles only the sender's assigned base forcefield.
		-- No base name or desired state crosses the wire: BaseService resolves
		-- both from its authoritative assignment/current-state tables.
		baseLockRequest = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- server -> requesting client. Clears the button's pending state and
		-- surfaces validation/rate-limit failures without trusting the client to
		-- infer whether the authoritative toggle committed.
		baseLockResult = ByteNet.definePacket({
			value = ByteNet.struct({
				ok = ByteNet.bool,
				locked = ByteNet.bool,
				message = ByteNet.string,
			}),
		}),

		--[[
			client -> server. "Drop whatever I'm carrying." No payload -- the
			packet carries no position on purpose. MergeService computes the
			drop spot itself from the character's CURRENT position at the
			moment this arrives; trusting a client-sent coordinate would let
			someone drop (and therefore relocate) an object anywhere, on
			anyone's pad, from anywhere on the map.

			A no-op if the sender isn't carrying anything -- MergeService just
			returns, same as every other "not in the state this implies"
			packet in this file.
		]]
		mergeDropRequest = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		-- client -> server. Requests that the currently carried squishy be
		-- launched at one world X/Z point inside the map overview. The server
		-- bounds-checks it, resolves surface height, and owns damage.
		mergeLaunchRequest = ByteNet.definePacket({
			value = ByteNet.struct({
				worldX = ByteNet.float64,
				worldZ = ByteNet.float64,
			}),
		}),

		-- server -> requesting client. Keeps the map overview active after a
		-- rejected click, but releases it as soon as a launch is accepted.
		mergeLaunchResult = ByteNet.definePacket({
			value = ByteNet.struct({ ok = ByteNet.bool, message = ByteNet.string }),
		}),

		-- server -> every client. Tells each observer to clone and locally emit
		-- one authored launch VFX pack. ParticleEmitter:Emit() is a transient
		-- request, so firing it on a freshly-parented server clone can happen
		-- before that clone reaches clients. The server still owns the timing
		-- and position; clients own only the cosmetic particle rendering.
		mergeLaunchVfx = ByteNet.definePacket({
			value = ByteNet.struct({
				templateName = ByteNet.string,
				worldX = ByteNet.float64,
				worldY = ByteNet.float64,
				worldZ = ByteNet.float64,
			}),
		}),

		--[[
			server -> every client. One launch-sequence sound: mush materialize,
			touchdown thud, or explosion. Sent independently of mergeLaunchVfx on
			purpose -- MergeService.Launch documents that the thud was deliberately
			pulled off the VFX broadcast because Vfx.spawnLaunchImpactVfx (and the
			equivalent GroundHit send) early return when their authored template is
			missing, and a launch should still be audible then. All three sounds
			share this shape so the client can play every one of them the same way
			(SoundKit.playAt with the LAUNCH_IMPACT profile).

			`kind` selects which sound: "Mush" | "Land" | "Explosion". Only "Mush"
			uses `soundId`/`soundVolume` -- that one is authored per tier on a
			ServerStorage-only template attribute (MergeObjectVisuals.getMushSound),
			so there is no client-visible AssetIds entry for it to look up, unlike
			Land (Sounds.SquishyLand) and Explosion (Sounds.SquishyPop), which the
			client already has and resolves itself from `kind`.
		]]
		mergeLaunchAudio = ByteNet.definePacket({
			value = ByteNet.struct({
				kind = ByteNet.string,
				soundId = ByteNet.string,
				soundVolume = ByteNet.float64,
				worldX = ByteNet.float64,
				worldY = ByteNet.float64,
				worldZ = ByteNet.float64,
			}),
		}),

		--[[
			server -> every client. "Two squishies just merged here." Same
			replication-race argument as mergeLaunchVfx: Emit() is transient, so
			the server sends only the position and every client clones the
			authored pack and emits it locally.

			templateName is selected authoritatively from the merging player's
			owned/equipped Merge Pop cosmetic. Clients only resolve that
			server-selected name under Assets.VFX.Merge.
		]]
		mergeSquishyVfx = ByteNet.definePacket({
			value = ByteNet.struct({
				templateName = ByteNet.string,
				worldX = ByteNet.float64,
				worldY = ByteNet.float64,
				worldZ = ByteNet.float64,
			}),
		}),

		-- client -> server. Request the carried object's Mush interaction.
		-- MergeService verifies the sender is carrying and is not already
		-- boosted; the client never chooses its tier, sound, or speed reward.
		mergeMushRequest = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		--[[
			server -> requesting client. Confirms an accepted Mush and provides
			the server-read per-tier audio configuration for local ASMR playback.

			payout is what this click actually paid out of the squishy's squeeze
			pot -- 0 for a mush on an empty squishy, which is still a legitimate
			mush (squash, sound, speed boost) with no money burst. float64
			because the coin curve doubles thirty times and an integer wire type
			would overflow long before the top tier.

			drainStep/drainTotal are 1-based and describe where this click sits
			in the squishy's drain, so the client can ramp the burst size and
			sound pitch across the sequence. Both are 0 when payout is 0. uint8
			is ample: drainTotal is bounded by MUSH_MAX_DRAIN_CLICKS.
		]]
		mergeMushActivated = ByteNet.definePacket({
			value = ByteNet.struct({
				tier = ByteNet.uint8,
				soundId = ByteNet.string,
				soundVolume = ByteNet.float64,
				direction = ByteNet.string,
				payout = ByteNet.float64,
				drainStep = ByteNet.uint8,
				drainTotal = ByteNet.uint8,
			}),
		}),

		-- server -> owning client. Fired only after the authoritative passive
		-- income grant succeeds. The client displays every resting model's
		-- popup in the same frame; persistent balance state does not travel here.
		mergeIncomePulse = ByteNet.definePacket({
			value = ByteNet.nothing,
		}),

		--[[
			client -> server. Request to equip an owned cosmetic. `slot` is one
			of CosmeticsCatalog.Slot ("KeycapThemes" | "SquishyBeams" |
			"MergePops"); `id` is a catalog id for that slot.
			CosmeticsService re-validates both
			(known slot, known id, actually owned) before writing -- an unowned
			or unknown id is silently dropped, same as every other "not in the
			state this implies" packet in this file.

			No result packet: the equip (or the rejection, which just leaves
			the old value in place) is visible via the replicated
			Cosmetics.KeycapThemeId / SquishyBeamId / MergePopId fields
			DataController.observe already watches, so there is nothing else to
			tell the client.
		]]
		cosmeticEquip = ByteNet.definePacket({
			value = ByteNet.struct({
				slot = ByteNet.string,
				id = ByteNet.string,
			}),
		}),
	}
end)
