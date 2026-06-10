--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Computed

	Lazy reactive derived state. The `fn` callback receives a `use()` function
	for reading dependencies; the result is cached and only re-evaluated when a
	dependency signals a change.

	State machine:
	  "stale"       — needs re-evaluation (initial state or dep changed)
	  "recomputing" — evaluation in progress (cycle guard)
	  "clean"       — cached value is current

	When no listener has connected to `OnValueChange`, re-evaluation is deferred
	until `:Get()` is called (lazy). When observed, the computed re-evaluates
	eagerly on each dep change.

	Usage:
	```lua
	local combined = ProxyGraph.Computed(function(use): number
		return use(proxy.health) + use(proxy.power)
	end)
	combined:Get()  -- number
	```
]=]

local SignalLib = require("../Signal")
local ProxyNode = require("./ProxyNode")
local DepTracker = require("./DepTracker")
local ScopeModule = require("./Scope")
local Root = require("./Root")
local Types = require("./Types")
type Scope = Types.Scope<{}>
type Connection = Types.Connection
type AnySignal = Types.AnySignal
type ComputedState<T> = Types.ComputedState<T>

-- Erased alias used by all internal implementation functions.
type AnyComputed = ComputedState<any>

-- ─── Impl table (breaks mutual recursion without forward declarations) ────────

type ComputedImpl = {
	evaluate: (computed: AnyComputed) -> (),
	onDepChanged: (computed: AnyComputed) -> (),
}

local impl = {} :: ComputedImpl

-- ─── Module-level use() ───────────────────────────────────────────────────────

-- Reads the current raw value and, when inside a tracking context, registers
-- the state as a dependency. Non-state values pass through unchanged.
-- Typed as Use = <T>(UsedAs<T>) -> T so callers get precise return types.
local function use<T>(value: Types.UsedAs<T>): T
	if ProxyNode.isProxy(value) then
		DepTracker.trackAccess(value)
		return ProxyNode.peek(value) :: T
	elseif DepTracker.isState(value) then
		DepTracker.trackAccess(value)
		return ((value :: any) :: ComputedState<T>):Get()
	end
	return (value :: any) :: T
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getStateSignal(state: any): AnySignal?
	if ProxyNode.isProxy(state) then
		return ProxyNode.getOnValueChangeSignal(state)
	elseif DepTracker.isState(state) then
		return (state :: AnyComputed)._onValueChange
	end
	return nil
end

-- ─── Dep diffing ─────────────────────────────────────────────────────────────

local function diffDeps(computed: AnyComputed, newDepSet: { [any]: true })
	local deps = computed._deps
	for state in newDepSet do
		if deps[state] == nil then
			local sig = getStateSignal(state)
			if sig ~= nil then
				deps[state] = sig:Connect(function()
					impl.onDepChanged(computed)
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

impl.onDepChanged = function(computed: AnyComputed)
	if computed._destroyed or computed._state == "recomputing" then
		return
	end
	computed._state = "stale"
	if computed._onValueChange:IsConnectedTo() then
		impl.evaluate(computed)
	end
end

impl.evaluate = function(computed: AnyComputed)
	if computed._state == "recomputing" then
		warn("ProxyGraph Computed: cycle detected — returning cached value")
		return
	end

	computed._state = "recomputing"

	if computed._innerScope ~= nil then
		computed._innerScope:Destroy()
	end
	local innerScope = ScopeModule.new()
	computed._innerScope = innerScope

	Root.pushOwner(innerScope)
	local depCtx = DepTracker.push()

	local newValue: any
	local ok, err = pcall(function()
		newValue = computed._fn(use)
	end)

	DepTracker.pop()
	Root.popOwner()

	if not ok then
		computed._state = "stale"
		error(err, 2)
	end

	diffDeps(computed, depCtx)

	local oldValue = computed._cachedValue
	computed._cachedValue = newValue
	computed._state = "clean"

	if newValue ~= oldValue and computed._onValueChange:IsConnectedTo() then
		computed._onValueChange:Fire(newValue, oldValue)
	end
end

-- ─── Computed metatable ───────────────────────────────────────────────────────

local ComputedMeta = {}
ComputedMeta.__index = ComputedMeta

function ComputedMeta.Get(self: AnyComputed): any
	if self._destroyed then
		error("Cannot read a destroyed Computed", 2)
	end
	if self._state == "stale" then
		impl.evaluate(self)
	end
	return self._cachedValue
end

function ComputedMeta.Destroy(self: AnyComputed)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, conn in self._deps do
		conn:Disconnect()
	end
	table.clear(self._deps)
	if self._innerScope ~= nil then
		self._innerScope:Destroy()
		self._innerScope = nil
	end
	self._onValueChange:Destroy()
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local Computed = {}

--[=[
	Creates a new Computed state node. `fn` receives a `use(state) -> T`
	function for declaring dependencies. The value is recomputed lazily when
	stale (or eagerly when observed).

	`T` is inferred from `fn`'s return type annotation. Inside `fn`, calling
	`use(someProxy)` returns the proxy's value type rather than `any`:
	```lua
	local hp = ProxyGraph.Computed(function(use): number
		return use(health) * use(buffMultiplier)  -- both → number
	end)
	hp:Get()  -- number
	```

	If called inside a `root()` or `withScope()` context, the computed
	automatically registers its cleanup with the current owner scope.
]=]
function Computed.new<T>(fn: (use: Types.Use) -> T): ComputedState<T>
	local computed: AnyComputed = setmetatable({
		_isState = DepTracker.COMPUTED_SENTINEL,
		_fn = fn :: (use: any) -> any,
		_cachedValue = nil :: any,
		_state = "stale" :: "stale" | "clean" | "recomputing",
		_deps = {} :: { [any]: Connection },
		_innerScope = nil :: Scope?,
		_onValueChange = SignalLib.new() :: AnySignal,
		_destroyed = false,
	}, ComputedMeta) :: any

	local owner = Root.currentOwner()
	if owner ~= nil then
		owner:addTask(function()
			computed:Destroy()
		end)
	end

	impl.evaluate(computed)
	return computed :: ComputedState<T>
end

return Computed
