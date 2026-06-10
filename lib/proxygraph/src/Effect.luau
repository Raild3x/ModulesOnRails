--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Effect

	Reactive side-effect node. `fn` is called immediately on creation and
	re-called synchronously whenever a dep signals a change. Each re-run
	receives a fresh inner Scope so reactive objects created inside `fn` are
	cleaned up before the next run.

	Returns a stop handle (a function) that disconnects all deps and destroys
	the current run scope. If called inside a `root()` or `withScope()` context,
	the stop handle is also registered with the owner scope automatically.

	Usage:
	```lua
	local stop = ProxyGraph.Effect(function(use)
		print("health:", use(proxy.health))
	end)
	-- later:
	stop()
	```
]=]

local ProxyNode = require("./ProxyNode")
local DepTracker = require("./DepTracker")
local Root = require("./Root")
local Types = require("./Types")
type Scope = Types.Scope<{}>
type Connection = Types.Connection
type AnySignal = Types.AnySignal
type EffectState = Types.InternalEffectState

-- ─── Impl table (breaks mutual recursion without forward declarations) ────────

type EffectImpl = {
	run: (effect: EffectState) -> (),
	onDepChanged: (effect: EffectState) -> (),
}

local impl = {} :: EffectImpl

-- ─── Module-level use() ───────────────────────────────────────────────────────

-- Typed as Use = <T>(UsedAs<T>) -> T so callers get precise return types.
local function use<T>(value: Types.UsedAs<T>): T
	if ProxyNode.isProxy(value) then
		DepTracker.trackAccess(value)
		return ProxyNode.peek(value) :: T
	elseif DepTracker.isState(value) then
		DepTracker.trackAccess(value)
		return ((value :: any) :: Types.Computed<T>):Get()
	end
	return (value :: any) :: T
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getStateSignal(state: any): AnySignal?
	if ProxyNode.isProxy(state) then
		return ProxyNode.getOnValueChangeSignal(state)
	elseif DepTracker.isState(state) then
		return (state :: Types.InternalComputedState<any>)._onValueChange
	end
	return nil
end

-- ─── Dep diffing ─────────────────────────────────────────────────────────────

local function diffDeps(effect: EffectState, newDepSet: { [any]: true })
	local deps = effect._deps
	for state in newDepSet do
		if deps[state] == nil then
			local sig = getStateSignal(state)
			if sig ~= nil then
				deps[state] = sig:Connect(function()
					impl.onDepChanged(effect)
				end)
			end
		end
	end
	for state, conn in deps do
		if not newDepSet[state] then
			conn:Disconnect()
			deps[state] = nil
		end
	end
end

-- ─── State machine ───────────────────────────────────────────────────────────

impl.onDepChanged = function(effect: EffectState)
	if effect._destroyed or effect._running then
		return
	end
	impl.run(effect)
end

impl.run = function(effect: EffectState)
	if effect._destroyed then
		return
	end
	effect._running = true

	local depCtx = DepTracker.push()

	local innerScope, ok, err = Root.renewInnerScope(effect._innerScope, function()
		effect._fn(use)
	end)
	effect._innerScope = innerScope

	DepTracker.pop()

	effect._running = false

	if not ok then
		error(err, 2)
	end

	diffDeps(effect, depCtx)
end

-- ─── Destroy helper ──────────────────────────────────────────────────────────

local function destroyEffect(effect: EffectState)
	if effect._destroyed then
		return
	end
	effect._destroyed = true
	for _, conn in effect._deps do
		conn:Disconnect()
	end
	table.clear(effect._deps)
	if effect._innerScope ~= nil then
		effect._innerScope:Destroy()
		effect._innerScope = nil
	end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local Effect = {}

--[=[
	Creates a new Effect. `fn` runs immediately, then re-runs synchronously
	whenever any dependency accessed via `use()` signals a change.

	Inside `fn`, `use(someProxy)` returns the proxy's value type (not `any`)
	when the proxy is properly typed as `Proxy<T>`.

	Returns a stop handle: calling it disconnects all deps and destroys the
	current run scope.

	If `scope` is given, the stop handle is registered with that scope.
	Otherwise, if called inside a `root()` or `withScope()` context the stop
	handle is registered with the current owner scope automatically.
]=]
function Effect.new(fn: (use: Types.Use) -> (), scope: Scope?): () -> ()
	local effect: EffectState = {
		_fn = fn :: (use: any) -> (),
		_deps = {} :: { [any]: Connection },
		_innerScope = nil :: Scope?,
		_running = false,
		_destroyed = false,
	}

	Root.registerWithOwner(scope, function()
		destroyEffect(effect)
	end)

	impl.run(effect)

	return function()
		destroyEffect(effect)
	end
end

return Effect
