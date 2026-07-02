# TableManager — Observable Behavior Contract

This is the **observable contract** the shadow/linking/opacity re-architecture must preserve. It
documents what callers can rely on, derived from the current implementation and the existing
`src/Tests/**` specs. The internal mechanism (shadow, dispatch, diff) may change freely; everything
described here must keep holding unless a change is explicitly called out in the re-architecture plan
(`~/.claude/plans/evaluate-if-starting-from-elegant-lagoon.md`).

It exists so that, after the rewrite, divergence from this document is a regression — not a judgement
call. Where a behavior is intentionally changing under the plan, it is flagged **[PLANNED CHANGE]**.

---

## 1. Surfaces

There are two notification surfaces. Both fire for the same underlying changes.

### 1.1 Per-change Signals (global; fire for ANY path)
`ValueChanged`, `KeyAdded`, `KeyRemoved`, `KeyChanged`, `ArrayInserted`, `ArrayRemoved`, `ArraySet`.

Payloads (positional):
- `ValueChanged(path, newValue, oldValue)`
- `KeyAdded(path, key, newValue)`
- `KeyRemoved(path, key, oldValue)`
- `KeyChanged(path, key, newValue, oldValue)`
- `ArrayInserted(path, index, newValue)`
- `ArrayRemoved(path, index, oldValue)`
- `ArraySet(path, index, newValue, oldValue)`

For the array signals, `path` is the **array's** path (not the element path).

Dispatch is governed by `Config.SignalFireMode` (`"immediate"` default | `"deferred"` | `"bindable"` |
`"coalesced"`). `"coalesced"` collapses repeated fires of the *same* signal within a tick into one fire
carrying the latest args, except the "old value" arg is preserved from the first fire in the window
(`ValueChanged` arg 3, `KeyChanged` arg 4, `KeyRemoved` arg 3, `ArrayRemoved` arg 3, `ArraySet` arg 4).

### 1.2 Path Listeners (registered at a path)
Registration methods and callback signatures:
- `OnChange(path, cb, opts)` → `cb(newValue, oldValue, metadata)` — fires for a direct change at `path`
  OR any descendant change.
- `OnValueChange(path, cb, opts)` → `cb(newValue, oldValue, metadata)` — fires ONLY when `path` itself
  is directly reassigned (shorthand for `OnChange` with `ListenDepth = 0, ListenDepthStyle = "=="`).
- `Observe(path, cb, opts)` → immediately calls `cb(currentValue, nil, nil)`, then behaves like
  `OnValueChange`. The initial fire is `task.spawn` in immediate fire-mode, otherwise `task.defer`.
- `OnKeyAdd(path, cb, opts)` → `cb(key, newValue, metadata)`
- `OnKeyRemove(path, cb, opts)` → `cb(key, oldValue, metadata)`
- `OnKeyChange(path, cb, opts)` → `cb(key, newValue, oldValue, metadata)`
- `OnArrayInsert(path, cb, opts)` → `cb(index, newValue, metadata)`
- `OnArrayRemove(path, cb, opts)` → `cb(index, oldValue, metadata)`
- `OnArraySet(path, cb, opts)` → `cb(index, newValue, oldValue, metadata)`

All return a `Connection { Connected: boolean, Disconnect() }`.

A scalar `oldValue` is immutable and always safe to retain. A **table** `oldValue` is the baseline
mirror node and is a stable snapshot only for the **duration of the synchronous callback**: if the same
live table is later mutated in place and reconciled, the baseline node is refreshed in place (it is
shared by identity so co-observers see the update), which can change a retained table `oldValue`. Copy a
table `oldValue` if you need to keep it past the callback. (Writes that assign a *new* table replace
identity and never affect an earlier `oldValue`.)

`path` accepts a string (`"player.health"`), a path array (`{"player","health"}`), or (for the array/
write methods) a `Proxy` obtained from this manager. The empty path (`{}` / `""`) is the root.

### 1.3 Replication op stream (`OnApplied`)
- `OnApplied(cb): Connection` → `cb(op: AppliedOp)` — a pre-diff stream of one `AppliedOp` per finalized
  change, where `AppliedOp = { Kind, Path, NewValue?, OldValue?, Index?, Diff?, OriginHasNoOpacity? }` and
  `Kind` is `"Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet" | "BatchBegin" | "BatchEnd"`.
- A non-empty subscriber list **is its own gate**, separate from and cheaper than the diff/listener gate
  used by the surfaces above: a manager with only an `OnApplied` subscriber (no local listeners, no
  connected Signal) pays no diff cost for its writes.
- The payload is adaptive: if nothing else is already diffing the change, the op carries the raw
  `NewValue`; if a diff is already happening for some other reason (a covering listener, a batch flush),
  the op rides that diff node (`Diff`) instead, carrying a minimal per-leaf delta at no extra cost.
- `BatchBegin`/`BatchEnd` markers (`Path = {}`) frame a `Batch`/`Suspend`-`Resume` window.
- `Flush(path?)`'s gate widens to "locally observed OR has an `OnApplied` subscriber", so a bypassed
  write surfaced only via `Flush` still reaches replication even when nothing locally observes `path`.

---

## 2. Listener options

`ListenerOptions = { ListenDepth: number?, ListenDepthStyle: ("<="|"==")?, Once: boolean? }`

- `ListenDepth = nil` (default): fire for a change at the registered path or at any depth below it.
- `ListenDepth = 0`: fire only for a change AT the registered path (no descendants).
- `ListenDepth = n`: fire for changes up to `n` levels below.
- `ListenDepthStyle = "<="` (default): at-or-within the depth. `"=="`: exactly that depth.
- `Once = true`: auto-disconnect after the first fire. On a wildcard path this is once **total** across
  all matching keys (one tree node), not once per key.

`relativeDepth` for an ancestor notification = `#metadata.OriginPath - #registeredPath` (clamped ≥ 0);
a direct change is depth 0.

### Wildcards
A `"*"` path segment matches any single literal key at that position. A literal listener and a wildcard
listener that both match the same change BOTH fire. Matched keys are exposed via
`metadata.WildcardMatches` (array, left-to-right, one entry per `"*"`); `nil` when the registered path
had no wildcards.

---

## 3. `metadata` (ChangeMetadata)

Passed to every path-listener callback:
- `Diff: DiffNode?` — present for a **direct** change at the listener's path; **`nil` for an ancestor
  notification** (a descendant changed). This nil-vs-present distinction is the documented way a listener
  tells "me" from "a descendant".
- `OriginPath: PathArray` — where the assignment actually happened (same for direct and ancestor).
- `OriginDiff: DiffNode` — the root diff node of the whole operation.
- `Snapshot` — carries `RootTable` for ancestor value navigation.
- `WildcardMatches: { any }?` — see §2.
- `Move: MoveMetadata?` — set on the `ArrayRemoved`/`ArrayInserted` pair of a non-batched
  `ArraySwapRemove` that constitutes a move.
- `ArrayOp: { Kind, Index }?` — set on synthetic array-op events (and their ancestor notifications);
  carries explicit shift semantics so a consumer applying `OriginDiff` can distinguish a shifting
  remove/insert from an in-place numeric write. `Kind ∈ {"ArrayInserted","ArrayRemoved","ArraySet"}`.

`DiffNode = { type: "changed"|"added"|"removed"|"descendantChanged", old, new, children? }`.
`Diff.flatten(node, basePath)` yields `{ path, type, old, new }` leaf entries (the `descendantChanged`
internal nodes are not emitted as leaves).

---

## 4. Fire ordering (must be preserved)

For a single change, observed order is:
1. **Signal fires before registry listeners** at each emission point. (A re-entrant write from a
   listener therefore has its nested signal fire after the current one — the public signal stream stays
   in write-initiation order.)
2. **Ancestor delivery walks parent→…→root** for `ValueChanged`/`KeyChanged` (each ancestor gets
   `Diff = nil`).
3. For an **array op**: exact **element path** listeners fire, then **array path** listeners, then
   ancestor `ValueChanged`, then the array Signal. (See `Emitter.fireArrayOperation`.)
4. For a **scalar↔table transition**, subtree teardown/build events are delivered before the node's own
   scalar-collapse event (so a consumer never applies child events through a non-table value).
5. **Re-entrant writes are queued**: a write performed inside a listener runs its full dispatch AFTER
   the current dispatch completes (so consumers see the outer operation's events before the events of
   any write it triggered). A queued check diffs against drain-time state, so chained re-entrant writes
   may collapse into fewer (still convergent) events.

---

## 5. Event semantics per operation

### Set (`Set(path, v)` / `Proxy.a.b = v`)
- Scalar→scalar change: `KeyChanged` + `ValueChanged` at the path; ancestor `ValueChanged`/`KeyChanged`.
- New key: `KeyAdded` + `ValueChanged`. Removed key (`= nil`): `KeyRemoved` + `ValueChanged`.
- Assigning a table fires granular descendant events (per changed leaf) plus ancestor notifications, so
  a listener registered below the assigned path still sees its own change.
- Empty path `Set({}, newTable)` replaces the whole root (identity swap + full diff). The new root must
  be a table; cannot be done inside a batch.
- Setting a path equal to its current value fires nothing (no spurious events).

### Array ops (`path` is the array)
- `ArrayInsert(path, value)` appends; `ArrayInsert(path, index, value)` inserts (shifting later
  elements). Fires `ArrayInserted(index, value)`.
- `ArrayRemove(path, index)` removes and shifts; returns the removed value; fires
  `ArrayRemoved(index, oldValue)`.
- `ArraySet` (e.g. `Proxy.items[i] = v` on an existing index) fires `ArraySet(index, new, old)`; does
  NOT shift.
- `ArraySwapRemove(path, index)`: O(1) remove by moving the last element into the gap. If `index` is not
  the last, fires `ArraySet(index, movedValue, oldValue)` THEN `ArrayRemoved(lastIndex, movedValue)`,
  both carrying `Move` metadata. Swap-removing the **last** element fires only `ArrayRemoved` (no
  `ArraySet`).
- Array listeners fire only for the exact array path matched (an `OnArrayInsert("items", …)` does not
  fire for a different array).

### Other write helpers
- `MoveTo(src, dst)`, `CopyTo(src, dst)`, `Swap(a, b)` are batched internally and fire the equivalent
  Set events; they preserve proxy references for moved tables. Cannot target the root; `MoveTo`/`Swap`
  reject ancestor/descendant pairs.
- `Flush(path?)` surfaces changes made by code that bypassed `Set`/`Proxy` (raw mutation). No-op when
  nothing observes `path` AND no `OnApplied` subscriber exists (see §1.3). Inside a batch it only marks
  the branch dirty.
- `SetPathIgnored(path, ignored)`: an ignored write still updates `Raw`/`Get` but fires nothing and is
  excluded from diffing. `Config.IgnoredPaths` is the construction-time equivalent.

---

## 6. Batching

- `Batch(fn)` / `Suspend()` + `Resume()` defer all firing until the window closes; nested calls are
  no-ops (outermost wins). Yielding inside a batch is unsupported.
- On resume, accumulated changes are diffed against the pre-batch state and fired once. Net no-op
  changes within the window produce no events.
- A batched root-level write reaches root (`{}`) listeners (one delivery per changed root key).
  **[NOTE]** this per-key delivery is current behavior; the rewrite may revisit exact delivery grouping
  but must keep root listeners informed of batched root-level writes.

---

## 7. Opacity (`Opaque` / `OpaqueChildren` / global variants)

- A value marked opaque is compared by identity only — never cloned, frozen, walked, or deep-diffed. A
  change to its internals does NOT fire descendant events; replacing the reference fires a single
  `changed`/`added`/`removed` at its own slot.
- `OpaqueChildren` marks a container so its direct table-typed children (including later-inserted ones)
  are opaque leaves while the container itself stays transparent.
- Marking is by value reference (survives array shifts / `MoveTo` / `Swap`), via weak registries.
- **Opacity is per-viewer**: the same live table may be opaque to one manager and transparent to
  another. This MUST remain true (e.g. an Inventory manager treats a `sword` as an opaque leaf while a
  dedicated Sword manager observes that same table transparently). It holds **even when the two
  managers co-observe a shared parent** of that table: the opaque viewer never fires for the shared
  child's internal mutations, while the transparent co-observer still does. (The shared diff baseline
  picks each slot's shape by global observership, so neither viewer corrupts the other's baseline.)

---

## 8. Linking — implicit sharing (`Extend`)

- **Sharing a table identity *is* being linked.** Any table reachable (transparently) in 2+ managers'
  trees — root or interior, e.g. `Player.Stats` and `Tycoon.Stats` — is observed by all of them, and a
  write via one propagates to the others, translated into each manager's own path coordinates. No
  explicit link call: sharing is automatic as tables enter a tree (construction / table writes / array
  inserts / root replacement). See `Propagation`.
- Each recipient is delivered **exactly once** per change, even when it shares several nested identities
  along the changed path (deduplicated by recipient, via the shallowest shared ancestor).
- **Opacity is the boundary**: an opaque value (or an `OpaqueChildren` child) is never registered as
  observed and never propagates. This is the only opt-out (no separate API).
- **Divergence** is lazy: a manager that replaces a shared reference simply stops resolving a live path
  to that identity, so propagation to it is skipped and the sharing lapses; other observers keep sharing.
- `Extend(target)` returns a plain `TableManager` rooted at the shared table at `target`; because it
  shares that identity, it is automatically a co-observer (writes propagate both ways) until either side
  replaces the reference.
- `GetLinkedManagers()` (current co-observers) and `IsLinkedWith(other)` are plain `TableManager`
  methods. There is no manual link/unlink.
- Cross-manager delivery order: the *originating* manager's listeners fire before propagated observers'
  (see `Tests/TM/TableManager.shared-baseline.spec`).

---

## 9. Config (`TableManagerConfig`)

`Schema`, `OnValidationFailed`, `ListenerFireMode`, `SignalFireMode`, `FlushMode`
(`"immediate"`/`"coalesced"`), `EnableProxies` (default true; `Proxy`/`GetProxy` unavailable when
false), `IgnoredPaths`, `DuplicateReferenceMode` (`"allow"` default — multi-location references are a
supported feature; `"copy"` opts out by deep-cloning the value at write time). (Linking is implicit —
there is no `AutoLink` config; see §8.)

---

## 10. Proxies

- `manager.Proxy` / `GetProxy(path)` give a write-through view; reads return nested proxies for tables.
- Iterate with generic `for`. `pairs`/`ipairs`/`table.*`/`==` against the raw table are unsupported on
  proxies (use the manager's array methods and `Get`).
- A proxy tracks its live path across array shifts / `MoveTo` / `Swap`.
- A table referenced at multiple locations has ONE proxy, reporting a single **primary anchor** —
  whichever path established its proxy first (`ProxyManager._originalToProxy`'s single-slot-per-identity
  memo). `GetProxy` at a second location returns that same proxy (and its `GetPath`), not a proxy rooted
  at the second path.

---

## 11. Lifecycle

`Destroy()` disconnects all listeners and signals, tears down owned `Map*`/`For*` subscriptions, unlinks
from any groups, and releases proxies. It is idempotent. Destroying a `Map*`-derived manager disconnects
it from its source; destroying the SOURCE does not cascade-destroy a derived manager.
