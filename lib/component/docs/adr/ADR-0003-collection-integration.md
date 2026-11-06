# ADR-0003: Collection API integration — selectors as the primary attachment and matching language

- **Status:** Accepted (waves 1–4 + 6 implemented in v1.1.0; wave 5 staged for v2.0.0; wave 7 gated on production ungate)
- **Date:** 2026-08-13
- **Context sources:** empirical probe suite `test/collection_probe/` (production via Open Cloud + Studio, both SignalBehavior modes); design log in the project plan

## Context

Roblox shipped an engine-native `Collection` datatype —
`CollectionService:CreateCollection(selector, root?)` returning a
`CollectionHandle`: a live, CSS-like selector-driven instance set with
lifecycle/event callbacks. It overlaps the matching/watching half of this
package. Rather than compete, **Component repositions as the stateful
lifecycle/extension layer above Collection**: selectors become the primary
attachment/matching language, the engine-native backend slots in behind a
capability probe when available, and Component keeps everything Collection
lacks — per-instance stateful objects, Construct/Start/Stop with stop
reasons, extensions, Janitor cleanup, typed classes, arbitrary predicates,
and cross-class queries.

## Empirical findings the decisions rest on (probe, engine 0.734)

1. **Availability**: `CreateCollection` exists everywhere but is
   server-gated ("Collections are not enabled"); the Studio Beta Features
   checkbox ungates Studio only — **production and therefore CI remain
   gated**. Feature detection must be a functional pcall create/destroy
   probe (`src/CollectionSupport.luau`); `typeof` is insufficient.
2. **Dispatch is SignalBehavior-governed, not an async queue** (docs
   claiming unconditional async queueing are wrong): synchronous during the
   mutating call under Immediate, same-frame invocation-point deferral under
   Deferred — the identical envelope to classic signals, so our
   direct-connection fallback matches native behavior automatically.
3. **No membership coalescing in either mode**: same-cycle retag or
   attribute flip delivers both edges, order preserved. The edge-driven
   supersede semantics of v1 are therefore preserved for BOTH attachment
   spellings — no semantic break anywhere. `test/collection_probe/` is kept
   frozen as a regression canary in case Roblox ever aligns the engine with
   its documented model.
4. **Native grammar matrix**: class selectors use IsA semantics; comma
   OR-groups work (undocumented); float literals, `Enum.X.Y` paths, `*`,
   and ALL comparison/pattern operators are rejected; native attribute
   equality is **type-coerced** (`[$N = 5]` matches `"5"`). Consequently the
   dialect's residual matchers carry complete semantics and the native form
   is only ever a tracking superset.
5. **Wrapper hooks**: single-assignment is permanent; unknown names error;
   mixed classes silently skip; post-removal delivery is real under Deferred
   (a dispatch guard is mandatory); `OnHeartbeat` is 1 call/member/frame.
6. **Roots**: non-Workspace roots work; nested roots double-member (union
   needs refcounting); root destruction fires member removals then kills
   the handle (second `Destroy()` errors — janitor guards required).
7. **Fallback costs**: 1000-descendant root cold scan ≈ 0.16 ms; descendant
   watcher ≈ 0.36 µs/event; `GetTagged`(300) ≈ 0.05 ms. The pure-Luau
   fallback is viable **permanently** for scoped roots.
8. **Late wrapper assignment** (second frozen canary,
   `test/collection_probe/late_hooks.luau`, both modes): assignment
   connects **synchronously** — an event triggered in the same resumption
   cycle as the assignment delivers, with no warm-up window, even for a
   member that joined in that same cycle; nothing from before the
   assignment is replayed (except `OnAdded`'s documented existing-member
   sync, which works at any assignment time). Assigning `nil` errors
   ("Expected function, got nil") and reassignment errors ("Callback X
   already assigned" — even with the identical function; the original
   keeps firing). Native wrapper callbacks are **declare-once, immutable,
   and live for the whole membership window**.

## Decision

### D1 — Selector dialect, lowered onto the existing query IR
A superset of the native grammar (`= != > >= < <= ~ :typeof(t)`, plus the
native structural terms) parsed by `src/Query/Selector.luau`. Every bracket
term lowers to residual `Attr`/`Prop` MatchSpecs carrying **complete,
type-exact** semantics (the fallback path has no native half); the native
selector string is computed alongside as the tightest sound superset, with
`:not(...)` dropped from the native form unless its inner is exactly
expressible (widening a `:not`'s inner narrows the outer set — the unsound
direction). Parse results (and their matcher closures) are cached per
canonical form so equivalent spellings intern into one engine. Dialect
semantics that intentionally differ from native: `[$X = "5"]` is
type-exact; `[$X != v]` matches absent; comparisons are numbers-only; `~`
is strings-only, pattern-validated at build time.

### D2 — `Query.Selector(selector, root?)` node
`Build.Selector` lowers each comma group to an `And` of existing primitives
(tag strings, attr/prop filter nodes, `Not` nodes) around **one new node
kind**: a root-scoped IsA seed (`SelectorSource`) enumerated from
`root:GetDescendants()` and watched via `DescendantAdded` /
`DescendantRemoving` (removal re-checked after a `task.defer` — the signal
fires before the reparent settles). Multi-group selectors become an `Or`,
riding the engine's existing `_anyOf` machinery. Nodes are cached per
(normalized selector, root) so `:not` predicate closures keep one identity.
`>` / `>>` / `:has()` error until the native backend lands (wave 7).
ClassNames are not validated — `IsA` never errors, so a typo matches
nothing, same as native/CSS.

### D3 — ONE unified driver; edge semantics preserved
`Component.new` accepts `Selector` XOR `Tag`. Selector classes activate one
interned query engine per `Ancestors` root (track-style `changed`
connections, no per-match janitors) mapping edges to
`Lifecycle.Request`/`Release`; membership is the union across roots
(released only when no engine still matches). Because both the native API
and our fallback are edge-faithful (finding 3), **v1's same-frame supersede
protocol holds identically for selector classes** — verified by a parity
spec. Stop reasons map with the same rule the tag driver always used, plus
`SelectorUnmatched` for "still parented but stopped matching"; new
`Disabled` reason backs `Class:SetEnabled(bool)` (mirroring
`Collection.Enabled`, including reconstruction of instances that appeared
while disabled). `GetCreateFromInstance` stays tag-only. Tag classes are
byte-identical in v1.x; **wave 5 (v2.0.0)** lowers `Tag = "X"` to
`Selector = ".X"` through this driver and deletes the bespoke tag wiring
(`Untagged` preserved, keyed on seed kind).

### D4 — Collection-style hooks with full native parity (amended, wave 8)
Lifecycle names align with Collection: `OnConstruct`/`OnStart`/`OnStop`
primary (legacy aliases through v1.x, `On*` wins when both defined);
`HeartbeatUpdate → OnHeartbeat`, `SteppedUpdate → OnPreSimulation`,
`RenderSteppedUpdate → OnPreRender`. Any other `On*` method is a member
event hook (`OnTouched` → `instance.Touched`), and
`Class.OnAttributeChanged.X` / `Class.OnPropertyChanged.X` namespace tables
(seeded by `Component.new`; DOT-form declaration — the colon form binds
`self` to the namespace table) wrap the per-name changed signals.

Hook semantics match the probed native contract (finding 8) exactly:

- **Registry + interception, no scans.** Every class's metatable is the
  shared `Component` table; its `__newindex` routes hook-shaped new-key
  writes into a per-class registry (`ClassInternal.hooks`) instead of the
  class table, and the namespace tables intercept their own entries the
  same way. Because hook keys are never stored raw, every write re-fires
  the interceptor — which is what makes declare-once ("already assigned"),
  nil-rejection, and non-function rejection enforceable errors, exactly as
  native. Registration connects the hook to every live instance in the
  same cycle; instances constructed later connect from the registry.
  (Metamethod lookup is raw, so the interceptor cannot leak into component
  INSTANCE field writes.)
- **Live from successful construction to teardown-begin** (native hooks
  cover the whole membership window): connections are made in the
  Constructed tracking block, so events during the yieldable start window
  deliver; changes during the construct phases never do. The dispatch
  guard is `instToComponents[instance] == component` — untracking is
  synchronous at release, so a released or superseded component's hooks
  are silenced before their deferred physical disconnection (required
  under Deferred, finding 5).
- **Hooks are callbacks, not methods**: post-hoc declarations are not
  readable back off the class. Hooks declared via the config `Methods`
  table are additionally rawset (they are part of the typed class surface
  and stay callable); redefining one of those post-hoc is the single
  non-interceptable edge and is documented undefined.
- **Extension hooks are additive connections**, not entries in the class's
  single-assignment surface: an extension's `Hooks` table
  (`OnTouched = fn`, `OnAttributeChanged = { X = fn }`) is validated and
  flattened at `_setup` (`Extensions.CollectHooks`), connected per
  instance alongside class hooks (respecting `ShouldExtend`), and coexists
  with same-name class hooks and other extensions' hooks — as if the
  extension had connected manually in construct and disconnected in stop.
  Hook-shaped keys in extension `Methods` error with guidance.

The started-tag bridge Collection (probe-validated gap-free) is a
per-hook-kind backend swap reserved for wave 7; `Sync = true` per hook
will pin direct wiring.

### D5 — API prune, deep-not-wide
Deprecated in v1.1.0, removed in v2.0.0: `:withAny` (→ comma groups),
`:without` (→ `:not(...)`), `:withAttribute` / `:withProperty` value forms
(→ bracket terms). Demoted to internal IR (runtime kept, docs `@ignore`):
`Query.And/Or/Not/Pred`. Kept permanently: `:with` (component classes are
runtime objects — started-set probes, not expressible in strings),
`:where`, `Query.Attr`/`Query.Prop` (function matchers with per-name
re-evaluation), `Query.Sub`, all read terminals, and — per explicit
decision — the `GetOrCreateFromInstance` / `GetMatches` aliases (their
missing type exports fixed instead).

### D6 — Typing
`TypedClass` gains the `On*` lifecycle members, namespace tables typed
`{ [string]: (self) -> () }` (indexer scoped to those tables only — the
class keeps its deliberate no-indexer design), `SetEnabled`, `Selector`,
and the previously missing `Has`/`GetCreateFromInstance`/`GetMatches`.
Event-wrapper hooks are declared via the config `Methods` table to stay
fully typed. The selector-string → instance-type inference (type function
over the string singleton + generated ClassName map) is a prototype-gated
stretch (wave 7).

## Consequences

- Everything user-facing works TODAY on the pure-Luau fallback; the native
  Collection backend is strictly a perf swap (Runtime's selector source +
  the hook bridge), justified by a T8-vs-T9.6 benchmark when production
  ungates, behind `CollectionSupport`.
- Selector classes cost O(root descendants) at activation and per
  enumeration — scoped `Ancestors` roots are the documented recommendation;
  whole-Workspace roots in huge games are the known ceiling.
- The probe suite is a frozen canary; a T3.3/T3.4 failure means Roblox
  changed edge semantics and the supersede contract needs re-evaluation.
- v2.0.0 (wave 5) is a deletion-heavy internals swap gated on the entire
  v1.x spec suite passing unmodified, plus removal of legacy lifecycle
  names and deprecated chain builders.

## Verification (as implemented)

- 169 specs green on real Roblox (`lune run coverage.luau package=component`),
  including: dialect grammar/lowering matrix, selector-query reactive +
  cold-read behavior, hook lifecycle windows, selector-class lifecycle with
  every new StopReason, same-frame supersede parity, SetEnabled round-trips
  on both class kinds.
- `luau-lsp analyze --flag:LuauSolverV2=true` clean over `src/` and the
  `Component.types.luau` regression file (which also caught and fixed a
  pre-existing `ComponentConfigOf.Ancestors` union-exactness regression).
- Probe canary re-run post-implementation: engine behavior unchanged.
