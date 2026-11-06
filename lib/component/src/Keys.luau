--!strict
-- Component internal state: a single symbol key + typed accessors.
-- Authors: Stephen Leitnick, Logan Hunt [Raildex]
--[=[
	@class ComponentKeys
	@ignore

	Component classes and instances keep their private state under one symbol key
	(`Internal`) pointing at a typed table, instead of a pile of individual symbol
	keys. Access it through the typed accessors [`Keys.class`] / [`Keys.inst`] so
	field names are checked and autocompleted. The symbol (not a string key) keeps
	this state from colliding with the user-defined fields set on a component.
]=]

local Packages = script.Parent.Parent
local Symbol = require(Packages.Symbol)

--[=[
	@interface LifecyclePhase
	@within Component
	The phase a component instance is currently in. Returned by
	`ComponentClass:GetLifecycleStatus()`.

	- `"None"` — never started construction (or already fully torn down)
	- `"Constructing"` — running `Constructing` hooks / `Construct()`
	- `"Constructed"` — constructed, not yet starting
	- `"Starting"` — running `Starting` hooks / `Start()`
	- `"Started"` — fully started
	- `"Stopping"` — tearing down
	- `"Stopped"` — teardown complete
]=]
export type LifecyclePhase = "None" | "Constructing" | "Constructed" | "Starting" | "Started" | "Stopping" | "Stopped"

--[=[
	@interface StopReason
	@within Component
	Why a component is being stopped, passed as the first argument to `Stop()`.

	- `"Untagged"` — the CollectionService tag was removed
	- `"SelectorUnmatched"` — a selector-attached instance stopped matching while still parented
	- `"LeftAncestry"` — the instance left the valid ancestor list
	- `"InstanceDestroyed"` — the bound instance was destroyed
	- `"ClassDestroyed"` — the component class was destroyed
	- `"ConstructionCancelled"` — torn down before it finished constructing
	- `"Superseded"` — a newer construction attempt replaced this one
	- `"Disabled"` — the class was disabled via `SetEnabled(false)`
]=]
export type StopReason =
	"Untagged"
	| "SelectorUnmatched"
	| "LeftAncestry"
	| "InstanceDestroyed"
	| "ClassDestroyed"
	| "ConstructionCancelled"
	| "Superseded"
	| "Disabled"

-- The class's authoritative `On*` member-hook registry (Lifecycle-owned,
-- maintained by the `__newindex` interceptors — never scanned). A hook may be
-- declared at any time: registration connects it to every live instance
-- immediately and each future instance connects at its construction. Names are
-- declare-once (parity with native Collection callbacks). `events` keys are
-- the wrapped INSTANCE member names (`Touched`, not `OnTouched`).
export type HookRegistry = {
	events: { [string]: (...any) -> any },
	attrs: { [string]: (...any) -> any },
	props: { [string]: (...any) -> any },
	any: boolean,
}

-- One extension-declared hook, flattened by `Extensions.CollectHooks` at class
-- `_setup`. Extension hooks are ADDITIVE connections: they coexist with a
-- same-name class hook and with other extensions' hooks (all fire), and are
-- filtered per instance by extension activity when `ShouldExtend` varies it.
export type ExtensionHookEntry = {
	ext: any, -- source extension (identity, for the active filter)
	kind: "event" | "attr" | "prop",
	name: string, -- instance member ("Touched") or attribute/property name
	fn: (...any) -> any,
}

-- Private state carried by every component INSTANCE.
export type ComponentInternal = {
	phase: LifecyclePhase,
	started: boolean,
	stopReason: StopReason?,
	activeExtensions: { any },
	janitor: any, -- the per-instance core Janitor (AddTask etc.)
}

-- Private state carried by every component CLASS.
export type ClassInternal = {
	-- Owned by `init.luau` (tag/ancestry watching).
	ancestors: { Instance },
	watching: { [Instance]: { any } }, -- ancestry-watch connections
	-- Written by `Lifecycle.luau` as components are tracked/untracked; read
	-- widely (init's lookups, Query's compiled plans).
	instToComponents: { [Instance]: any },
	components: { any },
	-- Started sparse set, Lifecycle-owned: `startedInstances[instance]` is the
	-- 1-based index into `startedList` (dense, swap-remove on stop). Membership
	-- means "phase is Started" — maintained exactly at the Started/Stopping
	-- transitions. Both tables are mutated in place and never replaced, so
	-- Query's compiled plans capture them by reference (same guarantee as the
	-- two tables above).
	startedInstances: { [Instance]: number },
	startedList: { Instance },
	--[[ The construction-request protocol. Owned ENTIRELY by `Lifecycle.luau` —
		nothing else reads or writes these four. `pending` is a three-state slot
		(absent / `true` reservation / `PendingRecord`) and `lockConstruct` is the
		monotonic id that supersedes a stale request; keeping them in one module is
		what makes that protocol reviewable. ]]
	lockConstruct: { [Instance]: number },
	pending: { [Instance]: any },
	extensions: { any },
	classActiveExtensions: { any },
	-- True when some extension defines `ShouldExtend`, so the active set genuinely
	-- varies per instance. When false every instance resolves to
	-- `classActiveExtensions` and the per-instance topological sort is skipped.
	extensionsVaryPerInstance: boolean,
	fields: { [string]: any }?, -- config.Fields: deep-copied onto every instance
	initFields: (() -> { [string]: any })?, -- config.InitFields: called per instance
	janitor: any, -- class-level Janitor (signals + CollectionService connections)
	failed: any, -- internal Signal(instance, reason): construction ended without starting
	-- Also Lifecycle-owned. Teardowns that have begun but not yet finished:
	-- `DestroyClass` must not tear the class Janitor down while any are
	-- outstanding, or it would destroy the `Stopped`/`failed` signals those
	-- teardowns still have to fire on.
	teardownsInFlight: number,
	destroyJanitorWhenIdle: boolean,
	-- Lifecycle-owned: the live `On*` member-hook registry (see HookRegistry
	-- above) and the flattened extension hooks (see ExtensionHookEntry).
	hooks: HookRegistry,
	extensionHooks: { ExtensionHookEntry },
	-- Selector-attached classes (init.luau's selector driver): the config's
	-- selector string, and one activated query engine + changed connection per
	-- Ancestors root (union membership across roots; see `_setupSelectorDriver`).
	selector: string?,
	selectorEngines: { { query: any, conn: any } }?,
	-- `SetEnabled(false)` gates construction requests and mass-releases with
	-- reason "Disabled"; re-enabling re-requests current matches.
	enabled: boolean,
}

local INTERNAL = Symbol("Internal")

-- Class members with these names are NOT member hooks despite the `On` prefix:
-- the lifecycle/update methods and the two hook-namespace tables. Lives here
-- (not Lifecycle) so Extensions.luau can share it without a circular require.
local RESERVED_HOOK_NAMES: { [string]: boolean } = {
	OnConstruct = true,
	OnStart = true,
	OnStop = true,
	OnHeartbeat = true,
	OnPreSimulation = true,
	OnPreRender = true,
	OnAttributeChanged = true,
	OnPropertyChanged = true,
}

local Keys = {
	Internal = INTERNAL,
	ReservedHookNames = RESERVED_HOOK_NAMES,
}

--[=[
	@within ComponentKeys
	@ignore
	Returns the typed private state of a component instance.
]=]
function Keys.inst(component: any): ComponentInternal
	return component[INTERNAL]
end

--[=[
	@within ComponentKeys
	@ignore
	Returns the typed private state of a component class.
]=]
function Keys.class(class: any): ClassInternal
	return class[INTERNAL]
end

return Keys
