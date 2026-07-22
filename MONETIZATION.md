# Monetization Notes

## Gifted gamepass duplicate race

Status: deferred while all entries in `Shared.UISystem.Config.Passes` remain
disabled and their `PassRewards` implementations are stubs.

### What is already guaranteed

- A developer-product receipt is granted at most once for its `PurchaseId`.
- The purchaser is acknowledged only after the receipt ledger is durably saved.
- Paid gifts are placed in the recipient's durable ProfileStore message queue,
  so an offline recipient or server change does not lose the gift.
- Gift initiation rejects a recipient who owns the Roblox gamepass, or whose
  `UISystem.GiftedPasses[passName]` entitlement is visible in the same server.

### Remaining race

The ownership check cannot currently see a custom `GiftedPasses` entitlement
loaded in another server or stored in an offline profile. Two gifters can also
pass the check concurrently before either receipt finishes.

Those purchases have different valid `PurchaseId` values, so receipt
idempotency correctly treats them as separate purchases. Consequently, both
senders can be charged for the same one-time entitlement. Preventing the reward
from running twice would make fulfillment idempotent, but would not undo the
second charge.

### Why it is deferred

Preventing the purchase itself requires a durable, atomic reservation before
opening the Roblox prompt. That system must also handle canceled prompts,
expired reservations, crashes between reservation and receipt delivery, and
recovery of delayed receipts. It is unnecessary complexity while gifted passes
cannot be purchased.

### When to implement it

Implement reservations before enabling a gifted pass when all of the following
are true:

- the pass is a permanent, one-time entitlement;
- offline or cross-server recipients remain supported;
- the gift costs enough Robux that a duplicate charge would require support or
  compensation; and
- the pass reward and join/respawn entitlement behavior are implemented.

### Recommended design

Use a dedicated DataStore key per `(targetUserId, passName)` and `UpdateAsync`
to atomically transition among `available`, `reserved`, and `owned` states.
Store a reservation token, gifter user ID, product ID, and expiration time.

1. Reserve the entitlement before opening the purchase prompt.
2. Persist the same reservation token in the purchaser's pending gift intent.
3. Release it when the prompt is canceled.
4. On receipt, validate the token, enqueue the durable gift, and finalize the
   entitlement as owned.
5. Allow expired reservations to be replaced, while still accepting a delayed
   receipt whose `PurchaseId` was already finalized.

The target-side reward must remain idempotent even with reservations. The
reservation prevents duplicate charges; the `PurchaseId` ledger and entitlement
check prevent duplicate delivery.

### Required launch tests

- Two servers attempt to gift the same pass to one recipient concurrently.
- The recipient is offline, online in another server, and online with the
  gifter.
- The purchaser cancels, disconnects, or the server closes after reservation.
- A receipt arrives after its reservation would otherwise expire.
- Roblox redelivers the same receipt repeatedly.

