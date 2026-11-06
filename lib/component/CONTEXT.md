# Component

Binds reusable, class-based behavior to tagged Roblox instances, with a
yield-tolerant lifecycle and world-level queries. This context covers the
vocabulary for the lifecycle, extensions, cleanup, and querying. (`src/init.luau`'s
doc comment is the usage guide; this file is only the language.)

## Language

**Component class**:
The object returned by `Component.new{ Tag = ... }`. One per CollectionService
tag. Holds the lifecycle callbacks (`Construct`/`Start`/`Stop`), the `Started`/
`Stopped` signals, and the class-level tracking tables.
_Avoid_: component (ambiguous — say class or instance)

**Component instance**:
A live instance of a component class, bound to exactly one Roblox instance. What
`Construct`/`Start`/`Stop` run on as `self`, and what `FromInstance` returns.
_Avoid_: object, entity

**Roblox instance**:
The tagged `Instance` a component instance is bound to, always reachable as
`self.Instance`.
_Avoid_: part, target

**Valid ancestors**:
The `Ancestors` list (default `{workspace, Players}`). A tagged instance only
constructs while it is a descendant of one of them; leaving them tears the
component down.
_Avoid_: whitelist, scope

**Extension**:
A table hooking into the lifecycle. Contributes hooks (below), `Methods` bound
onto the class, a `ShouldConstruct` veto, a per-instance `ShouldExtend` toggle,
and nested `Extensions` treated as dependencies. Extensions are resolved in
topological order (dependencies first).
_Avoid_: plugin, mixin

**Hook**:
An extension's per-phase callback: `Constructing`, `Constructed`, `Starting`,
`Started`, `Stopping`, `Stopped`. Distinct from the component's own lifecycle
_methods_ (`Construct`/`Start`/`Stop`), which the class itself defines.
_Avoid_: lifecycle method (that's the component's own, not the extension's)

**Lifecycle phase**:
Where a component instance is: `None` → `Constructing` → `Constructed` →
`Starting` → `Started` → `Stopping` → `Stopped`. Reported by
`GetLifecycleStatus`.
_Avoid_: state (overloaded)

**Phase barrier**:
The synchronization point at the end of a phase. Every active extension's hook
for that phase is gated on dependency order — a hook starts only once the hooks
it depends on have finished — while hooks with no dependency edge between them
run concurrently. The phase completes only once all of them (and any Promise
they return) have finished. Construct phases run inline and hold up the
construction chain; start and stop phases are deferred (`task.defer`), and stop
phases gate in reverse (dependents first).
_Avoid_: await point, gate

**Construction request**:
A claim on a Roblox instance's construction slot for one component class, made
when a tagged instance enters its valid ancestors. Two requests in the same frame
collapse into one (the slot is reserved synchronously), and a later request
supersedes an earlier one still in flight — a driver that is parked before it has
published itself, as a yielding `ShouldConstruct` is, can only be caught this way
and stops with reason `Superseded`. Owned entirely by the lifecycle engine; no
other module reads or writes the slot.
_Avoid_: pending, lock (those are the fields, not the concept)

**Teardown**:
The single guaranteed removal path, run once construction has begun: untrack →
`Stopping` hooks → `Stop(reason)` → `Stopped` hooks → **core Janitor destroy**.
Runs on every removal (untag, ancestry exit, instance/class destroyed, cancelled
construction).
_Avoid_: cleanup (say teardown for the whole sequence; cleanup for a single task)

**Stop reason**:
Why teardown is happening, passed to `Stop`: `Untagged`, `LeftAncestry`,
`InstanceDestroyed`, `ClassDestroyed`, `ConstructionCancelled`, or `Superseded`.
_Avoid_: cause

**Core Janitor / Task**:
The per-instance Janitor created when construction begins. Anything registered
via `self:AddTask(...)` / `AddPromise` is a _task_ and is cleaned up during
teardown, on any path — the framework's cleanup guarantee.
_Avoid_: trove (this package uses Janitor exclusively)

**Query**:
A reusable, reactive description of "instances matching these requirements",
built with `Component.query(...)`. Terminal operations are `:observe` (reactive)
and the one-shot reads `:GetMatches`/`:get`, `:iter`, `:count`, `:first`, and
`:contains` (all O(1) off the live engine while the query is observed).
_Avoid_: filter, selector

**Requirement**:
One clause of a query: a component class (satisfied while _started_ on the
instance), a tag string (satisfied while the raw tag is present), another
Query (satisfied while it matches), a filter node (`Query.Attr` / `Query.Prop`
/ `Query.Pred` — a value test; refinement-only), or a combinator node
(`Query.And` / `Query.Or` / `Query.Not` — boolean composition, nests freely).
Combined via `:with` / `:withAny` / `:without` / `:withAttribute` /
`:withProperty` / `:where`.
_Avoid_: condition (reserve for `:where` predicates)

**Compose by value / by reference**:
Requirements are normalized at build time: one logical shape has one internal
form (one signature, one engine) regardless of spelling. A raw Query composes
_by value_ — its clauses are spliced (positive position) or lowered to an
equivalent node (`:withAny` / `:without`), so `Query(q1):with(B)` is literally
`q1:with(B)`. `Query.Sub(q)` composes _by reference_: the one spelling that
keeps `q` as a live nested sub-query with its own shared engine.
_Avoid_: nested query (say sub-query only for the `Sub` form)

**Match / Observer**:
An instance _matches_ a query while all its requirements hold. An _observer_
(from `:observe`) runs a callback with a fresh Janitor for each match and
destroys that Janitor when the instance stops matching.
_Avoid_: hit, subscriber
