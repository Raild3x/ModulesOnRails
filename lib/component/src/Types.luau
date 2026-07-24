--!strict
-- Component type declarations: the public type surface (re-exported by
-- `init.luau`) plus the internal implementation views.
-- Authors: Stephen Leitnick, Logan Hunt [Raildex]
--[=[
	@class ComponentTypes
	@ignore

	`ComponentClass` / `TypedClass` are the public-facing types returned by
	`Component.new`. `ClassAny` / `InstanceAny` are the *internal* structural
	views the implementation types its `self` parameters with (TableManager's
	`TM_Internal` pattern): `ClassAny` is the API reachable on a component
	class, `InstanceAny` extends it with the fields that only exist on a bound
	component instance. `AnyComponent` is the deliberately loose `{[any]: any}`
	view used in public signatures where `any` must bridge subtyping (see the
	comments below).
]=]

const Packages = script.Parent.Parent
const Signal = require(Packages.Signal)
const Promise = require(Packages.Promise)

const Keys = require(script.Parent.Keys)
const TypeFunctions = require(script.Parent.TypeFunctions)

type Promise<T... = ()> = Promise.TypedPromise<T...>
export type LifecyclePhase = Keys.LifecyclePhase
export type StopReason = Keys.StopReason

-- Loose view of a component/class used where `any` must bridge subtyping:
-- users pass heterogeneous concrete classes ({ MyClassA, MyClassB }) into
-- `{ AnyComponent }` parameters, and array element types are invariant — only
-- `any` accepts every concrete class type there.
export type AnyComponent = { [any]: any }

export type AncestorList = { Instance }

export type ComponentSignal<T...> = Signal.Signal<(T...) -> (), T...>

--[=[
	@type ExtensionFn (component) -> ()
	@within Component
]=]
export type ExtensionFn = (any) -> ()

--[=[
	@type ExtensionYieldableFn (component) -> Promise
	@within Component

	A yieldable extension hook is one that may alternatively return a Promise.
]=]
export type ExtensionYieldableFn = (any) -> Promise

--[=[
	@type ExtensionShouldFn (component) -> boolean
	@within Component
]=]
export type ExtensionShouldFn = (any) -> boolean

--[=[
	@interface Extension
	@within Component
	.ShouldExtend ExtensionShouldFn?
	.ShouldConstruct ExtensionShouldFn?
	.Constructing ExtensionYieldableFn?
	.Constructed ExtensionYieldableFn?
	.Starting ExtensionFn?
	.Started ExtensionFn?
	.Stopping ExtensionFn?
	.Stopped ExtensionFn?
	.Extensions {Extension}?
	.Methods {[string]: (component, ...any) -> ...any}?

	Extensions hook into the component lifecycle. `ShouldConstruct` (all must pass)
	gates construction. `ShouldExtend` toggles an extension per-instance. `Methods`
	are added to the component **class** (available regardless of `ShouldExtend`);
	a name collision between two extensions, or with an existing class member, is an
	error. Extensions listed in another extension's `Extensions` array are treated
	as dependencies and resolved first (topological order; a cycle is an error).
]=]
export type Extension = {
	ShouldExtend: ExtensionShouldFn?,
	ShouldConstruct: ExtensionShouldFn?,
	Constructing: ExtensionFn?,
	Constructed: ExtensionFn?,
	Starting: ExtensionFn?,
	Started: ExtensionFn?,
	Stopping: ExtensionFn?,
	Stopped: ExtensionFn?,
	Extensions: { Extension }?,
	-- Loosely typed: the new solver rejects a user's concrete methods table
	-- (named function props) against a `{ [string]: function }` indexer type.
	Methods: any?,
}

--[=[
	@interface ComponentConfig
	@within Component
	.Tag string
	.Ancestors {Instance}?
	.Extensions {Extension}?
	.DelaySetup boolean?
	.Methods {[string]: function}?
	.Fields {[string]: any}?
	.InitFields (() -> {[string]: any})?

	Passed to `Component.new`. `Ancestors` defaults to `{workspace, Players}`.

	`Methods` are merged onto the component **class** (a name collision with an
	existing class member or an extension method is an error). `Fields` are
	deep-copied onto every component **instance** before `Construct`, so a table
	default is never shared between instances; `InitFields` is called once per
	instance and its result copied over (shallow), for fields that need to be
	built at runtime. Both are applied before `Instance` is set, so neither can
	clobber it.
]=]
export type ComponentConfig = {
	Tag: string,
	Ancestors: AncestorList?,
	-- `{ any }`, not `{ Extension }`: the new solver rejects concrete extension
	-- tables against optional structured props ("is not exactly" union checks),
	-- and the old solver can't unify heterogeneous extension arrays either way.
	-- `Extension` documents the shape; runtime validates it.
	Extensions: { any }?,
	DelaySetup: boolean?,
	-- Loosely typed for the same reason as `Extension.Methods`: the new solver
	-- rejects a concrete methods/fields table against a `{ [string]: T }`
	-- indexer. `ComponentConfigOf` is the checked, generic view used by
	-- `Component.new`; this is the documented runtime shape.
	Methods: any?,
	Fields: any?,
	InitFields: (() -> any)?,
}

-- Generic config used by `Component.new`'s signature: `E` captures the type of
-- the extension tables passed in the `Extensions` array (a union for
-- heterogeneous arrays), which the type functions turn into checked extension
-- methods on the returned class. The `[string]: any` indexer is required:
-- without it the new solver rejects config literals that omit optional keys
-- when inferring through the generic.
-- `F` and `IF` are separate generics so a config may use `Fields` and
-- `InitFields` together (they contribute different keys); the instance type
-- gets both, merged.
export type ComponentConfigOf<E, M = {}, F = { [any]: any }, IF = {}> = {
	Tag: string,
	Ancestors: AncestorList?,
	-- `Ancestors` is deliberately NOT declared here: the new solver's
	-- union-exactness rejects a concrete `{ workspace }` (i.e. `{Workspace}`)
	-- against an optional `{ Instance }` / `{ any }` prop, and array element
	-- types are invariant. It flows through the `[string]: any` indexer below;
	-- `ComponentConfig` documents and the runtime uses the real shape.
	DelaySetup: boolean?,
	Extensions: { E }?,
	-- Attaches user methods to the class type
	Methods: M?,
	-- Attaches user fields to the instance type. An alternate function form is
	-- provided for fields that may require runtime construction like tables.
	-- Anything in `Fields` is cloned/deep copied into the instance on construction.
	-- InitFields' result is just directly copied over.
	Fields: F?,
	InitFields: (() -> IF)?,
	[string]: any,
}

--[[
	The type returned by `Component.new(config)`: `M` (the config's `Methods`,
	plus `extensionMethods<E>` when it has Extensions) is merged in, so user
	methods are real, checked props, and `F` (its `Fields` / `InitFields`) lands
	on the instance type. No indexer — adding a new method after `new` is a type
	error by design.

	Usage (the `self: MyComponent` annotations close the circular type; add
	`& Component.extensionMethods<typeof(myExtension)>` to see extension methods
	checked on `self` inside method bodies):

	```lua
	local Methods = {}
	type MyComponent = Component.TypedClass<typeof(Methods)>

	function Methods.Greet(self: MyComponent, msg: string) print(self.Instance, msg) end
	function Methods.Start(self: MyComponent) self:Greet("hi") end

	local MyComponent = Component.new({ Tag = "MyComponent", Methods = Methods })
	```
]]
export type TypedClass<M = {}, F = {}, I = Instance> = {
	--- Just for easy access to the instance type. Luau hates if this is a property of the class type
	--- itself, so we make it a method.
	--- Example usage: type ti = typeof(TypedComponent:__ComponentInstanceTypeExport())
	__ComponentInstanceTypeExport: (self: TypedClass<M, F, I>) -> TypedInstance<M, F, I>,

	Tag: string,
	DelaySetup: boolean,
	RenderPriority: number?,
	Started: ComponentSignal<TypedInstance<M, F, I>>,
	Stopped: ComponentSignal<TypedInstance<M, F, I>>,
	AncestorsChanged: ComponentSignal<{ Instance }, { Instance }>,

	-- Lifecycle methods run on a component INSTANCE, so `self` is the instance
	-- type (that is what makes `self.Instance` resolve inside them).
	Construct: (self: TypedInstance<M, F, I>) -> (),
	Start: (self: TypedInstance<M, F, I>) -> ()?,
	Stop: (self: TypedInstance<M, F, I>, reason: StopReason) -> ()?,
	HeartbeatUpdate: ((self: TypedInstance<M, F, I>, dt: number) -> ())?,
	SteppedUpdate: ((self: TypedInstance<M, F, I>, dt: number) -> ())?,
	RenderSteppedUpdate: ((self: TypedInstance<M, F, I>, dt: number) -> ())?,

	Has: (self: TypedClass<M, F, I>, instance: Instance) -> boolean,
	GetLifecycleStatus: (self: TypedClass<M, F, I>, instanceOrComponent: any) -> LifecyclePhase,
	FromInstance: (self: TypedClass<M, F, I>, instance: I & Instance) -> TypedInstance<M, F, I>?,
	WaitForInstance: (
		self: TypedClass<M, F, I>,
		instance: I & Instance,
		timeout: number?
	) -> Promise<TypedInstance<M, F, I>>,
	CreateFromInstance: (self: TypedClass<M, F, I>, instance: I & Instance) -> Promise<TypedInstance<M, F, I>>,
	GetAll: <T>(self: T) -> { T },
	UpdateAncestors: (self: TypedClass<M, F, I>, newAncestors: { Instance }) -> (),
	GetAncestors: (self: TypedClass<M, F, I>) -> { Instance },

	Destroy: (self: TypedClass<M, F, I>) -> (),
} & M

export type TypedInstance<M = {}, F = {}, I = Instance> = {
	Instance: I & Instance,

	IsStarted: (self: TypedInstance<M, F, I>) -> boolean,
	AddTask: <T>(self: TypedInstance<M, F, I>, task: T, cleanupMethod: (string | boolean)?, index: any?) -> T,
	AddPromise: <T...>(self: TypedInstance<M, F, I>, promise: Promise<T...>, index: any?) -> Promise<T...>,
	RemoveTask: (self: TypedInstance<M, F, I>, index: any, dontClean: boolean?) -> (),
	GetTask: (self: TypedInstance<M, F, I>, index: any) -> any,
	-- Cross-class lookups take a foreign CLASS type `T`; a component instance is
	-- that class's shape plus its bound `Instance`, which is what the intersection
	-- models (a full `TypedInstance<...>` here would need a class -> instance type
	-- function, and bloats the solver).
	GetComponent: <T>(self: TypedInstance<M, F, I>, componentClass: T) -> (T & { Instance: Instance })?,
} & TypedClass<M, F, I> & F

-- The config's `Methods` (`M`) and its extensions' methods are merged into the
-- returned class as checked props; `Fields`/`InitFields` (`F`/`IF`) land on the
-- instance type. `TypedClass<M>` is the matching self-annotation alias.
export type NewFn = <E, M, F, IF>(
	config: ComponentConfigOf<E, M, F, IF>
) -> TypedClass<M & TypeFunctions.extensionMethods<E>, F & IF>

--------------------------------------------------------------------------------
-- Internal implementation views
--------------------------------------------------------------------------------

-- Minimal structural view of an evaera Promise. The implementation types its
-- promise plumbing against this instead of the vendored modules' inferred /
-- generic signatures (which reject our variadic glue); values are cast through
-- `unknown` at the vendor boundary.
-- Callback params are `...any` by necessity: `...unknown` would require every
-- handler to accept arbitrary arguments (contravariance), rejecting plain
-- `() -> ()` handlers; only `any` bridges both directions.
export type PromiseLike = {
	andThen: (self: PromiseLike, onResolve: (...any) -> ...any, onReject: ((...any) -> ...any)?) -> PromiseLike,
	finally: (self: PromiseLike, fn: (...any) -> ...any) -> PromiseLike,
	catch: (self: PromiseLike, fn: (...any) -> ...any) -> PromiseLike,
	timeout: (self: PromiseLike, seconds: number) -> PromiseLike,
	cancel: (self: PromiseLike) -> (),
	getStatus: (self: PromiseLike) -> string,
}

export type ComponentClass = TypedClass<{}, {}, Instance>
export type ComponentInstance = TypedInstance<{}, {}, Instance>

-- Internal view of a component CLASS: what the implementation itself reads off
-- `self` in class-level methods. Instances reach all of this through `__index`.
-- Dynamic members (user methods, the `Keys.Internal` symbol slot) stay behind
-- the `Keys` accessors and the constructors' `any` build step.
type ComponentClass_Internal_Methods = {
	_isInAncestorList: (self: ComponentClass_Internal, instance: Instance) -> boolean,
	_startWatching: (self: ComponentClass_Internal, instance: Instance) -> (),
	_stopWatching: (self: ComponentClass_Internal, instance: Instance) -> (),
	_setup: (self: ComponentClass_Internal) -> (),
}
export type ComponentClass_Internal = ComponentClass_Internal_Methods & ComponentClass

-- Internal view of a component INSTANCE: the class view plus instance-only
-- state. Lifecycle members are optional functions — the implementation
-- `type(...) == "function"`-checks before invoking, since they may be user
-- methods, base-class stubs, or absent.
export type ComponentInstance_Internal = ComponentClass_Internal_Methods & ComponentInstance & {
	_updateCleanup: { () -> () }?,
}

-- In-flight construction record kept in `ClassInternal.pending` while a
-- component's lifecycle chain runs (the slot briefly holds `true` as a
-- same-frame reservation before the record exists).
export type PendingRecord = {
	component: ComponentInstance_Internal?,
	-- Aborts an in-flight construction with the given reason. The driver wakes
	-- from whatever it is parked on and routes to teardown.
	cancel: ((StopReason) -> ())?,
	id: number,
}

return {}
