--!strict
-- Component
-- Stephen Leitnick, Logan Hunt
-- November 26, 2021 (rewritten for v1.0.0)

--[=[
	@class Component

	## Overview

	Bind reusable, class-based behavior to Roblox instances using CollectionService
	tags. This is a fork of Stephen Leitnick's Component that adds a robust,
	yield-tolerant lifecycle, a per-instance cleanup Janitor, world-level queries,
	and cross-class instance lookups.

	To avoid confusion of terms:
	- `Component` refers to this module.
	- `Component Class` (e.g. `MyComponent`) refers to a class made via `Component.new`.
	- `Component Instance` refers to an instance of a component class.
	- `Roblox Instance` refers to the Roblox instance a component instance is bound to.

	## Lifecycle

	1. **ShouldConstruct** — extensions may veto construction (sync).
	2. **Constructing** — extension hooks (see barrier note below).
	3. **Construct()** — component initialization.
	4. **Constructed** — extension hooks. The component is now tracked.
	5. **Starting** — extension hooks.
	6. **Start()** — component startup.
	7. **Started** — extension hooks, then update loops connect and `Started` fires.

	Teardown always runs `Stopping` → `Stop(reason)` → `Stopped` → **Janitor
	destroy**, in that order, on *every* removal path (untag, ancestry exit,
	instance destroyed, class destroyed, or construction cancelled). Anything added
	via `self:AddTask(...)` is therefore guaranteed to be cleaned up.

	### Yielding and the phase barrier

	Lifecycle hooks may yield or return a Promise. Within a single phase, every
	active extension's hook is gated on dependency order: an extension's hook does
	not start until the hooks of the extensions it depends on have *finished*.
	Hooks with no dependency edge between them still run concurrently, so an
	unrelated sibling never blocks a hook. The phase completes (and the next one
	begins) only once every hook has finished and every returned Promise has
	resolved. `Construct()`/`Start()` may likewise yield or return a Promise.

	Only the construct phases (`Constructing` → `Construct()` → `Constructed`) run
	inline and hold up the construction chain. The start phases run after a
	`task.defer` boundary and teardown is deferred as a whole, so neither ever
	runs on the thread that triggered it and teardown never blocks its caller.
	Stop hooks are gated in *reverse* dependency order — a dependency stops only
	after everything depending on it has stopped.

	Hooks that neither yield nor return a Promise run inline in dependency order
	and cost no Promise at all; the machinery only materializes for hooks that
	actually suspend (see `Lifecycle.luau`).

	If the instance leaves its valid ancestors, is untagged, or is superseded while
	a hook is still waiting, the in-flight work is cancelled and the component is
	torn down.

	The lifecycle engine itself (construction chain + teardown) lives in
	`Lifecycle.luau`; the public/internal types live in `Types.luau`. This module
	owns class creation, tag/ancestry watching, and the public API.
]=]

--[=[
	@within Component
	@prop Started Signal
	@tag Event
	@tag Component Class
	Fired when a component instance finishes starting. Passes the component.
]=]

--[=[
	@within Component
	@prop Stopped Signal
	@tag Event
	@tag Component Class
	Fired when a started (or mid-start) component instance is stopped. Passes the
	component. Not fired for components torn down before they began starting.
]=]

--[=[
	@within Component
	@prop Instance Instance
	@tag Component Instance
	The Roblox instance a component instance is bound to.
]=]

--// Services //--
const CollectionService = game:GetService("CollectionService")

--// Dependencies //--
const Packages = script.Parent
const Promise = require(Packages.Promise)
const Janitor = require(Packages.Janitor)
const Signal = require(Packages.Signal)

--// Internal //--
const Keys = require(script.Keys)
const Extensions = require(script.Extensions)
const Query = require(script.Query)
const Lifecycle = require(script.Lifecycle)
const Types = require(script.Types)
const TypeFunctions = require(script.TypeFunctions)

--// Public type surface (declared in Types.luau / Keys.luau) //--
export type LifecyclePhase = Keys.LifecyclePhase
export type StopReason = Keys.StopReason
export type Extension = Types.Extension
export type ComponentConfig = Types.ComponentConfig
export type ComponentClass = Types.ComponentClass
export type TypedClass<M> = Types.TypedClass<M>
export type Query = Query.Query
export type Queryable = Query.Queryable
export type Filter = Query.Filter
export type Combinator = Query.Combinator
export type Matcher = Query.Matcher
export type RecheckSignal = Query.RecheckSignal

-- Type functions (NEW type solver only) live in TypeFunctions.luau; re-exported
-- here so users can compose `Component.extensionMethods<typeof(myExtension)>`
-- into their typed-path self alias.
export type extensionMethods<E> = TypeFunctions.extensionMethods<E>

type Janitor = Types.Janitor
type Promise<T...> = Types.Promise<T...>
type Class_Internal = Types.ComponentClass_Internal
type Instance_Internal = Types.ComponentInstance_Internal

const DEFAULT_ANCESTORS: { Instance } = { workspace, game:GetService("Players") }
const DEFAULT_TIMEOUT = 60
const UNSETUP_COMPONENTS: { Class_Internal } = {}

-- Typed view over the vendored `Promise.fromEvent`, whose inferred signature
-- rejects our typed signals/predicates; the value bridges through `unknown` once.
type FromEventFn = <T...>(event: unknown, predicate: ((T...) -> boolean)?) -> Promise<T...>
const fromEvent = (Promise.fromEvent :: unknown) :: FromEventFn

const Component = {}
Component.prototype = {}
Component.__index = Component.prototype
-- `Component` doubles as every class table's metatable (`setmetatable({},
-- Component)` in `componentClassNew`), so this intercepts NEW-key writes on
-- every class: member-hook definitions (`function Class:OnTouched()`) register
-- in the class's hook registry and connect to live instances immediately;
-- everything else rawsets, byte-identical to an uninstrumented table.
-- Component-INSTANCE writes are unaffected — metamethod lookup is raw, and the
-- class table itself never carries a raw `__newindex` key.
Component.__newindex = function(class: any, key: unknown, value: unknown)
	if not Lifecycle.ClassHookWrite(class, key, value) then
		rawset(class, key, value)
	end
end

--[=[
	@within Component
	@prop DelaySetup boolean
	@tag Component

	Global default for delaying component setup. When true, `Component.new` will not
	begin listening for tagged instances until `_setup()` is called manually.
	Initialized from the script's `DelaySetup` attribute (default false).
]=]
Component.DelaySetup = script:GetAttribute("DelaySetup") or false

--[=[
	@within Component
	@function query
	@param ... Queryable -- component classes, tag strings, sub-queries, and/or Query.Attr/Prop/Pred/And/Or/Not nodes
	@return Query
	Creates a world-level [Query] over tagged instances. See the [Query] class.

	`Component.query` / `Component.Query` are the callable Query module itself:
	`Component.Query(A, B)` builds a query, and the static node constructors
	(`Component.Query.Attr`, `.Prop`, `.Pred`, `.And`, `.Or`, `.Not`) build
	composable requirement nodes.
]=]
Component.query = Query
Component.Query = Query

--[=[
	@tag Component
	@return {ComponentClass}
	Returns a copy of all component classes that have not yet been set up.
]=]
function Component.getUnsetupComponents(): { ComponentClass }
	return (table.clone(UNSETUP_COMPONENTS) :: unknown) :: { ComponentClass }
end

--[=[
	@within Component
	@function GetAllComponentsForInstance
	@tag Component
	@param instance Instance
	@return {Component}
	Returns every component bound to `instance`, across all component classes. A
	component appears here from the moment it finishes constructing.
]=]
Component.GetAllComponentsForInstance = Lifecycle.GetAllForInstance

--------------------------------------------------------------------------------
-- Construction of a component class
--------------------------------------------------------------------------------

--[=[
	@function new
	@within Component
	@tag Component
	@param config ComponentConfig
	@return ComponentClass

	Create a new component class bound to a CollectionService tag.

	```lua
	local MyComponent = Component.new({ Tag = "MyComponent", Ancestors = {workspace} })

	function MyComponent:Construct() self.Data = "Hello" end
	function MyComponent:Start() print(self.Data) end
	function MyComponent:Stop(reason) print("stopped:", reason) end
	```

	Lifecycle methods may be defined post-hoc on the returned class (above), but
	custom methods and fields go in the config's `Methods` / `Fields` — the class
	type has no `[string]: any` indexer, so a brand-new name assigned post-hoc is
	a type error by design. Extension `Methods` from the config's `Extensions`
	array are merged in with full argument checking (new type solver).

	`Fields` are deep-copied onto every component instance before `Construct`, so
	a table default is never shared; `InitFields` is called once per instance for
	fields that must be built at runtime. `self` annotations close the circular
	type:

	```lua
	local Methods = {}
	type MyComponent = Component.TypedClass<typeof(Methods)>

	function Methods.Greet(self: MyComponent, msg: string)
		print(self.Instance, msg)
	end

	function Methods.Start(self: MyComponent)
		self:Greet("hello") -- fully checked
		print(self.Count) -- from Fields
	end

	local MyComponent = Component.new({
		Tag = "MyComponent",
		Methods = Methods,
		Fields = { Count = 0 },
		InitFields = function() return { Janitor = Janitor.new() } end,
	})
	```
]=]
const function componentClassNew(config: Types.ComponentConfig): Class_Internal
	const tag = config.Tag
	const selector = config.Selector
	if (tag == nil) == (selector == nil) then
		error("[Component] Component.new requires exactly one of `Tag` or `Selector`", 2)
	end
	if tag ~= nil then
		assert(type(tag) == "string", "[Component] `Tag` must be a string")
	else
		assert(type(selector) == "string", "[Component] `Selector` must be a string")
	end

	-- Built dynamically (symbol slot, signals, user methods) under `any`, then
	-- viewed as ClassAny; the public type comes from the NewFn cast below. The
	-- `:: any` on the RHS keeps the solver from stamping `@metatable` onto the
	-- local and defeating the annotation.
	const classAny: any = setmetatable({}, Component) :: any
	classAny.__index = classAny
	const janitor = Janitor.new()
	const ci: Keys.ClassInternal = {
		ancestors = config.Ancestors or DEFAULT_ANCESTORS,
		instToComponents = {},
		components = {},
		startedInstances = {},
		startedList = {},
		lockConstruct = {},
		watching = {},
		pending = {},
		extensions = config.Extensions or {},
		classActiveExtensions = {},
		extensionsVaryPerInstance = false,
		fields = config.Fields,
		initFields = config.InitFields,
		janitor = janitor,
		failed = janitor:Add(Signal.new(), "Destroy"),
		teardownsInFlight = 0,
		destroyJanitorWhenIdle = false,
		hooks = { events = {}, attrs = {}, props = {}, any = false },
		extensionHooks = {},
		selector = selector,
		enabled = true,
	}
	classAny[Keys.Internal] = ci
	classAny.Tag = tag
	classAny.Selector = selector
	classAny.AncestorsChanged = Signal.new(janitor)
	classAny.Started = Signal.new(janitor)
	classAny.Stopped = Signal.new(janitor)
	-- Collection-style hook namespaces, seeded so the dot-form function
	-- statement works: `function MyClass.OnAttributeChanged.Health(self) end`.
	-- (Never the colon form — it would bind `self` to the namespace table.)
	-- Their entries are intercepted into the hook registry, never stored raw.
	classAny.OnAttributeChanged = Lifecycle.MakeHookNamespace(classAny, "attr")
	classAny.OnPropertyChanged = Lifecycle.MakeHookNamespace(classAny, "prop")

	-- Copy user methods before _setup so extension-method collision checks in
	-- Extensions.BindMethods also fire against them. Hook-shaped entries
	-- (`OnTouched = fn`) register as member hooks AND stay real, typed,
	-- callable members (the rawset) — redefining one post-hoc is therefore
	-- not interceptable and is documented undefined.
	const methods: { [string]: unknown }? = config.Methods
	if methods then
		for name, fn in methods do
			if rawget(classAny, name) ~= nil then
				error(`[Component] Method '{name}' collides with an existing class member`, 2)
			end
			Lifecycle.ClassHookWrite(classAny, name, fn)
			rawset(classAny, name, fn)
		end
	end

	const customComponent = classAny :: Class_Internal

	table.insert(UNSETUP_COMPONENTS, customComponent)
	-- `Component.DelaySetup`, not `customComponent.DelaySetup`: the global default
	-- lives on the module table, which classes do not inherit from.
	const delaySetup = if config.DelaySetup ~= nil then config.DelaySetup else Component.DelaySetup
	if not delaySetup then
		customComponent:_setup()
	else
		task.delay(30, function()
			if table.find(UNSETUP_COMPONENTS, customComponent) then
				warn(customComponent, "Component:_setup() was not called within 30 seconds of instantiation.")
			end
		end)
	end
	return customComponent
end
Component.new = (componentClassNew :: any) :: Types.NewFn

--------------------------------------------------------------------------------
-- Tag / ancestry watching
--------------------------------------------------------------------------------

--[[
	Returns true if `instance` is a descendant of any valid ancestor.
]]
function Component.prototype._isInAncestorList(self: Class_Internal, instance: Instance): boolean
	for _, parent in Keys.class(self).ancestors do
		if instance:IsDescendantOf(parent) then
			return true
		end
	end
	return false
end

--[[
	Begins watching `instance` for ancestry changes, constructing/deconstructing as
	it enters or leaves the valid ancestor list. Idempotent.
]]
function Component.prototype._startWatching(self: Class_Internal, instance: Instance)
	const ci = Keys.class(self)
	if ci.watching[instance] then
		return
	end

	const function evaluate()
		if self:_isInAncestorList(instance) then
			if ci.enabled then
				Lifecycle.Request(self, instance)
			end
		else
			const reason: StopReason = if instance:IsDescendantOf(game) then "LeftAncestry" else "InstanceDestroyed"
			Lifecycle.Release(self, instance, reason)
		end
	end

	ci.watching[instance] = {
		instance.AncestryChanged:Connect(evaluate),
		self.AncestorsChanged:Connect(evaluate),
	}

	if ci.enabled and self:_isInAncestorList(instance) then
		Lifecycle.Request(self, instance)
	end
end

function Component.prototype._stopWatching(self: Class_Internal, instance: Instance)
	const ci = Keys.class(self)
	const connections = ci.watching[instance]
	if connections then
		ci.watching[instance] = nil
		for _, conn in connections do
			conn:Disconnect()
		end
	end
end

--[[
	Wires the component class to CollectionService and begins processing tagged
	instances. Called automatically unless `DelaySetup` is set.
]]
function Component.prototype._setup(self: Class_Internal)
	const idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	else
		warn(self, ":_setup was already called for this component.")
		return
	end

	const ci = Keys.class(self)
	const classActiveExtensions = Extensions.Resolve(self, ci.extensions, true)
	ci.classActiveExtensions = classActiveExtensions
	Extensions.BindMethods(self, classActiveExtensions)
	ci.extensionHooks = Extensions.CollectHooks(classActiveExtensions)

	-- Without a `ShouldExtend` anywhere, every instance resolves to exactly this
	-- list, so the lifecycle engine can share it instead of re-sorting per instance.
	for _, extension in classActiveExtensions do
		if type(extension.ShouldExtend) == "function" then
			ci.extensionsVaryPerInstance = true
			break
		end
	end

	if ci.selector ~= nil then
		self:_setupSelectorDriver()
		return
	end

	ci.janitor:Add(CollectionService:GetInstanceAddedSignal(self.Tag):Connect(function(instance)
		self:_startWatching(instance)
	end))
	ci.janitor:Add(CollectionService:GetInstanceRemovedSignal(self.Tag):Connect(function(instance)
		self:_stopWatching(instance)
		Lifecycle.Release(self, instance, "Untagged")
	end))

	for _, instance in CollectionService:GetTagged(self.Tag) do
		task.defer(function()
			self:_startWatching(instance)
		end)
	end
end

--------------------------------------------------------------------------------
-- Selector driver (Selector-attached classes)
--------------------------------------------------------------------------------

--[[
	The unified driver for `Selector =` classes: one interned Query.Selector
	engine per Ancestors root, track-style (`changed` edges, no per-match
	janitors), mapped to Lifecycle.Request / reason-mapped Lifecycle.Release.
	Union membership across roots: an instance under two overlapping roots is
	released only when NO engine still matches it. Edge semantics are identical
	to the tag driver's (the engines are edge-faithful; probe finding F8), so
	the same-frame supersede protocol behaves the same for both attachment
	spellings.
]]
function Component.prototype._setupSelectorDriver(self: Class_Internal)
	const ci = Keys.class(self)
	const engines: { { query: any, conn: any } } = {}
	ci.selectorEngines = engines

	const function stillMatchedElsewhere(instance: Instance): boolean
		for _, entry in engines do
			const engine = entry.query._engine
			if engine and engine.matched[instance] ~= nil then
				return true
			end
		end
		return false
	end

	const function onChanged(instance: Instance, isMatch: boolean)
		if isMatch then
			if ci.enabled then
				Lifecycle.Request(self, instance)
			end
		else
			if stillMatchedElsewhere(instance) then
				return
			end
			-- Same reason rule as the tag driver's ancestry watcher, plus the
			-- selector-specific "still parented but stopped matching" case.
			const reason: StopReason = if not instance:IsDescendantOf(game)
				then "InstanceDestroyed"
				elseif not self:_isInAncestorList(instance) then "LeftAncestry"
				else "SelectorUnmatched"
			Lifecycle.Release(self, instance, reason)
		end
	end

	for _, root in ci.ancestors do
		const query = Query(Query.Selector(ci.selector :: string, root)) :: any
		query:_validate()
		const engine = query:_activate()
		const conn = engine.changed:Connect(onChanged)
		table.insert(engines, { query = query, conn = conn })
	end

	-- Seed from matches that existed before our `changed` connections attached.
	if ci.enabled then
		for _, entry in engines do
			const engine = entry.query._engine
			if engine then
				for _, instance in table.clone(engine.matchedList) do
					Lifecycle.Request(self, instance)
				end
			end
		end
	end
end

function Component.prototype._teardownSelectorDriver(self: Class_Internal)
	const ci = Keys.class(self)
	const engines = ci.selectorEngines
	if not engines then
		return
	end
	ci.selectorEngines = nil
	for _, entry in engines do
		entry.conn:Disconnect()
		entry.query:_deactivate()
	end
end

--------------------------------------------------------------------------------
-- Public class API
--------------------------------------------------------------------------------

--[=[
	@within Component
	@tag Component Class
	@return {Component}
	Returns a copy of all active component instances of this class.
]=]
function Component.prototype.GetAll(self: Class_Internal): { Instance_Internal }
	return table.clone(Keys.class(self).components)
end

--[=[
	@within Component
	@tag Component Class
	@param instance Instance
	@return Component?
	Returns the component of this class bound to `instance`, or nil. The component
	may still be constructing; use [Component:GetLifecycleStatus] to check.
]=]
function Component.prototype.FromInstance(self: Class_Internal, instance: Instance): Instance_Internal?
	return Keys.class(self).instToComponents[instance]
end

--[=[
	@within Component
	@tag Component Class
	@param instance Instance
	@return boolean
	Whether a *started* component of this class is bound to `instance`. Use
	[Component:FromInstance] if a still-constructing component should count.
]=]
function Component.prototype.Has(self: Class_Internal, instance: Instance): boolean
	return Keys.class(self).startedInstances[instance] ~= nil
end

--[=[
	@within Component
	@tag Component Class
	@param instanceOrComponent Instance | Component
	@return LifecyclePhase
	Returns the lifecycle phase of the component bound to the given instance (or the
	phase of the given component). `"None"` if there is no such component.
]=]
function Component.prototype.GetLifecycleStatus(
	self: Class_Internal,
	instanceOrComponent: Instance | Types.AnyComponent
): LifecyclePhase
	return Lifecycle.GetPhase(self, instanceOrComponent)
end

--[=[
	@within Component
	@tag Component Class
	@param instance Instance
	@param timeout number?
	@return Promise<Component>
	Resolves once a *started* component of this class exists on `instance`.
	Defaults to a 60 second timeout.
]=]
function Component.prototype.WaitForInstance(
	self: Class_Internal,
	instance: Instance,
	timeout: number?
): Promise<Types.AnyComponent>
	const componentInstance = self:FromInstance(instance)
	if componentInstance and Keys.inst(componentInstance).started then
		return Promise.resolve(componentInstance)
	end
	return fromEvent(self.Started, function(c: Instance_Internal)
		return c.Instance == instance
	end):timeout(if type(timeout) == "number" then timeout else DEFAULT_TIMEOUT)
end

--[=[
	@within Component
	@tag Component Class
	@param instance Instance
	@return Promise<Component>
	Resolves with the started component on `instance`. If none exists, tags the
	instance and constructs one directly (without waiting on the CollectionService
	round-trip). Rejects if construction is vetoed by `ShouldConstruct` or is
	stopped before it starts.
]=]
function Component.prototype.GetCreateFromInstance(
	self: Class_Internal,
	instance: Instance
): Promise<Types.AnyComponent>
	if Keys.class(self).selector ~= nil then
		error(
			"[Component] GetCreateFromInstance is tag-only: a Selector-attached class cannot force-create "
				.. "(make the instance match the selector instead)",
			2
		)
	end
	return Promise.new(function(resolve, reject, onCancel)
		const existing = self:FromInstance(instance)
		if existing and Keys.inst(existing).started then
			resolve(existing)
			return
		end

		const janitor = Janitor.new()
		onCancel(function()
			janitor:Destroy()
		end)
		janitor:Add(self.Started:Connect(function(component)
			if component.Instance == instance then
				janitor:Destroy()
				resolve(component)
			end
		end))
		janitor:Add(Keys.class(self).failed:Connect(function(failedInstance, reason)
			if failedInstance == instance then
				janitor:Destroy()
				reject(`Component '{self.Tag}' did not start on instance: {reason}`)
			end
		end))

		if not CollectionService:HasTag(instance, self.Tag) then
			CollectionService:AddTag(instance, self.Tag)
		end
		self:_startWatching(instance)
		if Keys.class(self).enabled and self:_isInAncestorList(instance) then
			Lifecycle.Request(self, instance)
		end
	end)
end

--[=[
	@method GetOrCreateFromInstance
	@within Component
	@deprecated v1.0.0 -- Renamed to [Component:GetCreateFromInstance].
]=]
Component.prototype.GetOrCreateFromInstance = Component.prototype.GetCreateFromInstance

--[=[
	@within Component
	@tag Component Class
	@param enabled boolean

	Enables or disables the whole class, mirroring `Collection.Enabled`.
	Disabling stops every component (and cancels pending constructions) with
	reason `"Disabled"` and gates new construction; re-enabling re-evaluates,
	reconstructing current matches — including instances that appeared while
	the class was disabled.
]=]
function Component.prototype.SetEnabled(self: Class_Internal, enabled: boolean)
	const ci = Keys.class(self)
	if ci.enabled == enabled then
		return
	end
	ci.enabled = enabled
	if not enabled then
		-- Snapshot: Release mutates both tables synchronously.
		const toRelease: { Instance } = {}
		for instance in ci.pending do
			table.insert(toRelease, instance)
		end
		for instance in ci.instToComponents do
			if not table.find(toRelease, instance) then
				table.insert(toRelease, instance)
			end
		end
		for _, instance in toRelease do
			Lifecycle.Release(self, instance, "Disabled")
		end
		return
	end
	if ci.selector ~= nil then
		for _, entry in ci.selectorEngines or {} do
			const engine = (entry :: any).query._engine
			if engine then
				for _, instance in table.clone(engine.matchedList) do
					Lifecycle.Request(self, instance)
				end
			end
		end
	else
		for instance in ci.watching do
			if self:_isInAncestorList(instance) then
				Lifecycle.Request(self, instance)
			end
		end
	end
end

--[=[
	@within Component
	@tag Component Class
	Updates the valid ancestors of this class and re-evaluates watched instances.
]=]
function Component.prototype.UpdateAncestors(self: Class_Internal, newAncestors: { Instance })
	const ci = Keys.class(self)
	const lastAncestors = ci.ancestors
	ci.ancestors = newAncestors
	if ci.selector ~= nil and ci.selectorEngines ~= nil then
		-- Roots ARE the engines for a selector class: rebuild against the new
		-- list. Instances no longer under any root release via the fresh
		-- engines' membership (LeftAncestry through the reason mapping).
		const previouslyMatched: { [Instance]: boolean } = {}
		for _, entry in ci.selectorEngines :: { any } do
			const engine = entry.query._engine
			if engine then
				for _, instance in engine.matchedList do
					previouslyMatched[instance] = true
				end
			end
		end
		self:_teardownSelectorDriver()
		self:_setupSelectorDriver()
		const engines = ci.selectorEngines :: { any }
		for instance in previouslyMatched do
			local stillMatched = false
			for _, entry in engines do
				const engine = entry.query._engine
				if engine and engine.matched[instance] ~= nil then
					stillMatched = true
					break
				end
			end
			if not stillMatched then
				Lifecycle.Release(
					self,
					instance,
					if instance:IsDescendantOf(game) then "LeftAncestry" else "InstanceDestroyed"
				)
			end
		end
	end
	self.AncestorsChanged:Fire(newAncestors, lastAncestors)
end

--[=[
	@within Component
	@tag Component Class
	Returns a copy of the current valid ancestors.
]=]
function Component.prototype.GetAncestors(self: Class_Internal): { Instance }
	return table.clone(Keys.class(self).ancestors)
end

--[=[
	@within Component
	@tag Component Class
	@function OnConstruct
	Called before the component starts, to initialize it. May yield or return a
	Promise. Primary spelling of the legacy `Construct` (the `On*` form wins
	when both are defined).
]=]
--[=[
	@within Component
	@tag Component Class
	@function OnStart
	Called when the component starts. Sibling components on the same instance
	are safe to access here. May yield or return a Promise. Primary spelling of
	the legacy `Start`.
]=]
--[=[
	@within Component
	@tag Component Class
	@function OnStop
	@param reason StopReason
	Called when the component stops. The bound instance may already be gone —
	check `reason`. Anything added via `self:AddTask` is cleaned up
	automatically after this returns. Primary spelling of the legacy `Stop`.

	Beyond the lifecycle names, ANY other `On`-prefixed method on the class is
	a **member event hook**: `function MyClass:OnTouched(otherPart)` connects
	`instance.Touched` while the component is started (auto-disconnected on
	stop; a member the instance's class lacks is silently skipped). Declare
	event hooks through the config's `Methods` table to keep them fully typed.
]=]
--[=[
	@within Component
	@tag Component Class
	@deprecated v1.1.0 -- renamed to `OnConstruct` (Collection-aligned). Removal in v2.0.0.
	Called before the component starts, to initialize it. May yield or return a
	Promise.
]=]
function Component.prototype.Construct(_self: Instance_Internal) end

--[=[
	@within Component
	@tag Component Class
	@deprecated v1.1.0 -- renamed to `OnStart`. Removal in v2.0.0.
	Called when the component starts. Sibling components on the same instance are
	safe to access here. May yield or return a Promise.
]=]
function Component.prototype.Start(_self: Instance_Internal) end

--[=[
	@within Component
	@tag Component Class
	@param _reason StopReason
	@deprecated v1.1.0 -- renamed to `OnStop`. Removal in v2.0.0.
	Called when the component stops. The bound instance may already be gone — check
	`reason`. Anything added via `self:AddTask` is cleaned up automatically after
	this returns.
]=]
function Component.prototype.Stop(_self: Instance_Internal, _reason: StopReason) end

--------------------------------------------------------------------------------
-- Public instance API
--------------------------------------------------------------------------------

--[=[
	@within Component
	@tag Component Instance
	@param componentClass ComponentClass
	@return Component?
	Retrieves another component bound to the same Roblox instance.
]=]
function Component.prototype.GetComponent(self: Instance_Internal, componentClass: Class_Internal): Instance_Internal?
	return Keys.class(componentClass).instToComponents[self.Instance]
end

--[=[
	@within Component
	@tag Component Instance
	@return boolean
	Whether the component has fully started.
]=]
function Component.prototype.IsStarted(self: Instance_Internal): boolean
	return Keys.inst(self).started == true
end

--[=[
	@within Component
	@tag Component Instance
	@param task_ T
	@param cleanupMethod (string | true)?
	@param index any?
	@return T
	Adds a task to the component's core Janitor, cleaned up when the component
	stops (on every teardown path). Returns the task.
]=]
function Component.prototype.AddTask<T>(
	self: Instance_Internal,
	task_: T,
	cleanupMethod: (string | boolean)?,
	index: unknown?
): T
	return Keys.inst(self).janitor:Add(task_, cleanupMethod, index)
end

--[=[
	@within Component
	@tag Component Instance
	@param promise Promise
	@param index any?
	@return Promise
	Adds a Promise to the component's core Janitor. An optional string `index`
	names it so it can be removed/cancelled via [Component:RemoveTask].
]=]
function Component.prototype.AddPromise<T...>(self: Instance_Internal, promise: Promise<T...>, index: unknown?): Promise<T...>
	return Keys.inst(self).janitor:AddPromise(promise, index)
end

--[=[
	@within Component
	@tag Component Instance
	@param index any
	@param dontClean boolean?
	Removes a task from the core Janitor, cleaning it unless `dontClean` is true.
]=]
function Component.prototype.RemoveTask(self: Instance_Internal, index: unknown, dontClean: boolean?)
	const janitor = Keys.inst(self).janitor
	if dontClean then
		janitor:RemoveNoClean(index)
	else
		janitor:Remove(index)
	end
end

--[=[
	@within Component
	@tag Component Instance
	@param index any
	@return any
	Gets a task previously added with an index.
]=]
function Component.prototype.GetTask(self: Instance_Internal, index: unknown): unknown
	return Keys.inst(self).janitor:Get(index)
end

--[=[
	@tag Component Class
	@function OnHeartbeat
	@param dt number
	@within Component
	If present, connected to `RunService.Heartbeat` while the component runs.
	Primary spelling of the legacy `HeartbeatUpdate` (the `On*` form wins when
	both are defined).
]=]
--[=[
	@tag Component Class
	@function OnPreSimulation
	@param dt number
	@within Component
	If present, connected to `RunService.Stepped` while the component runs.
	Primary spelling of the legacy `SteppedUpdate`.
]=]
--[=[
	@tag Component Class
	@function OnPreRender
	@param dt number
	@within Component
	@client
	If present, connected to `RunService.RenderStepped` while the component
	runs, or to `BindToRenderStep` when `RenderPriority` is set. Primary
	spelling of the legacy `RenderSteppedUpdate`.
]=]
--[=[
	@tag Component Class
	@function HeartbeatUpdate
	@param dt number
	@within Component
	@deprecated v1.1.0 -- renamed to `OnHeartbeat` (Collection-aligned). Removal in v2.0.0.
	If present, connected to `RunService.Heartbeat` while the component runs.
]=]
--[=[
	@tag Component Class
	@function SteppedUpdate
	@param dt number
	@within Component
	@deprecated v1.1.0 -- renamed to `OnPreSimulation`. Removal in v2.0.0.
	If present, connected to `RunService.Stepped` while the component runs.
]=]
--[=[
	@tag Component Class
	@function RenderSteppedUpdate
	@param dt number
	@within Component
	@client
	@deprecated v1.1.0 -- renamed to `OnPreRender`. Removal in v2.0.0.
	If present, connected to `RunService.RenderStepped` while the component runs, or
	to `BindToRenderStep` when `RenderPriority` is set.
]=]
--[=[
	@tag Component Class
	@prop OnAttributeChanged { [string]: (self) -> () }
	@within Component
	Collection-style hook namespace, seeded on every class. An entry named `X`
	is connected to `GetAttributeChangedSignal("X")` on the bound instance
	while the component is started (auto-disconnected on stop). Declare with
	the DOT form and an explicit `self` — the colon form would bind `self` to
	the namespace table:

	```lua
	function MyClass.OnAttributeChanged.Health(self)
		print(self.Instance:GetAttribute("Health"))
	end
	```
]=]
--[=[
	@tag Component Class
	@prop OnPropertyChanged { [string]: (self) -> () }
	@within Component
	Like `OnAttributeChanged`, for `GetPropertyChangedSignal`. An entry naming
	a property the bound instance's class lacks is silently skipped, so one
	component class can span multiple Roblox classes.
]=]

--[=[
	@within Component
	@tag Component Class
	Destroys the component class: stops all its components (with reason
	`"ClassDestroyed"`), disconnects from CollectionService, and clears all state.
]=]
function Component.prototype.Destroy(self: Class_Internal)
	const idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	end

	-- Stop watching every instance first, so no new construction begins mid-destroy.
	const ci = Keys.class(self)
	for instance in ci.watching do
		self:_stopWatching(instance)
	end
	table.clear(ci.watching)
	self:_teardownSelectorDriver()

	Lifecycle.DestroyClass(self)
end

return Component
