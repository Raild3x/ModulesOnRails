# ProxyGraph — Design Document & Implementation Plan

> This document captures the complete design for a new standalone Luau reactive data-graph library. It is intended as a handoff document for implementation. Read it in full before writing any code.

---

## Part 1 — Design Document

---

### 1. Overview

ProxyGraph is a reactive data-graph library for Luau (Roblox). Every value in the graph — including scalars — is wrapped in a proxy node. Observers attach directly to node references, not to path strings. There is no central "manager" object. Data and reactivity are fully decoupled from lifecycle management.

**Design priorities in order:**
1. Readability and maintainability
2. Extensibility
3. No unnecessary computation — singular changes must not trigger global processing

**Core properties:**
- Every value (table, scalar, array) is a `Proxy<T>` node
- Proxies can have multiple parents (true graph, not tree)
- `Observer(proxy)` is the explicit interface for attaching listeners
- `peek(proxy)` / `:Get()` unwraps to the raw value
- `proxy.field = value` is fully type-safe via read/write type asymmetry
- Scopes provide lifecycle management with implicit or explicit registration
- Computeds are lazy — only recompute when observed or read

**What this is NOT:**
- A replacement for TableManager2 (different paradigm, new package)
- A serialization system
- A networking layer

---

### 2. Type Hierarchy

```
UsedAs<T>  =  State<T>  |  T         -- "reactive or constant" — accepted everywhere reads happen

State<T>                              -- readable, observable, participates in the graph
  └── Proxy<T>                        -- extends State<T> with write capabilities
```

`State<T>` is what `Computed`, `ForValues`, and any read-only derived value produces. `Proxy<T>` is what `Graph.new()` returns. APIs that only read accept `State<T>`. APIs that need write access require `Proxy<T>`.

`UsedAs<T>` is the union accepted by `use()` inside Computeds/Effects and by `peek()`. Passing a raw value to `use()` is a no-op passthrough — no dependency is tracked. This means a constant can be passed anywhere a `State<T>` is expected without special casing.

---

### 3. Proxy System

#### 3.1 Unified Proxy Node

A single `ProxyNode` class handles all three modes. The mode determines which operations are valid at runtime and which types are valid at the type-checker level.

| Mode | Created when | Operations |
|---|---|---|
| **Scalar** | Value is a non-table primitive | `:Get()`, `:Set(T)` |
| **Table** | Value is a plain table (non-array) | `:Get()`, `:Set(T)`, `:Remove(key)`, `proxy.key` read/write, `OnKeyAdded`, `OnKeyRemoved` |
| **Array** | Value is an all-numeric-key table | `:Get()`, `:Set(T)`, `:Insert(i, v)`, `:Remove(i)`, `:Find(v)`, `OnArrayInserted`, `OnArrayRemoved`, `OnArrayShifted` |

Proxies are `newproxy(true)` userdata. All state lives in module-level tables keyed by proxy identity (same pattern as TableManager2's ProxyManager). The proxy carries no Lua-visible fields.

#### 3.2 Read/Write Type Asymmetry

Luau's type function API provides `tabletype:setreadproperty` and `tabletype:setwriteproperty` independently. The `ProxyWrap` type function uses this to declare:

- **Read** of `proxy.field` → `Proxy<FieldType>` — enables `:Get()`, `:Set()`, `Observer()` chaining
- **Write** of `proxy.field = value` → accepts `FieldType` directly — natural assignment syntax

Both work simultaneously. No compromise needed.

```lua
proxy.health = 75              -- ✓ write: number
local hp = proxy.health:Get() -- ✓ read: Proxy<number> → Get() → number
Observer(proxy.health)         -- ✓ read: Proxy<number>
proxy.health:Set(75)           -- ✓ also valid
```

#### 3.3 Child Proxy Caching

`_children: { [key]: ProxyNode }` is maintained per table-mode proxy. `__index` checks this map first; only on miss does it create a new child node. The child is then stored in `_children` and returned on all future accesses.

**Consequence:** `proxy.health == proxy.health` is always `true`. Holding a reference to `proxy.health` gives a stable node that tracks that path for its lifetime. Structural reconciliation (via `:Set()`) updates the cached proxy's value in-place — the proxy object identity is preserved across value changes.

#### 3.4 Multi-Parent Graph

A single ProxyNode can be placed in multiple parent TableProxy nodes simultaneously. This is the core structural departure from TableManager2.

```lua
local sharedBuff = Graph.new({ power = 20 })
player1.activeBuff = sharedBuff   -- __newindex assigns the node by reference
player2.activeBuff = sharedBuff
sharedBuff.power:Set(30)          -- fires OnChange on BOTH parent chains
```

**Parent tracking:** Each proxy maintains `_weakParents: { [parentProxy]: key }` using a weak-keyed metatable. Parents hold strong references to children via `_children`. Children hold weak references to parents. When a parent is GC'd, its entry disappears from the child's `_weakParents` automatically.

**Consequence:** A child proxy outlives its parent if the user holds a reference to it — it just stops propagating to the GC'd parent.

#### 3.5 Proxy Construction

```lua
-- Explicit, typed (full autocomplete)
type PlayerData = { health: number, stats: { power: number } }
local player: Proxy<PlayerData> = Graph.new({ health = 100, stats = { power = 10 } })

-- Untyped (functional but no field autocomplete)
local player = Graph.new({ health = 100 })

-- With options
local player = Graph.new(initialData, {
    mirror = rawTable,           -- keep rawTable in sync with all writes
    ShouldBeOpaque = function(key, value)
        return key == "snapshot"  -- auto-treat this key as atomic
    end,
})
```

#### 3.6 Reconciliation — `:Set()` With Existing Children

When `proxy:Set(newData)` is called on a table-mode proxy:
1. A structural diff runs between the current value and `newData` (reuses `Diff.luau` from TableManager2)
2. For each key that changed: update the cached child proxy's value in-place via its own internal setter (so the child's own observers fire)
3. For new keys: create and cache a new child proxy, fire `OnKeyAdded`
4. For removed keys: detach the child proxy from `_children`, clear its `_weakParents` entry, fire `OnKeyRemoved`, fire `OnOrphaned` on the detached child

`:Get()` returns a deep copy of the underlying raw data as a plain Lua table — not a proxy. Mutations to the copy do not affect the graph until `:Set()` is called.

---

### 4. Opaque Values

An opaque value is stored atomically — no child proxies are created for its fields, no structural diff runs when it changes. It IS read-transparent: `proxy.config.theme` returns the raw string directly by reading into the inner table, but no `Proxy<string>` node is created for `theme`.

**Type-level:** `Opaque<T>` is a branded type tag in schema declarations. The `ProxyWrap` type function detects it and emits raw field types for reads rather than `Proxy<FieldType>`.

**Runtime — two write paths:**
- `proxy.config = Graph.Opaque(value)` — wrapper for `=` assignment syntax. `__newindex` detects the wrapper tag, strips it, stores the inner value atomically.
- `proxy.config:Set(value, { opaque = true })` — option on `:Set()`, no wrapper allocation.

**Per-slot flag:** When a slot is written opaquely, `_isOpaque[key] = true` is recorded on the parent proxy. Reconciliation checks this flag and uses identity comparison (`~=`) instead of structural diff.

**`ShouldBeOpaque` predicate** on `NewOptions`: runs during construction and `__newindex` to auto-classify fields as opaque based on key or value characteristics. Useful for schema-free proxies with consistent patterns.

---

### 5. Signal and Observer System

#### 5.1 Signal

`Signal<T...>` is a lightweight connection set. The connection count is tracked for fast shortcircuiting.

```lua
export type Signal<T...> = {
    Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
    Once:    (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
}
```

Signals are stored directly on each ProxyNode. They are not shared or cached outside the node.

**Connection lifecycle:** Connections are held strongly by the proxy's signal. They persist until `:Disconnect()` is called, the owning Scope is destroyed, or a `Once` connection fires. There is no `__gc` in Luau — automatic cleanup requires Scopes.

#### 5.2 Observer

`Observer(state)` returns a thin object exposing the node's signals by event type, without polluting the data key namespace of `Proxy<T>`.

```lua
export type Observer<T> = {
    OnChange:        Signal<T, T?>,              -- fires when THIS node OR any descendant changes
    OnValueChange:   Signal<T, T?>,              -- fires when THIS node's exact value is replaced
    OnKeyAdded:      Signal<string, State<any>>, -- table-mode only
    OnKeyRemoved:    Signal<string, State<any>>, -- table-mode only
    OnArrayInserted: Signal<number, any>,         -- array-mode only
    OnArrayRemoved:  Signal<number, any>,         -- array-mode only
    OnArrayShifted:  Signal<number, number, any>, -- array-mode only
}
```

`Observer(proxy.stats.health).OnValueChange:Connect(fn)` is the primary observation syntax. The `.OnChange:Once(fn)` pattern fires once then auto-disconnects.

---

### 6. Change Propagation Engine

#### 6.1 Scalar Write Path

```
proxy.health:Set(75)
  ├── no-op check: newValue == _value? → return immediately
  ├── capture oldValue
  ├── _value = newValue
  ├── fire _onValueChangeSignal (if _connectionCount > 0)
  ├── fire _onChangeSignal on self (if _connectionCount > 0)
  └── _walkParents(generation, newValue, oldValue)
```

#### 6.2 Parent Walk

```
_walkParents(generation, new, old)
  for each (parent, key) in _weakParents:
    if parent._notifyGeneration == generation: skip (dedup)
    parent._notifyGeneration = generation
    fire parent._onChangeSignal (if connectionCount > 0)
    parent._walkParents(generation, ...)  -- recurse
```

The `generation` is a module-level integer bumped at the start of each top-level write (or batch flush). This prevents duplicate notifications in diamond-shaped graphs and eliminates infinite loops from cycles.

#### 6.3 Table Write Path (`__newindex`)

When `proxy.stats = newValue` or `proxy:Set(newData)` is called:
1. If same reference as current: no-op
2. If target key has `_isOpaque[key]`: identity compare, fire `OnValueChange` if different, no diff
3. Otherwise: reconcile child proxies (structural diff via `Diff.luau`)
4. Fire `_onValueChangeSignal` on the target child proxy (if the child's value changed)
5. Walk parents

#### 6.4 Batch System

`Graph.Batch(fn)` defers all signal firing until `fn` completes.

- Module-level `_batchDepth: number` counter
- While `_batchDepth > 0`: writes coalesce into `_pendingChanges: { [ProxyNode]: { old, new, generation } }`
- Coalescing rule: keep the **original** `old` value, always update to the **latest** `new` value
- Multiple writes to the same node produce exactly one notification
- On `_batchDepth` reaching 0: flush all pending changes in write-order, firing all signals

---

### 7. Reactive Derivations

#### 7.1 Computed

A `Computed` is a read-only `State<T>` whose value is automatically recomputed when its dependencies change. It is returned by `Graph.Computed(fn)` or `scope.Computed(fn)`.

**Dependency tracking:** `use(stateValue)` inside the Computed callback reads the current value AND registers the accessed `State<T>` as a dependency. A module-level "current tracker" is pushed before executing the callback and popped after.

**State machine (three states):**
- `Clean` — value is current; `:Get()` returns immediately without recompute
- `Stale` — a dependency changed; `:Get()` triggers recompute before returning
- `Recomputing` — currently executing (for cycle detection)

**Lazy by default:** When a dependency fires, all dependents are marked `Stale`. A `Stale` Computed with no active `OnValueChange` listeners sits dormant — no recomputation occurs. Only when it has observers OR when `:Get()` is called does it recompute.

**Dep diffing between runs:** After each run, compare the new dependency set against the previous one. Only add connections for new deps; only remove connections for dropped deps. Stable deps retain their existing connections — zero teardown/rebuild overhead.

**Inner scope:** Each Computed evaluation runs inside a derived child scope. Before re-evaluating, the previous inner scope is destroyed (cleaning up any reactive objects created during that evaluation). After re-evaluating, the new inner scope becomes the child.

Computed results are `State<T>` (read-only). `:Set()` is a type error.

#### 7.2 Effect

An `Effect` runs a side-effect function reactively. Same dependency tracking mechanism as Computed via `use()`. No return value. Returns a `Connection` (stop handle).

**Per-run sub-scope:** Each execution of the Effect callback runs inside a fresh derived scope (child of the Effect's parent scope). When the Effect re-runs (a dep changed), the previous run's scope is destroyed first — cleaning up all reactive objects created inside it. This is the primary mechanism for "create a Computed inside an Effect and have it clean up automatically on re-run."

**Re-run scheduling:** When a dep fires, the Effect is added to a "needs re-run" queue. The queue is processed synchronously unless batching is active (in which case it flushes with the batch). Effects do not re-run while already rerunning (cycle protection).

#### 7.3 ForValues

`ForValues(source, mapFn)` produces a derived `State<{TOut}>` array whose entries are the results of mapping each entry of `source` through `mapFn`. Updates are incremental:

- Source item added → create a per-item derived scope, run `mapFn` inside it, add result to output
- Source item removed → destroy per-item derived scope (cleans up any reactive objects created for that item), remove from output
- A source item's value changes → per-item scope is treated like an Effect re-run: destroy previous run scope, re-run `mapFn` with fresh scope

Dependencies declared via `use()` inside `mapFn` are per-item. A change to item 3 only re-maps item 3.

---

### 8. Scope System

#### 8.1 `Scope<T>` — Generic Type

```lua
export type Scope<T = GraphMethods> = T & {
    Destroy: (self: Scope<T>) -> (),
    derive:  (self: Scope<T>) -> Scope<T>,
    addTask: (self: Scope<T>, destructor: () -> ()) -> (),
}
```

`T` defines the constructor methods available on the scope. Defaults to `GraphMethods` (all built-in constructors). Custom method providers are merged via `Graph.scoped()`.

**Scopes are arrays of destructors** (Fusion pattern). Every constructor called through a scope appends its cleanup function. `scope:Destroy()` iterates in reverse order and calls each destructor.

**`derive()`** creates a child scope registered with the parent. Children are destroyed when the parent is destroyed. A derived scope can also be independently destroyed before the parent.

**`addTask(fn)`** appends a raw destructor — for non-reactive cleanup (destroying Instances, disconnecting non-graph connections, etc.).

#### 8.2 `Graph.scoped()` — Constructor Merging

```lua
Graph.scoped: <T>(...: T) -> Scope<T>
Graph.Scope = function() return Graph.scoped(Graph) end  -- convenience
```

All constructor methods called through a scope (`scope.Observer`, `scope.Computed`, etc.) automatically:
1. Register the created connection/object with the scope's destructor list
2. Push the scope (or an inner scope for Effects) as the current owner on the calling thread

Custom extensions integrate cleanly:
```lua
local GameUtils = {
    OnCriticalHealth = function(scope, proxy, fn)
        return scope.Observer(proxy.health).OnValueChange:Connect(function(hp)
            if hp < 25 then fn(hp) end
        end)
    end,
}
local scope = Graph.scoped(Graph, GameUtils)
scope.OnCriticalHealth(player, fn)   -- tracked automatically
```

#### 8.3 Implicit Scopes — Coroutine-Keyed Owner Stack

A module-level `_threadStacks: { [thread]: {Scope} }` table (weak keys) maps each coroutine to its owner stack.

- `Graph.root(fn) -> cleanup` — creates a Scope, pushes it as owner, runs `fn`, pops, returns `scope:Destroy`
- `Graph.getScope() -> Scope?` — returns current innermost owner on the calling thread
- `Graph.withScope(scope, fn)` — explicitly pushes a scope as owner for the duration of `fn`

**Yielding is safe:** yield/resume on the same coroutine preserves the thread's stack entry exactly.

**`task.spawn` creates a new coroutine** with an empty stack. Implicit scope does not propagate across `task.spawn`. Use `Graph.withScope` to carry scope across async boundaries.

Any `Graph.Observer()`, `Graph.Computed()`, `Graph.Effect()` call that occurs while an owner is on the stack auto-registers its cleanup with that owner. The `scope.Method()` forms do the same explicitly.

#### 8.4 Effect and Computed Inner Scopes

When an Effect or Computed re-evaluates:
1. Destroy the inner scope from the previous run: `_innerScope:Destroy()`
2. Create a new inner scope: `_innerScope = parentScope:derive()`
3. Push `_innerScope` as the current owner on the calling thread
4. Execute the callback
5. Pop `_innerScope`

Anything created inside the callback (reactive or not) is registered with `_innerScope` and lives exactly as long as that run. `Graph.getScope()` inside the callback returns `_innerScope`.

---

### 9. Internal Optimizations

These are not optional — they are required to meet the performance priority.

#### 9.1 No-Op Detection at Write Time
Before any propagation machinery runs, check `newValue == oldValue`. For scalars, this is primitive equality. For table nodes being replaced via `:Set()`, check reference equality first — if `newData == currentRawValue`, skip entirely. Zero events, zero propagation.

#### 9.2 Signal Shortcircuit
Every `Signal` maintains `_connectionCount: number`. Before iterating connections to fire, check `_connectionCount > 0`. If zero, return immediately. This is the most impactful optimization — the common case is nodes with no active listeners.

#### 9.3 Generation-Stamp Deduplication
A module-level `_generation: number` is incremented at the start of each top-level write (outside a batch) or at batch flush. Each ProxyNode stores `_lastNotifiedGeneration`. During parent walk, if `parent._lastNotifiedGeneration == _generation`, skip that parent. This makes diamond-graph propagation O(nodes) not O(paths), and prevents infinite loops from structural cycles.

#### 9.4 Batch Coalescing
Within a batch, multiple writes to the same node collapse into one notification. The `_pendingChanges` table stores `{ originalOld, currentNew }` per node. The `originalOld` is set on first write and never overwritten; `currentNew` is always updated to the latest value. Result: exactly one notification per written node per batch regardless of write count.

#### 9.5 Computed Stale/Clean State Machine
A Stale `Computed` with zero `OnValueChange` connections sits dormant. No recomputation on dep change, no allocation, no propagation — just a flag flip. Recomputation occurs only when:
- `:Get()` is called and state is `Stale`
- A dep changes AND `_onValueChangeSignal._connectionCount > 0`

This ensures pure derivations that nobody is watching are completely free at runtime.

#### 9.6 Dep Diffing in Computed/Effect Re-Runs
The dependency set from the previous run (`_prevDeps`) is compared against the new one after each re-evaluation. Stable deps (in both sets) keep their existing connections — zero teardown/rebuild. Only newly added or dropped deps modify the connection set. For Effects that track 10 deps and only 1 changes, 9 connections survive untouched.

#### 9.7 Lazy Child Proxy Creation
`_children[key]` is populated on first `__index` access, not during construction. A 200-field data object accessed at 5 paths creates 5 proxy nodes, not 200. Large infrequently-accessed subtrees have zero overhead.

#### 9.8 Opaque Field Shortcircuit
Opaque slots skip structural diff entirely. Identity comparison (`~=`) determines if a change occurred. Zero child proxy creation, zero tree traversal, one `OnValueChange` if different. Critical for blob fields that change atomically.

#### 9.9 ForValues Incremental Updates
Per-item derived scopes mean only changed items re-evaluate. A 100-item source where item 3 changes runs `mapFn` once, not 100 times. The source proxy is observed via `OnKeyAdded`/`OnKeyRemoved` for structural changes only; per-item changes fire item-specific inner scopes.

#### 9.10 Future: Ancestor Listener Count Propagation
If profiling identifies the parent walk as a bottleneck (walking ancestors with zero listeners), a `_onChangeListenerCount` counter can be maintained per node, incremented/decremented as connections are added/removed. Before recurring into a parent during propagation, check `parent._onChangeListenerCount > 0`. Not in v1 — the signal shortcircuit covers the exit condition at minimal cost.

---

### 10. Module Structure

```
ProxyGraph/
├── init.luau             -- package entry point; top-level API table
├── ProxyNode.luau        -- unified proxy node: scalar/table/array modes, __index/__newindex
├── Signal.luau           -- Signal<T...> and Connection types
├── Observer.luau         -- Observer<T> factory
├── Propagation.luau      -- generation counter, parent walk, _walkParents()
├── Batch.luau            -- _batchDepth, _pendingChanges, Batch(fn), flush logic
├── Scope.luau            -- Scope<T>, scoped(), derive(), addTask(), thread stack
├── Root.luau             -- root(), getScope(), withScope()
├── Computed.luau         -- Computed reactive state, dep tracking, stale/clean
├── Effect.luau           -- Effect reactive side-effect, re-run scheduling
├── ForValues.luau        -- ForValues reactive transform, per-item scopes
├── Diff.luau             -- structural tree diff (ported from TableManager2)
├── ArrayDiff.luau        -- LCS array diff (ported from TableManager2)
├── Types.luau            -- all exported type definitions
└── TypeFunctions.luau    -- ProxyWrap, StateWrap, Opaque brand type functions
```

Modules that can be ported directly from TableManager2: `Diff.luau`, `ArrayDiff.luau`.

---

### 11. Full API Reference

```lua
export type ProxyGraph = {
    -- Construction
    new:    <T>(value: T, opts: NewOptions?) -> Proxy<T>,
    Array:  <T>(values: {T}?, opts: NewOptions?) -> Proxy<{T}>,

    -- Read utilities
    peek:    <T>(value: UsedAs<T>) -> T,
    isProxy: (value: any) -> boolean,

    -- Observation (auto-register with currentOwner if set)
    Observer:  <T>(state: State<T>) -> Observer<T>,

    -- Reactive derivations (auto-register with currentOwner if set)
    Computed:  <T>(fn: UseFunc, opts: ComputedOptions?) -> State<T>,
    Effect:    (fn: UseFunc) -> Connection,
    ForValues: <TIn, TOut>(
        source: State<{TIn}>,
        fn: (use: UseFunc, item: State<TIn>) -> TOut
    ) -> State<{TOut}>,

    -- Scoping
    Scope:     () -> Scope<GraphMethods>,
    scoped:    <T>(...: T) -> Scope<T>,
    root:      (fn: () -> ()) -> (() -> ()),
    getScope:  () -> Scope?,
    withScope: <T>(scope: Scope<T>, fn: () -> ()) -> (),

    -- Batching
    Batch: (fn: () -> ()) -> (),

    -- Opaque wrapper (for = assignment syntax)
    Opaque: <T>(value: T) -> OpaqueWrapper<T>,
}

export type NewOptions = {
    mirror:          { [any]: any }?,
    ShouldBeOpaque:  ((key: any, value: any) -> boolean)?,
}

export type ComputedOptions = { lazy: boolean? }

export type SetOptions = { opaque: boolean? }

export type ListenerOptions = {
    ListenDepth:      number?,
    ListenDepthStyle: ("==" | "<=")?,
    Once:             boolean?,
}

export type UsedAs<T>  = State<T> | T
export type State<T>   = StateWrap<T>    -- read-only proxy type (type function output)
export type Proxy<T>   = ProxyWrap<T>    -- read-write proxy type (type function output)
export type Opaque<T>  = T               -- schema type tag; branded in type function

export type Signal<T...> = {
    Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
    Once:    (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
}

export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}

export type Observer<T> = {
    OnChange:        Signal<T, T?>,
    OnValueChange:   Signal<T, T?>,
    OnKeyAdded:      Signal<string, State<any>>,
    OnKeyRemoved:    Signal<string, State<any>>,
    OnArrayInserted: Signal<number, any>,
    OnArrayRemoved:  Signal<number, any>,
    OnArrayShifted:  Signal<number, number, any>,
}

export type GraphMethods = {
    Observer:  <T>(state: State<T>) -> Observer<T>,
    Computed:  <T>(fn: UseFunc, opts: ComputedOptions?) -> State<T>,
    Effect:    (fn: UseFunc) -> (),
    ForValues: <TIn, TOut>(source: State<{TIn}>, fn: (UseFunc, State<TIn>) -> TOut) -> State<{TOut}>,
}

export type Scope<T = GraphMethods> = T & {
    Destroy: (self: Scope<T>) -> (),
    derive:  (self: Scope<T>) -> Scope<T>,
    addTask: (self: Scope<T>, destructor: () -> ()) -> (),
}

type UseFunc = <T>(value: UsedAs<T>) -> T
type OpaqueWrapper<T> = { __opaqueValue: T }   -- internal; not user-facing
```

---

## Part 2 — Phased Implementation Plan

---

### Phase 1

**Goal:** Learn proxygraph. Setup core files and package structure.

We can use the Signal Package instead of implementing our own library

---

### Phase 2 — ProxyNode Core

**Goal:** Implement the unified proxy node in scalar and table modes. No observers yet — just the data graph.

**Files:** `ProxyNode.luau`

**Steps:**
1. Define internal state tables (all module-level, keyed by proxy userdata):
   - `_nodeValue: { [proxy]: any }` — raw stored value
   - `_nodeMode: { [proxy]: "scalar" | "table" | "array" }` — current mode
   - `_children: { [proxy]: { [any]: proxy } }` — child proxy cache (table/array modes)
   - `_weakParents: { [proxy]: { [proxy]: any } }` — weak-keyed parent→key registry
   - `_isOpaque: { [proxy]: { [any]: boolean } }` — opaque slot flags per table proxy

2. `ProxyNode.new(value, parentProxy?, key?)` — creates a `newproxy(true)` userdata, determines mode from value type, initializes all state tables, registers parent link if provided.

3. Implement `__index` on the shared metatable:
   - For table-mode: check `_children[proxy][key]` first. On miss, create child via `ProxyNode.new(rawValue[key], proxy, key)`, cache in `_children`, return it.
   - For scalar-mode: `key == "Get"` returns a getter closure. Other keys are errors or return nil.
   - Reserved method names (`"Get"`, `"Set"`, `"Remove"`, `"Insert"`, `"Find"`) return their respective method closures.

4. Implement `__newindex`:
   - Detects `OpaqueWrapper` tag → store inner value, set `_isOpaque[proxy][key] = true`, no child proxy.
   - Detects existing child proxy → call its internal setter (route to the child's set path).
   - Detects plain table value → recursively wrap as new child ProxyNode.
   - Detects ProxyNode value → multi-parent assignment: register parent link on the incoming node, store in `_children`.
   - Detects scalar value → create new scalar child ProxyNode.

5. Implement `:Get()` — deep copy of raw value. Scalars return the value directly. Tables recursively copy.

6. Implement internal `_set(newValue, opts)`:
   - No-op check: `newValue == _nodeValue[proxy]` → return immediately.
   - Opaque path: `opts.opaque == true` → set value, mark slot opaque, signal firing (Phase 3).
   - Table/reconcile path: run structural diff, update children in-place (Phase 3).
   - Scalar path: set value, signal firing (Phase 3).

7. Implement `__iter`, `__len`, `__tostring`, `__eq`, `__metatable` as in TableManager2's ProxyManager.

8. Write unit tests: create proxy, read scalars, read nested tables, child caching (identity check), multi-parent assignment, `__iter`, `__len`.

---

### Phase 3 — Propagation Engine

**Goal:** Implement the generation-stamp parent walk and batch system. Wire signals to writes.

**Files:** `Propagation.luau`, `Batch.luau`

**Steps:**
1. In `Propagation.luau`:
   - `_generation: number = 0` — module-level generation counter.
   - `_nodeGeneration: { [proxy]: number }` — last generation each node was notified in.
   - `nextGeneration() -> number` — increments and returns `_generation`. Called at the start of each top-level write.
   - `walkParents(node, generation, new, old)` — iterates `_weakParents[node]`, skips nodes where `_nodeGeneration[node] == generation`, stamps each visited parent, fires `OnChange` signal if present (Phase 5), recurses.

2. In `Batch.luau`:
   - `_batchDepth: number = 0`
   - `_pendingChanges: { [proxy]: { originalOld: any, currentNew: any } }` — ordered change list.
   - `Batch(fn)` — increment `_batchDepth`, pcall fn, decrement, flush if depth reaches 0.
   - `recordChange(node, oldValue, newValue)` — if batching: coalesce (preserve originalOld, update currentNew). If not batching: fire immediately.
   - `flush()` — iterate `_pendingChanges` in write order, call `fireNodeChange(node, entry.currentNew, entry.originalOld)` for each, clear the table.

3. Wire `_set()` in ProxyNode to call `recordChange()` / `walkParents()` as appropriate.

4. Write unit tests: scalar write fires, no-op suppressed, batch coalesces, batch fires once per node, diamond graph fires parent once, generation resets between writes.

---

### Phase 4 — Observer API

**Goal:** Expose the Signal-based observer interface.

**Files:** `Observer.luau`; add signal tables to `ProxyNode.luau`

**Steps:**
1. Add signal tables to ProxyNode internal state:
   - `_onValueChangeSignal: { [proxy]: Signal }` — fires when exact value replaced
   - `_onChangeSignal: { [proxy]: Signal }` — fires when value OR descendant changes
   - `_onKeyAddedSignal: { [proxy]: Signal }` (table-mode)
   - `_onKeyRemovedSignal: { [proxy]: Signal }` (table-mode)
   - `_onArrayInsertedSignal: { [proxy]: Signal }` (array-mode)
   - `_onArrayRemovedSignal: { [proxy]: Signal }` (array-mode)
   - `_onArrayShiftedSignal: { [proxy]: Signal }` (array-mode)

2. Wire signals to `walkParents` and `_set`: scalar set fires `_onValueChangeSignal` and `_onChangeSignal` on self; parent walk fires `_onChangeSignal` on each visited parent.

3. `Observer.new(state)` — returns an object with named fields pointing to the node's signals.

4. Add `Graph.Observer` to `init.luau` which calls `Observer.new`.

5. Write unit tests: OnValueChange fires on write, OnChange fires on descendant write, OnChange does NOT fire for non-descendant write, Once auto-disconnects, Disconnect stops future fires.

---

### Phase 5 — Scope System

**Goal:** Implement `Scope<T>`, `scoped()`, `derive()`, `root()`, `getScope()`, `withScope()`, coroutine-safe owner stack.

**Files:** `Scope.luau`, `Root.luau`

**Steps:**
1. Implement `Scope` as a plain table (not userdata). Internal fields: `_destructors: { () -> () }` (array, run in reverse on Destroy), `_children: { Scope }` (derived child scopes).

2. `Scope:Destroy()` — iterate `_destructors` in reverse order and call each. Then call `:Destroy()` on each child in `_children`. Clear both lists.

3. `Scope:derive()` — create a new Scope, register its `:Destroy` in the parent's `_destructors`, return it.

4. `Scope:addTask(fn)` — append `fn` to `_destructors`.

5. `Graph.scoped(...providers)` — create a Scope, merge all provider tables onto it as methods. Each merged method wraps the original to: (a) run the original with the Scope as implicit first argument, (b) register the returned Connection/cleanup in the Scope's `_destructors`.

6. `Graph.Scope()` — convenience for `Graph.scoped(Graph)`.

7. In `Root.luau`:
   - `_threadStacks: { [thread]: {Scope} }` — weak keyed table.
   - `pushOwner(scope)`, `popOwner()`, `currentOwner() -> Scope?` — per-thread stack operations.
   - `Graph.root(fn)` — creates a Scope, pushes it, pcall(fn), pops it, returns `scope:Destroy`.
   - `Graph.getScope()` — returns current top of calling thread's stack.
   - `Graph.withScope(scope, fn)` — pushes scope, pcall(fn), pops scope.

8. Wire all `Graph.*` constructors to check `currentOwner()` and auto-register if present.

9. Write unit tests: Scope destroys connections on Destroy, derive is destroyed with parent, derive can be destroyed independently, addTask fires, root cleanup works, nested root, getScope returns correct scope, withScope sets and restores, coroutine isolation (two threads have independent stacks).

---

### Phase 6 — Computed

**Goal:** Implement lazy reactive derived state with dep tracking, stale/clean state machine, and dep diffing.

**Files:** `Computed.luau`

**Steps:**
1. Define Computed internal state per node: `_fn`, `_cachedValue`, `_state: "clean" | "stale" | "recomputing"`, `_deps: { [State]: Connection }`, `_innerScope: Scope?`, `_parentScope: Scope`.

2. `Graph.Computed(fn, opts)` — creates a ProxyNode in scalar mode, marks it as Computed, runs initial evaluation, returns it as `State<T>`.

3. `_evaluate(computed)`:
   - Set state to `Recomputing`
   - Destroy `_innerScope` if exists; create fresh `_innerScope = _parentScope:derive()`
   - Push `_innerScope` as current owner
   - Set up dep tracker: push a new dep-collection context onto a module-level tracker stack
   - Call `_fn(use)` — `use(stateValue)` reads the current value AND records the state in the active tracker
   - Pop dep tracker, pop owner
   - Dep diff: compare new dep set vs `_deps`; add/remove connections as needed
   - Update `_cachedValue`, set state to `Clean`
   - If `_onValueChangeSignal._connectionCount > 0` and new value ≠ old value: fire signal

4. Override `:Get()` for Computed nodes: if state is `Stale`, call `_evaluate()` first.

5. On a dep's `OnValueChange` firing: if state is `Clean`, mark `Stale`. If `_onValueChangeSignal._connectionCount > 0`, schedule re-evaluation (via batch queue or immediate).

6. Computed nodes do NOT expose `:Set()`. The type function emits `State<T>` not `Proxy<T>`.

7. Write unit tests: initial value correct, updates when dep changes, stale-only behavior when unobserved (no re-eval), observed Computed re-evals eagerly, dep diffing (removed dep doesn't trigger re-eval), cycle detection (state stays Recomputing on self-reference), lazy opt-in, inner scope cleanup on re-eval.

---

### Phase 7 — Effect

**Goal:** Implement reactive side-effects with per-run sub-scopes.

**Files:** `Effect.luau`

**Steps:**
1. `Graph.Effect(fn)` — creates an Effect object with `_fn`, `_deps: { [State]: Connection }`, `_runScope: Scope?`, `_parentScope: Scope`, `_queued: boolean`.

2. `_runEffect(effect)`:
   - Destroy `_runScope`; create fresh `_runScope = _parentScope:derive()`
   - Push `_runScope` as current owner and dep-collection context
   - Call `_fn(use)`
   - Pop both
   - Dep diff (same as Computed)
   - `_queued = false`

3. On a dep's `OnValueChange` firing: if `_queued == false`, set `_queued = true`, schedule re-run (batch-aware: if batching, add to flush queue; otherwise run synchronously after current propagation completes).

4. Run initial evaluation immediately on construction.

5. Return a `Connection`-like stop handle: calling `:Disconnect()` destroys `_runScope`, removes all dep connections, prevents future re-runs.

6. Write unit tests: effect runs initially, re-runs on dep change, per-run scope cleanup, nested reactive objects in effect are cleaned on re-run, stopping effect prevents future runs, effect inside root is cleaned on root destroy.

---

### Phase 8 — ForValues

**Goal:** Incremental reactive transform over a source collection.

**Files:** `ForValues.luau`

**Steps:**
1. `Graph.ForValues(source, mapFn)` — creates a `State<{TOut}>` backed by an array proxy. Maintains `_itemScopes: { [any]: Scope }` per source item.

2. Subscribe to `Observer(source).OnKeyAdded` and `OnKeyRemoved` for structural changes.

3. On item added: create `itemScope = parentScope:derive()`, push as owner, run `mapFn(use, itemProxy)`, pop, cache result in output proxy, store `itemScope`.

4. On item removed: `_itemScopes[item]:Destroy()`, remove from output.

5. For each item, observe the item proxy's `OnValueChange` — when it fires, re-run `mapFn` for that item (destroy and recreate item scope).

6. Output is `State<{TOut}>` — read-only.

7. Write unit tests: initial mapping, item added triggers map, item removed cleans scope, item value change re-maps only that item, nested reactive objects in mapFn are scoped correctly.

---

### Phase 9 — Opaque System

**Goal:** Implement opaque value storage, `Graph.Opaque()` wrapper, `ShouldBeOpaque` predicate, and diff shortcircuit.

**Files:** `ProxyNode.luau` (additions), `init.luau`

**Steps:**
1. `OpaqueWrapper` — a plain table `{ __opaqueValue: T }` with a sentinel metatable for `isOpaque()` detection.
2. `Graph.Opaque(value)` — creates an OpaqueWrapper.
3. In `__newindex`: detect `isOpaque(value)`, strip wrapper, store inner value, set `_isOpaque[proxy][key] = true`.
4. In `NewOptions` processing: run `ShouldBeOpaque(key, value)` for each field during construction; mark matching fields.
5. In reconciliation (`_set` for tables): if `_isOpaque[proxy][key]`, skip structural diff; use identity comparison only.
6. In `__index` for opaque slots: return value directly from the raw inner table without creating child proxies.
7. For schematically declared `Opaque<T>` fields: the type function ensures the write type accepts raw `T` without requiring `Graph.Opaque()` wrapper. The read type returns raw field types. Runtime auto-marks these fields based on schema info stored at construction.

8. Write unit tests: opaque write stores atomically, no child proxies for opaque, read-transparent navigation, OnValueChange fires with whole value, structural diff skipped, ShouldBeOpaque predicate applied.

---

### Phase 10 — Array Mode

**Goal:** Implement array-mode proxies with insert/remove/shift operations and array-specific signals.

**Files:** `ProxyNode.luau` (array mode additions), `ArrayDiff.luau` (port from TableManager2)

**Steps:**
1. Array detection: a table is array-mode if all keys are `1..#t` with no gaps. Reuse classification logic from TableManager2.
2. Array-mode `_children` maps numeric indices to child proxies.
3. Implement `:Insert(index?, value)` — shifts existing proxies at affected indices, creates new child proxy, fires `OnArrayInserted`.
4. Implement `:Remove(index)` — detaches child proxy, shifts remaining, fires `OnArrayRemoved`.
5. On `:Set(newArray)` — use `ArrayDiff.luau` to compute minimal insert/remove/shift operations; apply to child proxy array and fire corresponding signals.
6. `OnArrayShifted` fires when an existing item moves index (without value change) — important for list UI consistency.

7. Write unit tests: insert, remove, set-with-diff, shift detection, stable proxy identity through reindexing.

---

### Phase 11 — Type Functions

**Goal:** Implement `StateWrap`, `ProxyWrap`, and `Opaque` brand type functions for full Luau autocomplete.

**Files:** `TypeFunctions.luau`

**Steps:**
1. `StateWrap(T)` type function:
   - For table T: iterate `T:properties()`. For each key, `setreadproperty(key, StateWrap(valueType))`. For `Opaque<T>` fields: `setreadproperty(key, unwrapOpaque(valueType))` (raw type, no proxy wrap). Add `Get` method.
   - For scalar T: emit table with `Get` method only.
   - For array T: emit table with `Get`, numeric read indexer returning `StateWrap(elementType)`.

2. `ProxyWrap(T)` type function:
   - Start from `StateWrap(T)` output.
   - For table T: add `setwriteproperty` for each key (raw `valueType`). Add `Set`, `Remove` methods.
   - For scalar T: add `Set` method.
   - For array T: add write indexer (raw element type), add `Insert`, `Remove`, `Find` methods.

3. `Opaque<T>` brand: the type function checks for a sentinel property (`__opaque_brand: never`) to detect `Opaque<T>` fields.

4. Wire `State<T> = StateWrap<T>` and `Proxy<T> = ProxyWrap<T>` as exported type aliases.

5. Verification: write representative typed usage in a test file and confirm Luau LSP gives correct autocomplete for field reads, write type errors, and method availability.

---

### Phase 12 — Mirror Option and Init Wiring

**Goal:** Implement `mirror` option for external table sync. Wire all modules together in `init.luau`.

**Files:** `init.luau`, `ProxyNode.luau` (mirror hook)

**Steps:**
1. When `mirror` is provided in `NewOptions`: after every write that changes a value, apply the same write to the mirror table (plain table, not proxy). Use a post-write hook in the propagation path.
2. Mirror writes do not trigger propagation — they are silent reflections.
3. In `init.luau`: assemble the full `Graph` table from all modules. Implement `Graph.Scope()` as `Graph.scoped(Graph)`. Export all types.
4. Final integration pass: ensure `currentOwner()` auto-registration is wired in `Observer`, `Computed`, `Effect`, `ForValues` constructors.

---

### Phase 13 — Integration Tests and Validation

**Goal:** End-to-end correctness and performance validation.

**Steps:**
1. Typed proxy construction with schema — verify autocomplete via type-check run.
2. Full observation chain: write scalar → OnValueChange fires → OnChange fires on parent chain.
3. Multi-parent: shared node write fires both parent chains exactly once each.
4. Batch: 10 writes to same node in batch → 1 notification.
5. Diamond graph: shared child with two parents → OnChange fires on shared parent once (generation stamp).
6. Computed: unobserved, dep changes → no recompute (confirmed by counter). Observed, dep changes → recomputes once.
7. Effect re-run: inner Computed created in Effect → destroyed before re-run → no accumulation.
8. ForValues: 1000-item source, 1 item changes → 1 mapFn re-run (not 1000).
9. Scope cascade: root destroyed → all derived scopes and tracked connections destroyed.
10. Coroutine isolation: two threads with different owners → no cross-contamination.
11. Opaque: write opaque field → no child proxies → one OnValueChange → diff not called.
12. Performance smoke test: 10,000 scalar writes with no listeners → complete in <1ms (signal shortcircuit + no-op detection doing their job).
