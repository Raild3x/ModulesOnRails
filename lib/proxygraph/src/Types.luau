--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026

const Signal = require("../Signal")

export type Connection = Signal.Connection
export type AnySignal = Signal.ClassicSignal<...any>
export type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

export type NodeMode = "scalar" | "table" | "array"

-- ════════════════════════════════════════════════════════════════════════════
-- ─── Public API types ──────────────────────────────────────────────────────
-- ════════════════════════════════════════════════════════════════════════════

-- ─── Readable ─────────────────────────────────────────────────────────────────

-- Shared base for any reactive value-holder that can be read with :Get(): T.
-- Both Proxy<T> and Computed<T> extend this.
export type Readable<T> = {
	Get: (self: Readable<T>) -> T,
}

export type Cleanable = {
	Cleanup: (self: any) -> (),
}

-- ─── Proxy ────────────────────────────────────────────────────────────────────

-- Public generic proxy type. T is the value type wrapped by this node.
-- Named method fields are precisely typed; child key access (`proxy.field`)
-- returns `any` because Luau cannot express mapped types {[K in keyof T]: Proxy<T[K]>}.
export type Proxy<T> = Readable<T> & {
	Set: (self: Proxy<T>, newValue: T) -> (),
	Remove: (self: Proxy<T>, key: any) -> (),
	Destroy: (self: Proxy<T>) -> (),
	DestroyChain: (self: Proxy<T>) -> (),
	[any]: any,
}

-- ─── Signals ──────────────────────────────────────────────────────────────────

-- Table of all 7 per-node signal types, returned by Signals.getSignals /
-- ProxyNode.getSignals. Fields are resolved (and lazily created) on access.
export type SignalsTable = {
	onValueChange: AnySignal,
	onChange: AnySignal,
	onKeyAdded: AnySignal,
	onKeyRemoved: AnySignal,
	onArrayInserted: AnySignal,
	onArrayRemoved: AnySignal,
	onArrayShifted: AnySignal,
}

-- ─── Computed ─────────────────────────────────────────────────────────────────

-- Public generic computed type. T is the computed result type. Holds only the
-- public surface (Get/Destroy); internal fields live in InternalComputedState<T>.
export type Computed<T> = Readable<T> & Cleanable

-- ─── State ────────────────────────────────────────────────────────────────────

-- Reactive state: a Proxy or Computed that holds/derives a value of type T.
-- Effect is intentionally excluded — it produces no value.
export type State<T> = Proxy<T> | Computed<T>

-- Anything that use() can accept to produce a T.
-- Includes raw values (which use() passes through unchanged).
export type UsedAs<T> = State<T> | T

-- Typed use() function. Generic over T: given UsedAs<T>, returns T.
-- This replaces the weaker UseFunc = (any)->any and enables proper return-type
-- inference when calling use(proxy) inside Computed/Effect callbacks.
export type Use = <T>(UsedAs<T>) -> T

-- ─── Scope ────────────────────────────────────────────────────────────────────

-- Module-local base scope fields. Not exported directly; consumers use Scope<T>.
type ScopeBase = {
	_destructors: { () -> () },
	_children: { ScopeBase },
	_destroyed: boolean,
	Destroy: (self: ScopeBase) -> (),
	derive: (self: ScopeBase) -> ScopeBase,
	addTask: (self: ScopeBase, fn: () -> ()) -> (),
}

-- Scope<Provider>: lifecycle-managed scope with optional provider methods merged in.
--
--   Scope<>                    plain scope (no extra constructors)
--   Scope<typeof(ProxyGraph)>  scope with ProxyGraph methods; supports scope:Computed(fn)
--
-- Returned by ProxyGraph.Scope() as Scope<> and by ProxyGraph.scoped(p) as Scope<T>.
export type Scope<Provider = {}> = ScopeBase & Provider

-- ─── Options ──────────────────────────────────────────────────────────────────

export type NewOptions = {
	mirror: { [any]: any }?,
	ShouldBeOpaque: ((key: any, value: any) -> boolean)?,
}

export type SetOptions = {
	opaque: boolean?,
}

-- ════════════════════════════════════════════════════════════════════════════
-- ─── Internal implementation types (not part of the public API) ───────────
-- ════════════════════════════════════════════════════════════════════════════

-- A trackable dependency source (the non-Proxy half of getStateSignal's branch
-- logic: ProxyNode.isProxy(v) OR DepTracker.isState(v), which checks
-- rawget(v, "_isState") == COMPUTED_SENTINEL).
export type InternalDependencySource = {
	_isState: {},
	_onValueChange: AnySignal,
}

-- Anything that owns a per-evaluation/run inner Scope, recreated each time it
-- (re-)evaluates so nested reactive objects created during the run are cleaned
-- up before the next one. Computed and Effect both fill this role via the
-- shared field name `_innerScope`, managed by Root.renewInnerScope.
export type InternalScopedRunner = {
	_destroyed: boolean,
	_innerScope: Scope<{}>?,
}

-- Internal state for a Computed node. Implementation uses
-- InternalComputedState<any>; the generic is enforced at the ProxyGraph public
-- API boundary via Computed.new<T>.
export type InternalComputedState<T> = Computed<T> & InternalDependencySource & InternalScopedRunner & {
	_fn: (use: any) -> T, -- use: any breaks the UsedAs<T>→Computed<T>→Use→UsedAs<T> cycle
	_cachedValue: T?,
	_state: "stale" | "clean" | "recomputing",
	_deps: { [any]: Connection },
}

-- Internal state for an Effect node. Effects produce no value and are
-- therefore not part of State<T> — they are reactive side-effects only.
export type InternalEffectState = InternalScopedRunner & {
	_fn: (use: any) -> (), -- see InternalComputedState._fn comment above
	_deps: { [any]: Connection },
	_running: boolean,
}

return {}
