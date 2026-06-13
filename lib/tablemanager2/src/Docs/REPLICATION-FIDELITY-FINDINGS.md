# Replication Fidelity Findings

This document records the results of running
`Tests/TM/TableManager.replication-fidelity.spec.luau` (via
`Tests/Helpers/ReplicationHarness.luau`). The spec is a **precursor gate** for
rebuilding the `TableReplicator` package on tablemanager2: it proves whether a
TableManager's listener output (the public **signals** feed, or the
`metadata.OriginDiff` **diff** feed) carries enough deterministic, self-contained
information to reconstruct an independent replica that

1. holds **byte-identical state at every step**, and
2. **re-emits the same event stream in the same order**.

## Headline conclusion

**Both feeds are now replication-faithful.** The signals feed remains the
simplest channel (explicit shift semantics per event). The diff feed's former
"channel limitation" has been RESOLVED in production code (see "Third pass");
a diff consumer must follow the consumer contract below (apply
`metadata.ArrayOp` deliveries as array ops; flatten everything else into
non-shifting Sets with ancestor entries shadowing descendants).

The five defects below were all genuine and have been fixed, along with three
residual defects found on re-run ("Follow-up fixes") and the diff-feed channel
rework ("Third pass").

## Fixes applied (2026-06-11)

All fixes are production-code changes in `lib/tablemanager2/src`; no test logic
was weakened.

1. **Empty-table emission (#1)** — `Diff.luau` `diff()` now returns an `"added"`
   leaf node for `nil -> {}` (a childless `descendantChanged` node fired no
   signal). Non-empty `nil -> table` is unchanged.
2. **Empty-string-key collision (#2)** — `Diff.luau` replaced the `""` sentinel
   with a unique `SCALAR_SENTINEL` userdata (exported as `Diff.ScalarSentinel`;
   `ChangeDetector` updated to match), so a genuine `""` key is no longer folded
   into the parent path. `scalar -> table` is now a `"changed"` node carrying the
   whole new table (order-independent) plus the table's keys as children.
3. **Re-entrancy ordering (#3)** — `TableManager.new`'s four ChangeDetector
   callbacks now fire the public Signal **before** the registry listeners, so a
   listener's re-entrant write emits its nested signal *after* the outer one.
   Fixes the SIGNALS feed. (The diff feed's root-ancestor delivery still inverts
   under re-entrancy — a structural property of when ancestor callbacks fire —
   and remains documented as channel-limited.)
4. **Batch double-emission (#4)** — `TableManager`:
   - `shouldSuppressBatchArrayEvent` now suppresses any non-array-flush event at
     or under a tracked array path (covers string-keyed element fields and the
     container), but only while the array still exists (so a wholesale array
     removal still flows through).
   - Arrays **created** during a batch are pruned from `TrackedPaths` before the
     flush, so their creation flows through the non-array flush as ordinary
     key/value adds (the array flush can't create a not-yet-existing container).
   - In-place mutation of an array element (`items[1].hp = 9`) now forces Branch A
     (full LCS), since Branch B coalescing can't represent interior field changes.
     (Superseded: Branch B was later removed entirely — all batched array flushes
     now go through LCS unconditionally.)
5. **Array-reference replacement in a batch (#5)** — Resume forces Branch A when
   the pre-batch array reference (`Diff.Snapshot.ref`, via the new
   `BatchUtils.GetSnapshotRef`) differs from the op-log's start reference, so a
   `Proxy.items = {...}` replacement inside a batch is no longer lost.

## Follow-up fixes (2026-06-11, second pass)

The first re-run showed three residual defects the fixes above missed:

6. **`Set` with `buildTablesDynamically` bypassed change detection** — after
   creating the first missing intermediate through the proxy, `Set` re-pointed
   its cursor at the RAW `{}` table it had just built, so every deeper write
   (including the final leaf) went around the proxy and emitted nothing. The
   replica only ever heard "empty table at the first segment". `Set` now builds
   the remaining path as ONE plain subtree (value at the leaf) and assigns it
   through the proxy in a single write, producing one ordinary nil→table /
   scalar→table diff. Fixes `structural methods › Set with
   buildTablesDynamically` on BOTH feeds.
7. **In-batch `ArraySwapRemove` recorded ops that corrupted stable-id
   resolution** — it recorded `Remove@index` then `Set@index`, but the recorder
   replays its op log to map indices to ids, so the Remove killed the id at
   `index` and the Set then targeted whichever id "shifted" into that slot
   (an element that never actually moved). Coalesce emitted
   `remove(1,a) + set(1,d,b)` for a swap-remove of `{a,b,c,d}` → consumer state
   `{d,c,d}` vs source `{d,b,c}`. The recording now mirrors the actual mutation
   (backfill `Set@index` first, then `Remove@lastIndex`), matching the
   non-batched emission order. Fixes `batch › ArraySwapRemove inside a batch`
   on the signals feed.
8. **Stale ChangeDetector spec** — `should handle scalar to table transition`
   still pinned the pre-fix contract (synthesized `KeyRemoved` for the old
   scalar). Updated to assert the new contract from fix #2: one `KeyChanged`
   at the key (old scalar → whole new table) plus the table's keys as adds.

## Third pass (2026-06-11): diff feed made replication-faithful

The diff feed's batch/Swap/re-entrancy/hole failures were NOT left as a channel
limitation; four production-code changes resolved them:

1. **Array ops now carry explicit shift semantics** — `fireArrayOperation` tags
   every synthetic array delivery (and its ancestor notifications) with
   `metadata.ArrayOp = { Kind = "ArrayInserted"|"ArrayRemoved"|"ArraySet",
   Index }`. A flattened "removed" entry at a numeric leaf is otherwise
   indistinguishable from an in-place nil write — this is what broke the
   array-hole case and forced the old harness to guess via an array-like
   heuristic.
2. **Batch flush no longer double-delivers arrays** — the non-array branch diff
   now MASKS every still-existing tracked-array subtree (substituting its
   pre-batch snapshot value via `maskTrackedArraysForBranchDiff`), so array
   content changes reach consumers exactly once: through the array flush's
   ArrayOp-tagged per-op deliveries. Wholesale array removals still flow
   through the branch diff (the array flush skips non-table paths).
3. **Root-level batch writes now reach root listeners** — a `__root__` dirty
   marker is expanded into per-key `CheckForChangesBetween({key})` flushes
   (union of pre-batch and current root keys). The old full-root
   `CheckForChanges` was captured at path `{}`, which fires NO ancestor
   delivery, so a root `OnChange` listener never saw batched root-level writes
   (and its diff re-included tracked-array changes).
4. **Re-entrant writes are queued** — `ChangeDetector:_dispatch` queues any
   check triggered from inside a callback and runs it after the current
   dispatch completes, so the OUTER write's events always deliver first. This
   fixes the inverted delivery order (inner clamp before outer write) on BOTH
   feeds at the source.

### Diff-feed consumer contract (bakes into the TableReplicator rebuild)

- A delivery with `metadata.ArrayOp` MUST be applied as an array op:
  `ArrayInserted`/`ArrayRemoved` shift later elements, `ArraySet` does not.
  The element path is `metadata.OriginPath`; the value is `OriginDiff.new`.
- Any other delivery: `Diff.flatten(metadata.OriginDiff, metadata.OriginPath)`
  and apply every entry as a plain non-shifting Set (`removed` → nil), SKIPPING
  entries whose path extends another entry's path in the same delivery (the
  ancestor entry's `new` carries the whole subtree and is authoritative — e.g.
  scalar↔table transitions).
- Surviving entries have no ancestor/descendant relation, so apply order does
  not matter (the old "apply numeric removals highest-index-first" rule is
  obsolete — removals are no longer applied as shifting ArrayRemoves).

`ReplicationHarness._connectDiffFeed` implements exactly this contract.

### Ordering guarantee for table<->scalar transitions

For a table -> scalar transition, the subtree teardown events (removals under
the key) are always delivered BEFORE the scalar event at the key:
`ChangeDetector._processDiffNode` processes the scalar-sentinel child LAST.
This used to follow `pairs()` order, so a consumer could receive the scalar
first and then error applying the (redundant) child removals through a
non-table value — an error that was invisible to state-only tests because the
replica already held the correct value. Two guards now exist:

- `Set(path, nil, ...)` through a missing OR non-table segment is a silent
  no-op (nothing to remove), so consumers tolerate redundant removals in any
  order.
- The harness records every replica apply error (`ApplyErrors()`), and
  `IsConverged()` returns false when any apply errored — every state-level
  test in the suite now doubles as an apply-cleanliness check. Feed handlers
  run in signal threads where uncaught errors are printed but do NOT fail
  tests; without this, "applied with an error but happened to converge" passed
  silently.

### Expected re-run outcome
- SIGNALS-feed tests: all cases converge (incl. `per-step convergence`,
  `echo order`, and `deferred`).
- DIFF-feed tests: all cases converge, including every batch, Swap,
  re-entrancy, and array-hole case. `per-step convergence` (which runs both
  feeds) converges.
- Regression watch: the `batch-lifecycle`, `array-advanced-methods`,
  `listeners-methods`, and `integration-scenarios` suites exercise the batch
  flush, ancestor notifications, and the dispatch ordering that changed here —
  confirm they stay green.

## Original defect analysis (pre-fix)

The five defects below were confirmed from the first run. Kept for reference.

## How the spec is structured

- The matrix runs once per feed mode (`"signals"`, `"diff"`).
- `harness:IsConverged()` checks state equality; `OpCount()` asserts no-op
  operations stay silent; `EchoMatches()` (signals only) asserts the replica
  re-emitted an equivalent normalized op stream in order; `Step(fn)` asserts
  convergence after every individual call.
- `ReplicationHarness.DEBUG = true` dumps the source op log, the replica echo
  log, and both `Raw` tables on any divergence.

## Confirmed TableManager defects (reproduce in BOTH feeds)

These are genuine emission bugs, independent of how the feed is consumed. They
block the replicator.

### 1. Assigning an empty table emits nothing
`Proxy.inventory = {}` (new key holding `{}`) fires **zero** events on the
signals feed, and produces an OriginDiff of `{type=descendantChanged, new={},
children={}}` which flattens to **zero** entries on the diff feed. The replica
never learns the key exists.
- Tests: `dictionary keys › setting an empty table value …` (both feeds).
- Likely cause: change detection only emits at leaves with diffable children; an
  empty container has none, and no event is synthesized for the container key
  itself. Compare with a non-empty table add, which works.
- Impact: any empty array/dict/object cannot be replicated. Common (empty
  inventories, cleared collections).

### 2. Empty-string key collides with the diff `""` sentinel
`Proxy.x = { [""] = 7 }` (replacing scalar `5`) is delivered as a change at path
`{x}` with value `7` — the inner `[""]` key is folded into the parent path.
- Signals: `ValueChanged({x}, 7)` instead of the `{x}` table value.
- Diff: `OriginDiff.children[""] = {type="added", new=7}`, and `flatten_node`
  skips the `""` segment (it is the sentinel for table↔scalar transitions in
  `Diff.luau`), so the entry lands at `{x}`.
- Replica ends with `x = 7` instead of `x = { [""] = 7 }`.
- Tests: `dictionary keys › empty-string key …` (both feeds).
- Impact: any genuine `""` key is mis-replicated. Fixable by choosing a sentinel
  that cannot collide with a user key (e.g. a unique table/userdata token).

### 3. Re-entrant writes emit in inverted order
A listener that writes back during notification (e.g. clamp `health < 0` → set
`health = 0`) produces this signal order:
`ValueChanged(old=-50, new=0)` **then** `ValueChanged(old=100, new=-50)`.
The inner (clamp) event fires before the outer event that triggered it, so a
consumer applying in receipt order ends on the pre-clamp value (`-50`) while the
source holds the clamped value (`0`).
- Tests: `re-entrant mutation › a source listener that clamps …` (both feeds).
- Cause: registry listeners fire before the public signal for the same change,
  so a nested write completes (and emits) before the outer write emits.
- Impact: any validation/normalization done inside a listener desyncs the replica.

### 4. Batch flush double-represents array mutations
When an array is mutated inside a `Batch`, the flush emits the change **twice**:
the non-array (branch) flush emits a whole-branch representation **and** the
array flush emits per-element ops. A consumer applying both double-counts.

Observed signal-feed cases (all diverge by re-adding/duplicating elements):
- **Array created in batch then inserted into**: `ValueChanged({newItems}, {a,b})`
  (full array) **plus** `ArrayInserted a@1`, `ArrayInserted b@2` → replica gets
  `{a,b,a,b}`.
- **ArrayInsert of a table element in batch**: string-keyed leaf events for the
  shifted element's fields (`KeyChanged/KeyAdded hp`) escape
  `shouldSuppressBatchArrayKeyEvent` (which only suppresses *numeric* keys on
  tracked paths) **plus** `ArrayInserted` → element duplicated.
- **Element field mutation + a shift in the same batch**: same escape; the
  pre-shift element's field events apply to the wrong element after the shift.
- **ArraySwapRemove in batch**: coalesced set/remove plus leaf events overlap.
- Tests: the `batch › …` group, signals feed.
- Note: `shouldSuppressBatchArrayKeyEvent` suppresses numeric element events on
  tracked array paths but **not** string-keyed descendants of array elements, nor
  the branch-level `ValueChanged` carrying the full array. Both leak.

### 5. Replacing an array reference inside a batch loses the replacement
`Batch(items = {x}; ArrayInsert(items, y))` over `{a,b}` emits only
`ArrayInserted y@2`; the `{a,b} → {x}` reference replacement is never emitted, so
the replica stays on the old base (`{a,y,b}` vs source `{x,y}`).
- Test: `batch › whole array replaced inside a batch then mutated` (signals).
- Cause: when the tracked array's reference changes mid-batch, Branch A's
  old-vs-current LCS appears to diff against the wrong baseline.
- (Superseded: the flush now always diffs the pre-batch snapshot value against
  the current array via LCS, so a mid-batch reference replacement is captured
  directly — no separate reference-change detection is needed.)

## Diff-feed channel limitation (HISTORICAL — resolved in the third pass)

The diff feed originally failed **every** batch test and all `Swap`s (which run
an internal batch): during a batch flush the root `OnChange({})` listener fired
multiple deliveries, and array changes were delivered **twice** — once as the
branch-level `descendantChanged` subtree (whose numeric children read as
in-place `changed`) and once as the array-flush `added`/`removed` element
deliveries. Flattening and applying every delivery double-counted, and the
positional entries were not shift-faithful.

Resolved by masking tracked arrays out of the branch diff and tagging array
deliveries with `metadata.ArrayOp` — see "Third pass" above for the mechanism
and the resulting consumer contract.

## Pinned / passing (guard rails, expected green)

- `ambiguity › …` — the diff feed cannot distinguish "ArrayInsert (shifting)"
  from "new numeric dictionary key"; state still converges for boundary cases.
- `dictionary keys › string key that looks numeric …` — `"1"` (string) must not
  be conflated with `1` (index).
- `late join › …` — snapshot-then-stream handshake works; the rebuild needs an
  equivalent.
- `schema validation › rejected writes emit nothing …` — rejected mutations are
  silent and leave the replica untouched.
- `echo order (signals feed) › …` — replica re-emits an equivalent ordered stream
  for the non-buggy cases.

## Triage summary of the 28 original failures (HISTORICAL — all since fixed)

| Failure(s) | Category |
| --- | --- |
| empty table value (both feeds) | TM defect #1 |
| empty-string key (both feeds) | TM defect #2 |
| re-entrant clamp (both feeds) | TM defect #3 |
| batch: array-created / table-element-insert / element-field+shift / swapremove (signals) | TM defect #4 |
| batch: whole-array-replaced (signals) | TM defect #5 |
| ALL diff-feed batch + Swap failures | Diff-feed channel limitation |
| diff: wholesale shrink >1 | Consumer contract (now fixed in harness) |
| diff: nil-write-in-middle (hole) | Sparse arrays unsupported; documented |
| Set with buildTablesDynamically (both) | Downstream of defect #1 (intermediate empty tables don't emit) |
| per-step convergence | Aggregates the above |
