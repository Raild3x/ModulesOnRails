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
	- `"LeftAncestry"` — the instance left the valid ancestor list
	- `"InstanceDestroyed"` — the bound instance was destroyed
	- `"ClassDestroyed"` — the component class was destroyed
	- `"ConstructionCancelled"` — torn down before it finished constructing
	- `"Superseded"` — a newer construction attempt replaced this one
]=]
export type StopReason =
	"Untagged"
	| "LeftAncestry"
	| "InstanceDestroyed"
	| "ClassDestroyed"
	| "ConstructionCancelled"
	| "Superseded"

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
}

local INTERNAL = Symbol("Internal")

local Keys = {
	Internal = INTERNAL,
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
