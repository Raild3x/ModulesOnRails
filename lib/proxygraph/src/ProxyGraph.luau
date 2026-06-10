--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class ProxyGraph

	Top-level entry point for the ProxyGraph reactive data-graph library.

	## Phases implemented
	- Phase 1: Package structure
	- Phase 2: ProxyNode core (scalar + table modes, lazy child caching, multi-parent)
	- Phase 3: Propagation engine (generation stamps, parent walk, batch system)
	- Phase 4: Observer API (OnChange, OnValueChange, OnKeyAdded, OnKeyRemoved, …)
	- Phase 5: Scope system (Scope, root, getScope, withScope, scoped)
	- Phase 6: Computed (lazy reactive derived state with dep tracking)
	- Phase 7: Effect (reactive side-effects with per-run inner scopes)

	## Pending phases
	- Phase 8: ForValues
	- Phase 9: Opaque system
	- Phase 10: Array mode signals (OnArrayInserted / Removed / Shifted)
	- Phase 11: Type functions (ProxyWrap / StateWrap)
	- Phase 12: Mirror option + full wiring
]=]

local ProxyNode = require("./ProxyNode")
local ObserverModule = require("./Observer")
local Batch = require("./Batch")
local ScopeModule = require("./Scope")
local Root = require("./Root")
local ComputedModule = require("./Computed")
local EffectModule = require("./Effect")
local DepTracker = require("./DepTracker")
local Types = require("./Types")

-- ─── Re-exported types ────────────────────────────────────────────────────────
-- export type declarations are also visible within this module as local aliases.

export type Observer<T> = ObserverModule.Observer<T>
export type Connection = Types.Connection
export type Readable<T> = Types.Readable<T>
export type Proxy<T> = Types.Proxy<T>
export type Computed<T> = Types.Computed<T>
export type State<T> = Types.State<T>
export type UsedAs<T> = Types.UsedAs<T>
export type Use = Types.Use
export type Scope<Provider = {}> = Types.Scope<Provider>

type NewOptions = Types.NewOptions
export type NewOptions_ = NewOptions  -- public alias

-- ─── API table ────────────────────────────────────────────────────────────────

local ProxyGraph = {}

--[=[
	Creates a new Proxy node wrapping `value`. The value type `T` is inferred
	from the argument so that `:Get()` and `:Set()` are precisely typed.

	```lua
	local health = ProxyGraph.new(100)
	health:Get()      -- number
	health:Set(75)    -- ✓   health:Set("oops") ✗

	local player = ProxyGraph.new({ health = 100, power = 10 })
	player:Get()      -- { health: number, power: number }
	```
]=]
function ProxyGraph.new<T>(value: T, _opts: NewOptions?): Proxy<T>
	return ProxyNode.new(value)
end

--[=[
	Creates an Observer for `state`, exposing reactive signal fields:
	- `OnChange` / `OnValueChange`
	- `OnKeyAdded` / `OnKeyRemoved`
	- `OnArrayInserted` / `OnArrayRemoved` / `OnArrayShifted` (Phase 10)

	Accepts any `State<T>` (`Proxy<T>` or `Computed<T>`). For computed
	states only `OnChange` / `OnValueChange` are populated.

	```lua
	local obs = ProxyGraph.Observer(player.health)
	obs.OnValueChange:Connect(function(new, old) ... end)
	```
]=]
function ProxyGraph.Observer<T>(state: State<T>): Observer<T>
	return ObserverModule.new(state)
end

--[=[
	Returns the raw value of `proxy` without a deep copy and without creating a
	dependency. `T` is inferred from `proxy`. For non-proxy values the argument
	is returned unchanged.

	For table/array proxies this returns the live internal table — do NOT mutate
	the result. For a safe deep-copy snapshot call `:Get()` on the proxy directly.

	```lua
	local hp = ProxyGraph.peek(health)  -- number, O(1)
	```
]=]
function ProxyGraph.peek<T>(value: Proxy<T>): T
	if ProxyNode.isProxy(value) then
		return ProxyNode.peek(value) :: T
	end
	return value :: T
end

--[=[
	Returns true when `value` is a ProxyNode created by this library.
]=]
function ProxyGraph.isProxy(value: any): boolean
	return ProxyNode.isProxy(value)
end

--[=[
	Runs `fn` inside a batch: all signal firing is deferred until `fn`
	returns. Multiple writes to the same node coalesce into one notification.
]=]
function ProxyGraph.Batch(fn: () -> ())
	Batch.Batch(fn)
end

--[=[
	Creates an OpaqueWrapper for use with `=` assignment syntax.

	```lua
	proxy.config = ProxyGraph.Opaque({ theme = "dark" })
	```

	Phase 9 fully implements the opaque diff-shortcircuit.
]=]
function ProxyGraph.Opaque(value: any): { _opaqueValue: any }
	return ProxyNode.makeOpaqueWrapper(value)
end

-- ─── Phase 5: Scope system ────────────────────────────────────────────────────

--[=[
	Creates a plain `Scope<{}>` for managing reactive object lifetimes manually.

	```lua
	local scope = ProxyGraph.Scope()
	scope:addTask(conn.Disconnect)
	scope:Destroy()
	```
]=]
function ProxyGraph.Scope(): Scope<{}>
	return ScopeModule.new()
end

--[=[
	Creates a `Scope<T>` with `provider`'s methods merged onto it. Each merged
	method pushes the scope as the current owner so reactive objects constructed
	via the scope auto-register their cleanup.

	```lua
	local scope = ProxyGraph.scoped(ProxyGraph)
	-- scope: Scope<typeof(ProxyGraph)>
	local computed = scope:Computed(function(use): number
		return use(proxy.health) * 2
	end)
	scope:Destroy()  -- computed cleaned up automatically
	```
]=]
function ProxyGraph.scoped<T>(provider: T): Scope<T>
	local scope = ScopeModule.new()
	local scopeAny: any = scope
	for k, v in provider :: any do
		if type(v) == "function" then
			scopeAny[k] = function(...)
				Root.pushOwner(scope)
				local result = v(...)
				Root.popOwner()
				return result
			end
		else
			scopeAny[k] = v
		end
	end
	return scopeAny :: Scope<T>
end

--[=[
	Runs `fn` inside a new root `Scope<{}>`. Returns a cleanup function that
	destroys the scope and all reactive objects registered inside `fn`.

	```lua
	local cleanup = ProxyGraph.root(function()
		ProxyGraph.Effect(function(use)
			print(use(proxy.health))
		end)
	end)
	cleanup()
	```
]=]
function ProxyGraph.root(fn: () -> ()): () -> ()
	return Root.root(fn)
end

--[=[
	Returns the current owner `Scope<{}>` for the running coroutine, or nil
	when called outside a `root()` or `withScope()` context.
]=]
function ProxyGraph.getScope(): Scope<{}>?
	return Root.getScope()
end

--[=[
	Runs `fn` with `scope` as the current owner. Reactive constructors called
	inside `fn` automatically register with `scope`.
]=]
function ProxyGraph.withScope(scope: Scope<{}>, fn: () -> ())
	Root.withScope(scope, fn)
end

-- ─── Phase 6: Computed ────────────────────────────────────────────────────────

--[=[
	Creates a lazy reactive derived value. `fn` receives a typed `use()` function;
	any state accessed through `use()` becomes a dependency.

	`T` is inferred from `fn`'s return type annotation. Inside `fn`, `use(state)`
	returns the state's value type rather than `any`:
	```lua
	local combined = ProxyGraph.Computed(function(use): number
		return use(proxy.health) + use(proxy.power)  -- both → number
	end)
	combined:Get()  -- number
	```

	If `scope` is given, the computed registers its cleanup with that scope.
	Otherwise, if called inside a `root()` or `withScope()` context, it
	automatically registers its cleanup with the current owner scope.
]=]
function ProxyGraph.Computed<T>(fn: (use: Use) -> T, scope: Scope?): Computed<T>
	return ComputedModule.new(fn, scope)
end

-- ─── Phase 7: Effect ──────────────────────────────────────────────────────────

--[=[
	Creates a reactive side-effect. `fn` runs immediately and re-runs
	synchronously whenever any dependency changes. Returns a stop function.

	Note: Effect is not a `State<T>` — it produces no value.

	```lua
	local stop = ProxyGraph.Effect(function(use)
		print("hp:", use(proxy.health))
	end)
	stop()
	```

	If `scope` is given, the stop handle is registered with that scope.
	Otherwise, if called inside a `root()` or `withScope()` context the stop
	handle is registered with the current owner scope automatically.
]=]
function ProxyGraph.Effect(fn: (use: Use) -> (), scope: Scope?): () -> ()
	return EffectModule.new(fn, scope)
end

--[=[
	Reads the current value of `value` and, when called inside a Computed or
	Effect `fn`, registers it as a dependency. Outside any tracking context
	behaves like `peek()`.

	`T` is inferred from `value`:
	```lua
	local hp = ProxyGraph.use(health)  -- number
	```
]=]
function ProxyGraph.use<T>(value: UsedAs<T>): T
	if ProxyNode.isProxy(value) then
		DepTracker.trackAccess(value)
		return ProxyNode.peek(value) :: T
	elseif DepTracker.isState(value) then
		DepTracker.trackAccess(value)
		return ((value :: any) :: Computed<T>):Get()
	end
	return (value :: any) :: T
end

return ProxyGraph
