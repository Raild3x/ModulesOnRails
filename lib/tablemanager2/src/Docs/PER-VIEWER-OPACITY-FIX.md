# Per-Viewer Opacity for Shared Parents — Fix Plan

Status: **proposed** (the bug is captured by an expected-RED golden; see §2.1). This
document is the design for closing it. All line numbers are against the tree at the time of
writing — re-confirm before editing.

---

## 1. Summary

The baseline is a **global, identity-keyed pool** (`ShadowNode.REGISTRY`) shared by every
manager. A `REGISTRY[T]` node is **intrinsically tied to the live table `T`** — it is always
T's content and is never repurposed for another identity. A parent node's child *slot* holds
one of two shapes:

- a **content node** (`REGISTRY[child]`, a deep copy) for a transparently-observed child, or
- the **live ref** for an opaque child.

The bug is **not** the two shapes — it is that today the shape is chosen by the *reconciling
manager's* opacity (`copyForShadow` branches on `ctx`). When two managers co-observe a parent
but disagree on a child's opacity, each reconcile of the parent overwrites the shared slot
with *its* shape, corrupting the other's baseline.

**The fix is one idea:** choose the slot shape by **global observership** instead of the
reconciler's opacity — content node iff *some* manager observes the child transparently
(`OBSERVERS[child]` non-empty), live ref otherwise. Every manager then reconciles the slot to
the **same** shape, so there is nothing to corrupt. Because `OBSERVERS` already excludes
opaque marks (per-manager *and* global), it is the correct, ready-made signal.

This needs one supporting piece: a small **node → identity** back-reference, so an opaque
viewer reading a *content-node* slot can still compare the child's **identity** (not the copy)
against live — which is what "ref-change is the parent's concern" requires. Opacity then
collapses to a single diff-time decision: after the identity check, transparent recurses into
the content node, opaque stops.

What this fix does **not** require (vs. earlier drafts): no bare-ref slots, no ref-indirection
in the node walkers, no change to `oldValue` (baselines stay deep copies). A `SnapshotOldValue`
listener option remains a worthwhile *independent* optimization but is **not** needed here.

---

## 2. The bug — current behavior

### 2.1 Reproduction (the golden)

`lib/tablemanager2/src/Tests/TM/TableManager.opaque.spec.luau`, in
`describe("Per-viewer opacity (Inventory/Sword)")`, test
**"mixed-opacity co-observers of a shared parent do not corrupt each other's baseline"**
(currently expected RED).

```lua
local C = { hp = 100 }
local P = { child = C }
local N = TableManager.new { Region = P } -- transparent on P + C
local M = TableManager.new(P)             -- co-observes the SAME P (root)
M:Set("child", TableManager.Opaque(C))    -- M marks C opaque
N:Set({ "Region", "child", "hp" }, 101)   -- N materializes the shared child slot as a FULL node
local mSaw = false
M:OnValueChange({ "child" }, function() mSaw = true end)
C.hp = 50                                  -- raw internal mutation of the shared child
M:Flush({ "child" })
expect(mSaw).never_is_true()               -- FAILS today: M (opaque) fires a spurious change
```

The non-conflicting Inventory/Sword case in the same describe block passes — there the opaque
viewer does **not** co-observe a shared parent, so the conflict never arises.

### 2.2 Mechanism (with code references)

- **Both managers register as observers of `P` and `C`.** `TableManager.new` →
  `Propagation.RegisterSubtree` (`lib/tablemanager2/src/Propagation.luau:145`) →
  `registerOwner` (`Propagation.luau:117`), giving `OBSERVERS[P] = {M, N}` and
  `OBSERVERS[C] = {N}` (opaque marks are skipped, so M is **not** an observer of C). This
  registry is exactly the global "who sees this transparently" signal the fix keys on.
- **M's reconcile writes the slot as a live ref.** `M:Set("child", Opaque(C))` →
  `ShadowNode.Reconcile` (`ShadowNode.luau:128`) → `copyForShadow` (`ShadowNode.luau:67`),
  which for an opaque value returns the **live ref** (`ShadowNode.luau:70-72`), so
  `REGISTRY[P].child = C`.
- **N's reconcile overwrites the same slot with a full copy.**
  `N:Set({"Region","child","hp"}, 101)` → `ShadowNode.Materialize` (`ShadowNode.luau:146`) →
  `copyForShadow(P, N.ctx)` does `table.clear(REGISTRY[P])` then refills, setting
  `REGISTRY[P].child = REGISTRY[C]` (a deep copy node) — wiping M's ref. The slot's shape now
  depends entirely on who reconciled last.
- **M flushes and fires spuriously.** `M:Flush({"child"})` → `Baseline.Get` →
  `ShadowNode.Get` (`ShadowNode.luau:119`) returns `REGISTRY[C]` (the copy). `Diff.diff`
  (`Diff.luau:324`) takes the opaque branch (C opaque in M's ctx) and `make_opaque_leaf`
  (`Diff.luau:196`) compares `liveValue(old = REGISTRY[C] copy)` vs `liveValue(new = C)`.
  Copy ≠ live identity → `"changed"` → `ChangeDetector.fireNodeCallbacks`
  (`ChangeDetector.luau:475`) fires a change M must never see.

Propagation does not heal this: N's fan-out to M is gated out by
`Coverage.PassesThroughOpaqueAncestor`, so M never re-materializes the slot.

---

## 3. Why it's structural

- **One slot, two needs.** An opaque viewer needs the child's **identity** (to tell
  "replaced" from "mutated"); a transparent viewer needs the child's **content** (to diff
  internals). Today `copyForShadow` (`ShadowNode.luau:67`) collapses the slot to exactly one,
  chosen by the *reconciler's* ctx — so co-observers with different opacity fight over it.
- **The pool is shared by identity.** `REGISTRY` (`ShadowNode.luau:59`) is global; the
  conflicting slot is literally the same entry for both managers. We can't give each its own
  without re-introducing per-manager baselines (the thing 6b deleted).
- **The old guard is gone.** Phase C's `managerHasNoPerManagerOpacityIn` (which disabled
  shared baselines under mixed opacity) was removed with the global pool.

The minimal correct change is therefore: make the slot's shape **independent of who
reconciles** (key it on global observership), and give an opaque viewer a way to recover the
**identity** from a content-node slot.

---

## 4. Design

### 4a. Slot shape is chosen by global observership (the fix)

`copyForShadow` stops branching on the reconciler's `ctx`. For a **table child**:

- if `OBSERVERS[child]` is **non-empty** (some manager observes it transparently) → store the
  **content node** `REGISTRY[child]` and recurse to build it (same as today's transparent
  case);
- else (opaque to everyone, or unobserved) → store the **live ref** (same as today's opaque
  case — one ref, no walk, no copy; opacity's memory/perf benefit preserved).

Because `OBSERVERS` already encodes both per-manager and global opacity (opaque nodes are
never registered — `Propagation.registerSubtree`), this is the exact "is anyone transparent
here?" signal, applied **per node, recursively**. The shape is now **globally determined**:
every manager reconciles the parent to the *same* slot shape regardless of its own opacity, so
the corruption is gone. (`copyForShadow` no longer needs `ctx` at all — observership subsumes
it. Single-manager behavior is unchanged: a lone transparent manager is in `OBSERVERS`, a lone
opaque mark is not.)

Consequence in your terms: a node is identity-bound and never changes which table it
represents; an **internal mutation** updates the existing `REGISTRY[child]` in place; a
**reference replacement** makes the parent slot resolve to a *different* node — both fall out
naturally because the slot is keyed on the child's current identity/observership, not on a
per-reconciler choice.

### 4b. Node → identity back-reference (so opaque viewers compare identities)

Add a weak `IDENTITY_OF: { [contentNode]: liveTable }` (weak **keys and values**, so it never
pins live data). `copyForShadow` records `IDENTITY_OF[REGISTRY[child]] = child` when it builds
a content node.

At diff time, the opaque branch must compare *identities*, not the copy. For an opaque viewer
whose slot is a content node, the "old identity" is `IDENTITY_OF[contentNode]` (= the live
child it mirrors); for an opaque-only slot it's already the live ref. So `liveValue`
(`Diff.luau:106`) resolves a content node to its identity via the registry, exposed to `Diff`
through the existing `Ctx` (add an `identityOf` resolver). Then:

- **opaque viewer:** `make_opaque_leaf(identity(old), live)` — equal when the reference is
  unchanged (no spurious fire), `"changed"` only on a real replacement.
- **transparent viewer:** unchanged — recurse into the content node and diff.

### 4c. `oldValue` is unchanged (and `SnapshotOldValue` is optional)

Because observed children still store **deep copies** (content nodes), a table `oldValue` is
still a concrete deep copy, exactly as today — no semantics change, no per-fire reconstruction.
The `SnapshotOldValue` listener option (default = literal previous value, opt-in = stable deep
snapshot) is a sound *independent* optimization to revisit later, but it is **not required** by
this fix. Recommend tracking it separately.

---

## 5. Changes by file

### `ShadowNode.luau` (the fix lives here)
- **`copyForShadow` (`:67`)** — replace the `ctx.isOpaque`/`ctx.hasOpaqueChildren` branching
  with the observership gate: for a table child, build/store the content node iff
  `OBSERVERS[child]` is non-empty, else store the live ref; record
  `IDENTITY_OF[contentNode] = child` when building. *Why:* makes the slot shape independent of
  the reconciler — the actual bug fix.
- **`new`/module state** — add the weak-kv `IDENTITY_OF` map; accept (or import) an
  `isObserved(child) -> boolean` predicate over `OBSERVERS`. Prefer **injecting** the predicate
  from `Baseline`/`TableManager` so `ShadowNode` stays decoupled from `Propagation`. *Why:* the
  gate's data source and the identity back-reference.
- **`Get` (`:119`), `Reconcile` (`:128`), `Materialize` (`:146`), `ApplyArrayOp` (`:173`),
  `RebindRoot` (`:209`)** — **unchanged in structure.** Slots keep their existing two shapes
  (content node / live ref), so the walkers behave exactly as today; only `copyForShadow`'s
  decision changed. *Why to call out:* this is the bulk that earlier drafts would have churned;
  the observership framing avoids it.

### `Diff.luau` (opaque branch resolves identity)
- **`liveValue` (`:106`)** — when the value is a baseline content node, return its identity via
  `ctx.identityOf` (falls back to current behavior otherwise). *Why:* lets the opaque
  comparison use the child's real identity instead of the copy — directly kills the spurious
  `"changed"`.
- **`isOpaqueValue` (`:85`) / `make_opaque_leaf` (`:196`)** — verify the opaque path feeds
  through `liveValue` on both sides (it does); no structural change expected.
- Array-aware `arraySink` path (6d) is unaffected (array element slots follow the same
  content-node/ref rule).

### `Baseline.luau` + `ChangeDetector.luau` (wiring)
- Thread the `isObserved` predicate to `ShadowNode` (via `Baseline.NewStore`/the store), and
  add `identityOf` to the `Ctx` built in `ChangeDetector:GetOpaqueCtx` (backed by
  `ShadowNode`'s `IDENTITY_OF`). `CheckForChangesBetween` (`ChangeDetector.luau:322`) passes
  that `Ctx` into `Diff.diff` as it already does. *Why:* the two small dependencies §4 needs,
  kept at the seam.

### Tests
- The §2.1 golden flips GREEN.
- Add per-viewer shared-parent goldens: opaque co-observer never fires for a shared child's
  internals; transparent co-observer still does; both directions; and across a Batch. Also a
  reference-replacement case (opaque child reassigned fires exactly one change).
- **`Docs/CONTRACT.md` §7** — note per-viewer opacity now holds for shared parents too.

### Not in scope (track separately)
- `ListenerRegistry.luau` `SnapshotOldValue` option (§4c) — independent optimization.

---

## 6. Test plan / gate

Run `tests.luau`. Must stay green: `Diff`, `ChangeDetector`, `shadow`, `array-*`,
`batch-lifecycle`, `replication-fidelity` (both feeds), `opaque`, `link`, `extend`,
`MemoryLeaks`. New/changed: the §2.1 golden (now green) and the per-viewer shared-parent
goldens. `replication-fidelity` is the convergence oracle and the primary regression watch.

---

## 7. Risks & open decisions

- **Blast radius is now small.** The behavioral change is concentrated in `copyForShadow`'s
  gate plus `liveValue`'s identity resolution; the node walkers and `oldValue` are untouched.
  This is materially lower-risk than the ref-indirection design it replaces.
- **`copyForShadow` now consults `OBSERVERS`.** Confirm the predicate reflects observership at
  reconcile time (a manager that just began observing a previously opaque-only child triggers
  content-building on the next reconcile that covers it; until then that manager self-seeds via
  `SeedIfNeeded`/`Materialize` — verify no gap in practice).
- **`IDENTITY_OF` must be weak in keys *and* values** so the baseline never pins live tables
  alive (preserves the current "baseline holds copies, not live data" leak-freedom).
- **Reference-replacement of an opaque child to an unmarked table** transitions that slot to
  transparent (the new object isn't opaque) — confirm this matches the intended by-reference
  opacity contract; it converges either way.
- **Scope.** Still a *beyond-contract* edge (the contract's per-viewer example has no shared
  parent). The alternative remains: keep the §2.1 golden `pending` as documentation and treat
  Phase 6 complete. But given the fix is now small and localized, implementing it is the better
  trade.

---

## 8. Fresh-agent execution brief

This section is self-contained: a cold agent should be able to implement the fix from §1–§7
plus the orientation here, without prior context.

### 8.1 Orientation — what you're working on

- **Repo:** `ModulesOnRails`. **Module:** `lib/tablemanager2/src/` — an in-progress,
  from-scratch rewrite of a `TableManager` (a reactive nested-table store with listeners,
  signals, proxies, batching, opacity, and cross-manager linking). Branch `feat/TableManager2`.
  It is **pre-release**, so internal changes don't break external consumers.
- **Read first:** `.github/copilot-instructions.md` (repo guide + style), this whole doc, and
  `lib/tablemanager2/src/Docs/CONTRACT.md` (the observable behavior contract — §7 opacity, §1.2
  `oldValue`).
- **Architecture you must hold in your head (all current as of this writing):**
  - **`ShadowNode.luau`** — the diff *baseline*. A single module-global, weak-keyed
    `REGISTRY: { [liveTable]: contentNode }` (`:59`). `REGISTRY[T]` is a deep-ish copy of T's
    last-emitted content and is intrinsically T's node forever. A node's slot for a table child
    holds **either** the child's content node (transparent) **or** the child's live ref
    (opaque). `copyForShadow` (`:67`) builds nodes; `Get/Reconcile/Materialize/ApplyArrayOp/
    RebindRoot` walk/update them. There is **no** per-manager baseline — `manager._shadow` is a
    thin handle whose `Get` keys on `manager.Raw`.
  - **`Propagation.luau`** — cross-manager linking via a global weak `OBSERVERS:
    { [liveTable]: { [manager]: true } }`. `registerSubtree` (`:145`) records observership as
    tables enter a tree and **skips opaque nodes**, so `OBSERVERS[t]` contains exactly the
    managers that observe `t` **transparently**. This is the signal the fix keys on.
  - **`Diff.luau`** — standalone structural diff. `diff`/`diff_tables` take a `Ctx` oracle
    (`isOpaque`, `hasOpaqueChildren`); the opaque branch (`isOpaqueValue:85`, `liveValue:106`,
    `make_opaque_leaf:196`) compares by identity. `ChangeDetector` calls it.
  - **`ChangeDetector.luau`** — `CheckForChangesBetween` (`:322`) runs `Diff.diff(old, new,
    nil, nil, ctx, arraySink?)` and dispatches the result; `GetOpaqueCtx` builds the `Ctx`.
  - **`Coverage.luau`** — `IsTrackable`/`PassesThroughOpaqueAncestor` gate which writes flush.
  - **`Baseline.luau`** — the seam between flush logic and `ShadowNode` (`Get`/`Reconcile`/
    `Materialize`/`ApplyArrayOp`/`SeedIfNeeded`/`NewStore`).
  - Opacity is **per-manager** (`manager._opaqueRegistries`) plus global variants; the per-
    manager `Ctx` is how a manager's own opacity reaches `Diff`/`ShadowNode`.

### 8.2 Guardrails (do not violate)

- **Do NOT run the test suite yourself.** The human runs `tests.luau` in VS Code (a Roblox
  test place) and reports results. Hand off at each checkpoint and wait.
- **Style** (`.github/copilot-instructions.md`): `const` for never-reassigned bindings,
  `local` otherwise; PascalCase for methods/class fields, camelCase for locals,
  `_`-prefixed privates; relative string requires only; explicit types on non-inferred
  signatures; Moonwave `--[=[ ]=]` doc comments; no magic numbers; match surrounding style.
- **Invariants from prior phases that must still hold (regressions = failure):**
  - Immediate (non-batched) write behavior stays byte-identical; this fix targets baseline
    *storage shape* only.
  - The 6d array-aware batch path (`Diff` `arraySink` → `BatchFlush` LCS) keeps working.
  - Opacity keeps its O(1)/no-copy benefit for **opaque-to-everyone** regions (the gate must
    store a bare ref, not a content node, when `OBSERVERS[child]` is empty).
  - Memory stays bounded by distinct observed identities — **no** per-manager nodes.
  - The baseline never pins live data alive (`MemoryLeaks.spec` guards this) → `IDENTITY_OF`
    must be weak in **keys and values**.
  - `oldValue` semantics unchanged (observed children remain deep copies).

### 8.3 Ordered implementation steps

Land these together (they're interdependent — the golden only flips once all are in), but in
this order for clarity. After the batch, **stop and request a test run**.

1. **`Propagation.luau`** — export `IsObserved(t): boolean` returning
   `OBSERVERS[t] ~= nil and next(OBSERVERS[t]) ~= nil`. *(The fix's gate signal.)*
2. **`ShadowNode.luau`**
   - Add a module-global weak-kv map `IDENTITY_OF` (`setmetatable({}, { __mode = "kv" })`)
     mapping `contentNode → liveTable`, and a module function `ShadowNode.IdentityOf(node)`.
   - In `new`/the store handle, accept an injected `isObserved(child) -> boolean` predicate
     (wired in step 4 to `Propagation.IsObserved`) — keeps `ShadowNode` decoupled from
     `Propagation`.
   - **`copyForShadow` (`:67`)** — replace the `ctx.isOpaque`/`ctx.hasOpaqueChildren` branching
     with: for a table child `v`, if `isObserved(v)` → `out[k] = copyForShadow(v, …)` (build the
     content node, recurse) **and** `IDENTITY_OF[REGISTRY[v]] = v`; else → `out[k] = v` (live
     ref, no recurse). The gate is now observership, applied recursively, ctx-independent.
3. **`Diff.luau`**
   - `Ctx` type: add `identityOf: ((node: any) -> any?)?`.
   - **`liveValue` (`:106`)** — if `snap` has no ref and `ctx.identityOf(v)` returns a value,
     return that identity (so an opaque comparison against a *content node* uses the child's
     real identity, not the copy). Otherwise unchanged.
   - Confirm `isOpaqueValue`/`make_opaque_leaf` feed both sides through `liveValue` (they do).
4. **`Baseline.luau` + `TableManager.luau`** — when constructing the store
   (`Baseline.NewStore`), pass `Propagation.IsObserved` (or a closure) as the `isObserved`
   predicate. *(Watch require direction; `Baseline` already requires `Propagation`? if not,
   inject from `TableManager.new`, which requires both.)*
5. **`ChangeDetector.luau`** — in `GetOpaqueCtx`, add `identityOf = ShadowNode.IdentityOf` to
   the returned `Ctx`. Add the `require("./ShadowNode")` (verify acyclic — `ShadowNode` requires
   only `PathHelpers`/`Diff`, so `ChangeDetector → ShadowNode` is fine).
6. **Tests** — the §2.1 golden in `Tests/TM/TableManager.opaque.spec.luau` should now pass.
   Add the extra goldens from §5 (transparent co-observer still sees the child change; both
   directions; across a `Batch`; opaque-child reference-replacement fires exactly once).
   Update `Docs/CONTRACT.md` §7.

### 8.4 Verification / acceptance

- Hand the human the change set and ask them to run `tests.luau`. **Acceptance:** the §2.1
  golden is GREEN and the **entire** suite is green — especially `replication-fidelity` (both
  feed modes, the convergence oracle), `opaque`, `shadow`, `array-*`, `batch-lifecycle`,
  `MemoryLeaks`, `link`, `extend`.
- If anything is red, report the spec + test name + first error line and fix before moving on;
  do not stack further changes on a red suite.

### 8.5 Open verifications (call out if hit)

- Observership timing: `registerSubtree` runs before `_doFlush` in a write, so `OBSERVERS`
  reflects current state when `copyForShadow` runs — confirm no path reconciles a child before
  its transparent observer is registered (if found, the observer self-seeds via
  `SeedIfNeeded`/`Materialize`; verify convergence).
- Reference-replacement of an opaque child to an *unmarked* table makes that slot transparent
  (the new object isn't opaque). Confirm against CONTRACT §7 intent; it converges either way.

### 8.6 Out of scope

- The `SnapshotOldValue` listener option (§4c) is an independent optimization — do **not**
  implement it as part of this fix.
