--!strict

--// Imports //--
const PathHelpers = require("./PathHelpers")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./ListenerRegistry")
const ChangeDetectorModule = require("./ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const ArrayDiffModule = require("./ArrayDiff")
const BatchUtilsModule = require("./BatchUtils")
const Signal = require("../Signal")
const JanitorModule = require("../Janitor")

--// Types //--
type Path<S> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type KeyAtPath<T, S> = PathHelpers.KeyAtPath<T, S>
type ElementAtPath<T, S> = PathHelpers.ElementAtPath<T, S>
type Janitor = JanitorModule.Janitor
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
type MoveMetadata = ArrayDiffModule.MoveMetadata
type SchemaCheck = SchemaNavigatorModule.Check
type BatchState = BatchUtilsModule.BatchState

export type Proxy<T, S> = ProxyManagerModule.Proxy<T, S>

export type DuplicateReferenceMode = "error" | "warn" | "allow" | "move" | "copy"

--------------------------------------------------------------------------------
--// Link type shapes (implemented by LinkGroup.luau / Linker.luau) //--
--------------------------------------------------------------------------------

type opKind = "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet"

-- An operation that has ALREADY been applied to the shared raw, awaiting replay
-- via `_NotifyApplied`. `Path` is in the receiving manager's own coordinates.
export type AppliedOp = {
	Kind: opKind,
	Path: PathArray,
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- An op relative to the shared object, computed by the fan-out hooks before
-- being translated into each member's own coordinates.
export type RelativeOp = {
	Kind: opKind,
	RelativePath: PathArray,
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- Payload shape passed from `fireArrayOperation` for array-op fan-out.
export type ArrayOpPayload = {
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- A positional 2-tuple { manager, path } naming a shared node inside a TM.
-- `manager` is typed loosely (`any`, not `TableManagerLike`) to avoid an
-- irregular recursive instantiation of `TM_Internal` (TM_Internal<T> ->
-- LinkGroup -> TableManagerLike -> TM_Internal<any>), which the Luau
-- type-checker cannot resolve and would poison every field of `TM_Internal`.
export type LinkAnchor = { any | Path<any> }

export type LinkGroup = {
	_object: any,
	_members: { any },
	_destroyed: boolean,
	MemberRemoved: Signal<(manager: any) -> (), any>,
	Dissolved: Signal<() -> ()>,
	Add: (self: LinkGroup, manager: any, path: Path<any>?) -> (),
	Remove: (self: LinkGroup, manager: any) -> (),
	Members: (self: LinkGroup) -> { any },
	HasMember: (self: LinkGroup, manager: any) -> boolean,
	GetAnchorPath: (self: LinkGroup, manager: any) -> PathArray?,
	NotifyChange: (self: LinkGroup, originManager: any, op: RelativeOp) -> (),
	Destroy: (self: LinkGroup) -> (),
}

export type Linker = {
	With: (self: Linker, other: any, selfPath: Path<any>?, otherPath: Path<any>?) -> (),
	Ensure: (self: Linker, path: Path<any>?) -> (),
	Unlink: (self: Linker, target: any?) -> (),
	GetManagers: (self: Linker) -> { any },
	IsLinkedWith: (self: Linker, other: any) -> boolean,
	GetGroups: (self: Linker) -> { LinkGroup },
}

--------------------------------------------------------------------------------
--// TableManager //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@interface TableManagerConfig
	.Schema SchemaCheck?
	.OnValidationFailed (path: PathArray, value: any, err: string) -> ()?
	.ListenersFireDeferred boolean?
	.DuplicateReferenceMode DuplicateReferenceMode? -- Experimental
	.EnableProxies boolean? -- Defaults to true. When false, `Proxy`/`GetProxy` are unavailable.
	.AutoLink boolean? -- When true, this manager auto-links (via `tm.Linker`) with any OTHER AutoLink manager with shared tables

	:::caution Auto Linking
	AutoLinking is an experimental feature.
	AutoLinking only supports linking with other managers that have AutoLink enabled. If you attempt 
	to link with a manager that does not have AutoLink enabled, the link will not be established. AutoLinking
	also only works when you are setting/inserting a managed table directly. It will not automatically link 
	nested tables that are placed in bulk. You can use `tm.Linker:Ensure(path)` to link nested tables.
	:::
]=]
export type TableManagerConfig = {
	Schema: SchemaCheck?,
	OnValidationFailed: ((path: PathArray, value: any, err: string) -> ())?,
	ListenersFireDeferred: boolean?,
	DuplicateReferenceMode: DuplicateReferenceMode?,
	EnableProxies: boolean?,
	AutoLink: boolean?,
}

--[=[
	@within TableManager
	@interface ForOptions
	.FireForExisting boolean? -- Defaults to true: run the handler/transform for items already present at subscribe time.
	.Defer boolean? -- Defer the initial fire (honors the registry's deferred-fire mode either way).
]=]
export type ForOptions = {
	FireForExisting: boolean?,
	Defer: boolean?,
}

export type TableManager<T = { [any]: any }> = {
	Raw: T,
	Proxy: Proxy<T, "">?,
	Linker: Linker,
	
	-- Signals (fire once per change)
	ValueChanged: Signal<(path: PathArray, newValue: any, oldValue: any) -> (), PathArray, any, any>,
	KeyAdded: Signal<(path: PathArray, key: any, newValue: any) -> (), PathArray, any, any>,
	KeyRemoved: Signal<(path: PathArray, key: any, oldValue: any) -> (), PathArray, any, any>,
	KeyChanged: Signal<(path: PathArray, key: any, newValue: any, oldValue: any) -> (), PathArray, any, any, any>,
	ArrayInserted: Signal<(path: PathArray, index: number, newValue: any) -> (), PathArray, number, any>,
	ArrayRemoved: Signal<(path: PathArray, index: number, oldValue: any) -> (), PathArray, number, any>,
	ArraySet: Signal<(path: PathArray, index: number, newValue: any, oldValue: any) -> (), PathArray, number, any, any>,

	-- Listener registration (fire for ancestors/descendants) --

	-- Fires when this path is directly reassigned OR any descendant of it
	OnChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	--- Fires ONLY when this exact path is directly reassigned (not when a
	--- descendant changes). Shorthand for `OnValueChange` with
	--- `ListenDepth = 0, ListenDepthStyle = "=="`.
	OnValueChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	--- Immediately invokes `callback` with the current value at `path`
	--- (`oldValue` and `metadata` both `nil`), then behaves like
	--- `OnValueChange` for subsequent changes.
	Observe: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata?) -> (),
		options: ListenerOptions?
	) -> Connection,

	OnKeyAdd: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyRemove: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayInsert: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayRemove: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArraySet: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	-- For / Map: reconcile the items found at `path` (a dictionary OR an array)
	-- by identity, running a handler/transform per item with automatic teardown
	-- (via a per-item Janitor) when that item leaves or is replaced. See
	-- TableManager.luau for full semantics and the identity rules per method.

	--- Identity = key. Re-runs only when a key is added/removed; a value change
	--- at an existing key does NOT re-run the handler.
	ForKeys: <S>(
		self: TableManager<T>,
		path: Path<S>,
		handler: (itemJanitor: Janitor, key: KeyAtPath<T, S>, metadata: ChangeMetadata?) -> (),
		options: ForOptions?
	) -> Connection,

	--- Identity = value (multiset; duplicate values are tracked independently).
	--- A value moving between keys/indices does NOT re-run the handler.
	ForValues: <S>(
		self: TableManager<T>,
		path: Path<S>,
		handler: (itemJanitor: Janitor, value: ElementAtPath<T, S>, metadata: ChangeMetadata?) -> (),
		options: ForOptions?
	) -> Connection,

	--- Identity = (key, value). Either changing tears down the old item and
	--- runs the handler again for the new one.
	ForPairs: <S>(
		self: TableManager<T>,
		path: Path<S>,
		handler: (
			itemJanitor: Janitor,
			key: KeyAtPath<T, S>,
			value: ElementAtPath<T, S>,
			metadata: ChangeMetadata?
		) -> (),
		options: ForOptions?
	) -> Connection,

	--- Returns a live `TableManager` keyed by `transform`'s return value, with
	--- values passed through unchanged. Re-runs `transform` only when the
	--- source key changes; a value change at an existing key refreshes the
	--- output value WITHOUT re-running `transform`. Destroying the returned
	--- manager disconnects the source subscription; destroying the SOURCE does
	--- NOT cascade-destroy the returned manager.
	MapKeys: <S>(
		self: TableManager<T>,
		path: Path<S>,
		transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> any
	) -> TableManager<any>,

	--- Returns a live `TableManager` keyed by the source key, with each entry
	--- recomputed via `transform` whenever its value changes. Same lifecycle
	--- rules as `MapKeys`.
	MapValues: <S>(
		self: TableManager<T>,
		path: Path<S>,
		transform: (entryJanitor: Janitor, value: ElementAtPath<T, S>, key: KeyAtPath<T, S>) -> any
	) -> TableManager<any>,

	--- Returns a live `TableManager` keyed by `transform`'s returned key, with
	--- the entry recomputed whenever the source key or value changes. On an
	--- output-key collision, the last write wins. Same lifecycle rules as
	--- `MapKeys`.
	MapPairs: <S>(
		self: TableManager<T>,
		path: Path<S>,
		transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> (any, any)
	) -> TableManager<any>,

	-- Helper methods
	Get: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> ValueAtPath<T, S>,
	GetProxy: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> Proxy<T, S>,
	Set: <S>(self: TableManager<T>, path: Path<S>, value: ValueAtPath<T, S>) -> (),
	ArrayInsert: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, newValue: any) -> ()
		& <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number, newValue: any) -> (),
	ArrayRemove: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number) -> any?,
	ArrayRemoveFirstValue: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, valueToFind: any) -> number?,
	ArraySwapRemove: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number) -> any?,
	ArraySwapRemoveFirstValue: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, valueToFind: any) -> number?,
	MoveTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	CopyTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	Swap: <S1, S2>(self: TableManager<T>, a: Path<S1>, b: Path<S2>) -> (),
	-- ForceNotify: <S>(self: TableManager<T>, path: Path<S> | Proxy<T, S>) -> (),
	Batch: (self: TableManager<T>, fn: () -> ()) -> (),
	Suspend: (self: TableManager<T>) -> (),
	Resume: (self: TableManager<T>) -> (),


	--- Returns a PLAIN TableManager rooted at the shared table found at `target`
	--- (a proxy, a path, or a raw value already in this manager's tree), linked
	--- to this manager via `Link` so writes on either side fan out to the other.
	Extend: <S>(self: TableManager<T>, target: Proxy<T, S> | Path<S>, config: ExtendConfig?) -> TableManager<ValueAtPath<T, S>>,

	Destroy: (self: TableManager<T>) -> (),
}

export type ExtendConfig = {
	-- Called when the extended manager's anchor diverges (the shared object is
	-- removed/replaced in this manager's tree) and it leaves the link group.
	-- Equivalent to listening on the group's `MemberRemoved` for the extended manager.
	OnDetached: (() -> ())?,
}

export type TM_Internal<T = { [any]: any }> = TableManager<T> & {
	-- fields
	_proxyManager: ProxyManagerModule.ProxyManager<T>?,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	_originalData: T,
	_schema: SchemaCheck?,
	_onValidationFailed: (<S>(path: Path<S>, value: any, err: string) -> ())?,
	_duplicateReferenceMode: DuplicateReferenceMode,
	_isDuplicateMoveInProgress: boolean?,
	_Destroyed: boolean?,
	-- Batch state
	_batchDepth: number,
	_batch: BatchState?,
	-- Exposes the write/fire core's `makeEmit` to BatchFlush without a circular require.
	_MakeEmit: (path: PathArray) -> ArrayDiffModule.Emit,
	-- Link state
	_linkGroups: { LinkGroup }?,
	_suppressLinkFanOut: boolean?,
	-- Set from `Config.AutoLink`; gates the direct write-path auto-link hook.
	_autoLink: boolean?,
	-- Lazily-created Janitor holding resources this manager owns but that live
	-- outside it (e.g. a `Map*` derived manager's subscription to its source).
	-- Flushed in `Destroy`. Reusable extension point for future derived helpers.
	_ownedCleanup: Janitor?,

	-- Re-fires listeners/signals for an op that has ALREADY been applied to the
	-- shared raw, WITHOUT mutating or snapshot-diffing. Used only by LinkGroup
	-- fan-out; `op.Path` is in this manager's own coordinates.
	_NotifyApplied: (self: TM_Internal<T>, op: AppliedOp) -> (),
}

export type TableManagerLike = TM_Internal<{[any]:any}>

return {}
