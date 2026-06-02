# Atomic Trade System — Implementation Plan

## Goal

Implement a crash-safe, exploit-resistant item trade system between two players on the same Roblox server. The system must guarantee that at the end of any execution path — including server crashes, DataStore failures, disconnects, and timeouts — the total number of items in the economy is conserved. No item should be duplicated or destroyed under any failure condition.

---

## Vocabulary

- **Outgoing** — a field inside a player's profile where their offered item is held during the trade. Written atomically with the removal from inventory.
- **Incoming** — a field inside a player's profile where the item they will receive is copied to before claiming.
- **Received** — a boolean flag in a player's profile indicating they have acknowledged the incoming item and are ready to claim. Does not touch inventory.
- **Claimed** — final state. Incoming item has been moved to inventory, escrow fields cleared.
- **Trade object** — an in-server-memory structure tracking both players' progress through the trade. Not persisted. Destroyed on server crash.
- **JobId** — Roblox's unique identifier for the current server instance. Stored on the trade at execution start. Used during recovery to detect a server change.
- **Execution window** — the period from when the first player commits their outgoing item to when both players have claimed. The timeout runs during this window.

---

## Constraints

- Both players must be on the same server for the duration of the trade.
- A player's profile must be loaded and active on this server to participate.
- All profile mutations are in-memory until ProfileStore autosaves or the profile is released. Two mutations on the same profile within the same tick are effectively atomic from DataStore's perspective.
- No item data is ever written to a DataStore key other than the owning player's own profile key.
- The trade object is authoritative during execution. On crash it is lost, and recovery derives state purely from each player's own profile fields.

---

## Profile Trade Fields

Each player's profile must have the following fields initialized to `nil` or `false`:

```
Data.Trade = {
    tradeId       : string,   -- shared identifier for this trade
    jobId         : string,   -- server JobId when execution began
    outgoing      : { id: string, qty: number } | nil,
    incoming      : { id: string, qty: number } | nil,
    received      : boolean,
    claimed       : boolean,
    executionStart: number,   -- os.time() when execution began
}
```

---

## Execution Phases

### Phase 0 — Trade Negotiation

Both players agree on the items to be exchanged. This phase involves no DataStore writes and no escrow. It is purely in-memory on the server.

**Steps:**
1. P1 sends a trade offer specifying `item1` and a target player P2.
2. P2 receives the offer and specifies `item2` in return.
3. Both players explicitly confirm the final offer.
4. Server validates both items exist in the respective inventories at the time of confirmation.

**Failure conditions:**
- Either player disconnects before confirmation → trade object is destroyed, nothing was written, no recovery needed.
- Validation fails (item no longer in inventory) → trade rejected, inform both players, destroy trade object.

---

### Phase 1 — Commit Outgoing (per player, can happen in either order)

Each player atomically removes their item from inventory and writes it to their own profile's `Trade.outgoing` field. Both mutations are on the same profile key and happen in the same in-memory operation, making them atomic from DataStore's perspective.

**Steps:**
1. Generate a `tradeId` (e.g. sorted player pair + timestamp). Assign to trade object.
2. Record `game.JobId` on the trade object. Do not write to profiles yet.
3. For each player (P1 then P2, or concurrently):
   - Validate item still exists in inventory.
   - In a single in-memory operation on their profile:
     - Remove item from `Data.Inventory`.
     - Write item to `Data.Trade.outgoing`.
     - Write `tradeId` to `Data.Trade.tradeId`.
     - Write `game.JobId` to `Data.Trade.jobId`.
     - Write `os.time()` to `Data.Trade.executionStart`.
   - Force a profile save.
   - Notify trade object that this player has committed.
4. Once both players have committed and saves have confirmed, start the execution timeout (`task.delay`).

**Failure conditions:**
- Validation fails for either player after the other has already committed → the committed player's outgoing must be refunded. Reverse the in-memory operation and force a save. Destroy trade object.
- Profile save fails for either player → retry save. If retry fails, reverse the in-memory operation, refund any already-committed player, destroy trade object.
- Either player disconnects before their commit saves → their profile will load on rejoin with no `Trade` fields set (the save failed or hadn't fired). The other player's profile may have `Trade.outgoing` set. See Recovery — Partial Commit.
- Server crashes during this phase → see Recovery — Partial Commit.

---

### Phase 2 — Copy Incoming

Each player reads the other player's `Trade.outgoing` value from the in-server loaded profile (not from DataStore — both profiles are loaded on this server) and writes it to their own `Trade.incoming` field. This is a write to their own profile only.

**Steps:**
1. Verify both players are still connected and both profiles are still active.
2. For each player:
   - Read the other player's `Data.Trade.outgoing` from the in-memory loaded profile.
   - Write that value to their own `Data.Trade.incoming`.
   - Force a profile save.
   - Notify trade object that this player has copied.
3. Both copies must succeed before proceeding. If either save fails, see failure conditions below.

**Failure conditions:**
- Either player disconnects before their copy saves → see Recovery — Partial Copy.
- Save fails → retry. If retry fails → full rollback. Refund both outgoing fields, clear all trade fields on both profiles, force saves, destroy trade object.
- Server crashes during this phase → see Recovery — Partial Copy.

---

### Phase 3 — Mark Received

Each player writes `Trade.received = true` to their own profile. This signals readiness to claim. Inventory is not touched in this phase.

**Steps:**
1. For each player:
   - Write `Data.Trade.received = true` to their own profile.
   - Force a profile save.
   - Notify trade object that this player has marked received.
2. Trade object waits until both players have marked received before proceeding.

**Failure conditions:**
- Either player disconnects before marking received → timeout will eventually fire. See Recovery — Timeout.
- Save fails → retry. If retry fails → full rollback. Both sides have incoming written but neither has claimed. Safe to refund outgoing and discard incoming on both profiles.
- Server crashes during this phase → both players rejoin. See Recovery — Crash After Copy.

---

### Phase 4 — Claim

Both players have marked received. This is the point of no return. Each player moves their `Trade.incoming` to inventory and clears all trade fields. Both mutations are on their own profile, in-memory, atomic.

**Steps:**
1. Cancel the execution timeout — both received flags are confirmed, rollback is no longer valid.
2. For each player:
   - In a single in-memory operation:
     - Add `Data.Trade.incoming` item to `Data.Inventory`.
     - Set `Data.Trade.claimed = true`.
     - Clear `Data.Trade.outgoing`, `incoming`, `received`, `tradeId`, `jobId`, `executionStart`.
   - Force a profile save.
3. Once both saves confirm, destroy the trade object. Trade is complete.

**Failure conditions:**
- Save fails → retry. The in-memory state already has the item in inventory and `claimed = true`. Keep retrying until the save lands. ProfileStore will save on player disconnect or server close regardless.
- Player disconnects before save → ProfileStore saves the profile on release. The claim is already in memory. On rejoin the item will be in their inventory. No recovery needed.
- Server crashes after one player claims but before the other → see Recovery — Crash After Partial Claim.

---

## Recovery

Recovery runs whenever a player's profile loads and `Data.Trade` is non-nil. It must be the first thing that runs after profile load, before the player is given control.

### Determining which recovery path to take

Read the following fields from the loaded profile to determine state:

```
claimed          → Phase 4 completed for this player
received         → Phase 3 completed for this player
incoming != nil  → Phase 2 completed for this player
outgoing != nil  → Phase 1 completed for this player
```

---

### Recovery — No Trade Fields

`Data.Trade` is nil or empty. Nothing to recover. Proceed normally.

---

### Recovery — Partial Commit

**Condition:** `outgoing` is set, `incoming` is nil, `received` is false.

The player committed their item to escrow but the trade did not progress past phase 1.

**Steps:**
1. Check if the other player is currently on this server and their profile has a matching `tradeId`.
2. If yes and the other player has also committed → trade can resume from phase 2. Proceed with copy phase. Restart timeout.
3. If the other player is not on this server, or their profile has no matching trade → full rollback for this player. Move `outgoing` back to inventory, clear all trade fields, save.
4. If the other player is on this server but has not committed → wait briefly (up to a few seconds). If they do not commit, full rollback for both.

---

### Recovery — Partial Copy

**Condition:** `outgoing` is set, `incoming` may or may not be set, `received` is false, jobId does not match current server.

The server crashed during or after the copy phase. Neither player has marked received.

**Steps:**
1. JobId mismatch confirms this is a new server.
2. Full rollback regardless of whether `incoming` is set.
3. Move `outgoing` back to inventory, clear all trade fields including `incoming`, save.
4. Both players are recovered independently. They do not need to be on the same server for this recovery path.

---

### Recovery — Crash After Copy, Same JobId

**Condition:** `outgoing` is set, `incoming` is set, `received` is false, jobId matches current server.

Both copies completed and saved, but the server crashed before either player marked received. Since the jobId matches, the server did not change — this means the player disconnected and reconnected to the same server.

**Steps:**
1. Check if the other player is on this server with a matching `tradeId`.
2. If yes → resume from phase 3. Both mark received and proceed to claim.
3. If no → the other player is on a different server or offline. JobId will mismatch for them on their rejoin. Full rollback for this player: refund outgoing, discard incoming, clear trade fields, save.

---

### Recovery — Timeout

**Condition:** `outgoing` is set, trade is active on this server, `os.time() - executionStart` exceeds the timeout threshold, and both players have not marked received.

**Steps:**
1. Full rollback for both players simultaneously.
2. Move each player's `outgoing` back to their inventory.
3. Clear all trade fields on both profiles including any `incoming` that was written.
4. Force saves on both profiles.
5. Destroy trade object.
6. Inform both players the trade expired.

---

### Recovery — Crash After Partial Claim

**Condition:** `claimed` is true.

This player completed phase 4 before the crash. Their inventory already has the item.

**Steps:**
1. Clear remaining trade fields if any are still set.
2. Save.
3. No item movement needed. Recovery is complete.

The other player will recover independently. If they have `received = true` and `incoming` set but `claimed = false`, they should proceed to claim their item — the trade reached the point of no return before the crash. Since `received = true` and the other player is confirmed claimed, this player's claim is valid regardless of jobId.

---

### Recovery — Crash After Both Mark Received, Before Either Claims

**Condition:** `received` is true, `claimed` is false, `incoming` is set.

Both players had marked received before the crash. The trade was past the point of no return.

**Steps:**
1. Check the other player's profile (if loaded on this server) or wait for them to rejoin.
2. If the other player also has `received = true` → both proceed to claim regardless of jobId. The both-received condition supersedes the jobId rollback rule.
3. Move `incoming` to inventory, set `claimed = true`, clear trade fields, save.

---

## Timeout Configuration

- Timeout begins when both players have committed their outgoing items (end of phase 1).
- Timeout duration should be long enough to accommodate normal DataStore save latency under load. 30–60 seconds is a reasonable range.
- Timeout is cancelled the moment both players mark received (start of phase 4).
- Timeout fires → same rollback path as Recovery — Timeout above.
- Timeout must be restarted if the trade resumes from a recovery path.

---

## Invariants — These Must Hold At All Times

1. An item exists in exactly one place: `Inventory`, `Trade.outgoing`, `Trade.incoming`, or in transit between them within a single in-memory operation.
2. `incoming` is never written before the corresponding `outgoing` exists in the other player's profile.
3. `received` is never set to true before `incoming` is written and saved.
4. Inventory is never modified during phases 1–3.
5. Rollback is only valid if both player have not `received = true`. Once both have `received = true` the trade must complete.
6. Recovery for any player must never require reading the other player's DataStore key directly. It must be derivable from the recovering player's own profile fields plus the in-server trade object if available.