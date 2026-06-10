--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026

const Signal = require("../Signal")

export type Connection = Signal.Connection
export type AnySignal = Signal.ClassicSignal<...any>

export type NodeMode = "scalar" | "table" | "array"

-- ─── Proxy ────────────────────────────────────────────────────────────────────

-- Public generic proxy type. T is the value type wrapped by this node.
-- Named method fields are precisely typed; child key access (`proxy.field`)
-- returns `any` because Luau cannot express mapped types {[K in keyof T]: Proxy<T[K]>}.
export type Proxy<T> = {
	Get: (self: Proxy<T>) -> T,
	Set: (self: Proxy<T>, newValue: T) -> (),
	Remove: (self: Proxy<T>, key: any) -> (),
	[any]: any,
}

-- ─── State ────────────────────────────────────────────────────────────────────

-- Reactive state: a Proxy or Computed that holds/derives a value of type T.
-- Effect is intentionally excluded — it produces no value.
export type State<T> = Proxy<T> | ComputedState<T>

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

-- Scope<T>: lifecycle-managed scope with optional provider methods T merged in.
--
--   Scope<{}>            plain scope (no extra constructors)
--   Scope<typeof(ProxyGraph)>  scope with ProxyGraph methods; supports scope:Computed(fn)
--
-- Returned by ProxyGraph.Scope() as Scope<{}> and by ProxyGraph.scoped(p) as Scope<T>.
export type Scope<T> = ScopeBase & T

-- ─── Computed ─────────────────────────────────────────────────────────────────

-- Generic reactive derived value. T is the computed result type.
-- Internal implementation uses ComputedState<any>; the generic is enforced
-- at the ProxyGraph public API boundary via Computed.new<T>.
export type ComputedState<T> = {
	_isState: {},
	_fn: (use: any) -> T,  -- use: any breaks the UsedAs<T>→ComputedState<T>→Use→UsedAs<T> cycle
	_cachedValue: T?,
	_state: "stale" | "clean" | "recomputing",
	_deps: { [any]: Connection },
	_innerScope: Scope<{}>?,
	_onValueChange: AnySignal,
	_destroyed: boolean,
	Get: (self: ComputedState<T>) -> T,
	Destroy: (self: ComputedState<T>) -> (),
}

-- ─── Effect ───────────────────────────────────────────────────────────────────

-- Internal state for an Effect node. Effects produce no value and are therefore
-- not part of State<T> — they are reactive side-effects only.
export type EffectState = {
	_fn: (use: any) -> (),  -- see ComputedState._fn comment above
	_deps: { [any]: Connection },
	_runScope: Scope<{}>?,
	_running: boolean,
	_destroyed: boolean,
}

-- ─── Options ──────────────────────────────────────────────────────────────────

export type NewOptions = {
	mirror: { [any]: any }?,
	ShouldBeOpaque: ((key: any, value: any) -> boolean)?,
}

export type SetOptions = {
	opaque: boolean?,
}

return {}
