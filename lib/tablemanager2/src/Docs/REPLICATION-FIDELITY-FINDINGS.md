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

**Use the SIGNALS feed, not the OriginDiff (diff) feed**, for the rebuilt
TableReplicator. The diff feed double-represents batched array mutations and is
not shift-faithful, so it cannot be consumed by naive flatten-and-apply (see
"Diff-feed channel limitation"). The signals feed converges on batches the diff
feed cannot.

The five defects below were all genuine. **Fixes for all five have now been
applied** (see "Fixes applied"); the signals feed is expected to converge on
every defect case after the fixes. The diff feed remains channel-limited for
batches and re-entrancy by design.

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
5. **Array-reference replacement in a batch (#5)** — Resume forces Branch A when
   the pre-batch array reference (`Diff.Snapshot.ref`, via the new
   `BatchUtils.GetSnapshotRef`) differs from the op-log's start reference, so a
   `Proxy.items = {...}` replacement inside a batch is no longer lost.

### Expected re-run outcome
- SIGNALS-feed tests: all defect cases above should now converge (incl. the
  `per-step convergence`, `echo order`, and `deferred` checks for signals).
- DIFF-feed tests: empty-table, empty-string-key, and scalar→table now converge;
  batch and re-entrancy cases remain expected-divergent (channel limitation).
- Regression watch: the `batch-lifecycle`, `array-advanced-methods`, and
  `integration-scenarios` suites exercise the batch flush and the
  signal/listener ordering that changed here — confirm they stay green.

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

## Diff-feed channel limitation (NOT a per-test bug)

The diff feed fails **every** batch test and all `Swap`s (which run an internal
batch), *including cases the signals feed replicates correctly* (e.g. "multiple
mixed operations in one Batch"). Root cause: during a batch flush the root
`OnChange({})` listener fires **multiple** deliveries, and array changes are
delivered **twice** — once as the branch-level `descendantChanged` subtree (whose
numeric children read as in-place `changed`) and once as the array-flush
`added`/`removed` element deliveries. Flattening and applying every delivery
double-counts, and the positional `added`/`removed` entries are not shift-faithful
when coalesced.

There is no clean way to consume the OriginDiff tree for batched array mutations
by flatten-and-apply. **Recommendation: the TableReplicator should consume the
signals feed.** If a diff-style wire format is desired, it should be derived from
the signal stream (which carries explicit shift semantics), not from
`metadata.OriginDiff`.

## Consumer contract verified (now handled in the harness)

- **Numeric removals from a single diff delivery must be applied
  highest-index-first**, because `ArrayRemove` shifts later elements down. The
  `wholesale shrink by >1` test exposed this; the harness diff feed now sorts
  removals descending. This is a real contract for any diff consumer, documented
  here so the rebuild bakes it in.

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

## Triage summary of the 28 failures

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
