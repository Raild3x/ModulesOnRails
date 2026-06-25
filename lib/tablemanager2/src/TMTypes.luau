--!strict

--// Imports //--
const PathHelpers = require("./PathHelpers")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./ListenerRegistry")
const ChangeDetectorModule = require("./ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const ArrayDiffModule = require("./ArrayDiff")
const BatchUtilsModule = require("./BatchUtils")
const OpaqueRegistryModule = require("./OpaqueRegistry")
const IgnoreTrieModule = require("./IgnoreTrie")
const DiffModule = require("./Diff")
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
type OpaqueRegistries = OpaqueRegistryModule.Registries
type IgnoreTrieNode = IgnoreTrieModule.Node
type DiffNode = DiffModule.DiffNode

export type Proxy<T, S> = ProxyManagerModule.Proxy<T, S>

-- The value returned by `Opaque`/`GlobalOpaque`/`OpaqueChildren`/
-- `GlobalOpaqueChildren` (see `OpaqueRegistry`). `Set`/`ArrayInsert` unwrap it
-- at write time; the literal value stored at the path is always the bare inner.
export type OpaqueWrapper = OpaqueRegistryModule.Wrapper

-- "allow" (default): a table written to a second location is a SUPPORTED
-- multi-location reference, not an error — both paths share identity, and the
-- write fires its own independent change events at the new path. The proxy
-- graph still reports a single "primary" anchor (whichever path established
-- the value's proxy first; see `ProxyManager._originalToProxy`). "copy": opt
-- OUT of sharing for this write by deep-cloning the value first, so the new
-- path gets its own, independent identity instead.
export type DuplicateReferenceMode = "allow" | "copy"

-- Re-export of `ListenerRegistry.FireMode` for config-surface convenience.
export type ListenerFireMode = ListenerRegistryModule.FireMode

-- Controls how the per-change Signals (`ValueChanged`, `KeyAdded`, etc.) are
-- dispatched. Defined here rather than in the `Signal` package itself since
-- it's a TableManager-level dispatch policy, not a native `Signal` method:
-- "Immediate"/"Deferred"/"Bindable" map onto `Signal:Fire`/`:FireDeferred`/
-- `:FireBindable`; "Coalesced" is implemented in `Emitter.luau` by wrapping
-- `:Fire` (see `Emitter.fireSignal`).
export type SignalFireMode = "immediate" | "deferred" | "bindable" | "coalesced"

-- Controls WHEN `_doFlush` (the shadow diff + fire + reconcile cycle) runs for
-- a direct write. "immediate" (default) runs it synchronously, same as today.
-- "coalesced" defers it to frame-end (`task.defer`) and merges every flush
-- request made before then into one flush at their common ancestor path, so a
-- frame with N writes under one subtree costs one diff/fire instead of N. See
-- `CoalescedFlush.luau`.
export type FlushMode = "immediate" | "coalesced"

--------------------------------------------------------------------------------
--// Cross-manager fan-out type shapes (see Propagation.luau) //--
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
	-- Phase B (linked fan-out): the origin's already-computed diff node for a
	-- "Set", so a recipient can dispatch it WITHOUT re-running `Diff.diff`. Only
	-- populated when the origin had no opacity active (`OriginHasNoOpacity`) —
	-- the diff tree's shape is otherwise per-manager opacity-dependent.
	Diff: DiffNode?,
	-- True when the origin's opacity ctx was nil at fan-out time. A recipient
	-- may only reuse `Diff` when it ALSO has no opacity active.
	OriginHasNoOpacity: boolean?,
}

-- Payload shape passed from `fireArrayOperation` for array-op fan-out.
export type ArrayOpPayload = {
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

--------------------------------------------------------------------------------
--// TableManager //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@interface TableManagerConfig
	.Schema SchemaCheck?
	.OnValidationFailed (path: PathArray, value: any, err: string) -> ()?
	.ListenerFireMode ListenerFireMode? -- Controls how listener callbacks (OnChange, OnValueChange, etc.) are scheduled when fired. Defaults to "immediate".
	.SignalFireMode SignalFireMode? -- Controls how the per-change Signals (ValueChanged, KeyAdded, etc.) are scheduled when fired. Defaults to "immediate".
	.FlushMode FlushMode? -- Controls WHEN a direct write's diff+fire+reconcile cycle runs. Defaults to "immediate". See `FlushMode`.
	.DuplicateReferenceMode DuplicateReferenceMode? -- Defaults to "allow" (multi-location references are supported). See `DuplicateReferenceMode`.
	.EnableProxies boolean? -- Defaults to true. When false, `Proxy`/`GetProxy` are unavailable.
	.IgnoredPaths { Path }? -- Paths (and their descendants) that skip diff/snapshot/event work entirely; see `SetPathIgnored`.

	:::note Implicit sharing
	Linking is automatic: any table reachable (transparently) in two or more
	managers' trees is observed by all of them, and a write through one propagates
	to the others. Mark a region `Opaque`/`OpaqueChildren` to opt it out.
	:::
]=]
export type TableManagerConfig = {
	Schema: SchemaCheck?,
	OnValidationFailed: ((path: PathArray, value: any, err: string) -> ())?,
	ListenerFireMode: ListenerFireMode?,
	SignalFireMode: SignalFireMode?,
	FlushMode: FlushMode?,
	DuplicateReferenceMode: DuplicateReferenceMode?,
	EnableProxies: boolean?,
	IgnoredPaths: { Path<any> }?,
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
	Set: <S>(self: TableManager<T>, path: Path<S>, value: ValueAtPath<T, S> | OpaqueWrapper) -> (),
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

	--- Diffs the persistent shadow baseline against the live value at `path`
	--- (the whole tree when omitted), fires any resulting events, then
	--- reconciles the shadow to the current live value. A no-op when nothing
	--- observes `path`. Outside a batch this runs immediately; inside one it
	--- just marks the branch dirty for `Resume`'s flush, so an explicit
	--- `Flush` can never break batch atomicity. Also the supported way to
	--- surface a mutation made by external code that bypassed `Set`/`Proxy`.
	Flush: <S>(self: TableManager<T>, path: Path<S>?) -> (),

	--- Marks `path` (and every descendant of it) as ignored or not: an ignored
	--- write still happens, but skips all diff/snapshot/event work. See
	--- `TableManagerConfig.IgnoredPaths` for the config-time equivalent.
	SetPathIgnored: <S>(self: TableManager<T>, path: Path<S>, ignored: boolean) -> (),


	--- Returns a PLAIN TableManager rooted at the shared table found at `target`
	--- (a proxy, a path, or a raw value already in this manager's tree), linked
	--- to this manager via `Link` so writes on either side fan out to the other.
	Extend: <S>(self: TableManager<T>, target: Proxy<T, S> | Path<S>) -> TableManager<ValueAtPath<T, S>>,

	--- Returns the other managers currently sharing (co-observing) at least one
	--- live table identity with this one — de-duplicated, excluding self.
	GetLinkedManagers: (self: TableManager<T>) -> { any },
	--- Returns true if this manager currently shares a live table identity with `other`.
	IsLinkedWith: (self: TableManager<T>, other: any) -> boolean,

	Destroy: (self: TableManager<T>) -> (),
}

export type TM_Internal<T = { [any]: any }> = TableManager<T> & {
	-- fields
	_proxyManager: ProxyManagerModule.ProxyManager<T>?,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	-- Set from `Config.SignalFireMode`; controls `Emitter.fireSignal` dispatch.
	_signalFireMode: SignalFireMode,
	-- Lazily created by `Emitter.fireSignalCoalesced` when `SignalFireMode == "Coalesced"`.
	_signalCoalesceState: { [any]: { Args: { n: number, [number]: any } } }?,
	_schema: SchemaCheck?,
	_onValidationFailed: ((path: PathArray, value: any, err: string) -> ())?,
	_duplicateReferenceMode: DuplicateReferenceMode,
	_Destroyed: boolean?,
	-- Batch state
	_batchDepth: number,
	_batch: BatchState?,

	-- Set from `Config.FlushMode`; controls `CoalescedFlush.Request` routing.
	_flushMode: FlushMode,
	-- The running common-ancestor path of every flush requested since the last
	-- coalesced flush drained, or nil when nothing is pending. See `CoalescedFlush`.
	_pendingFlushRoot: PathArray?,
	-- True while a `task.defer` is outstanding to drain `_pendingFlushRoot`.
	_coalescedFlushScheduled: boolean?,

	-- Cross-manager sharing state. `_suppressLinkFanOut` guards against
	-- re-fanning-out while replaying a propagated op. `_sharesObservers` is a
	-- sticky flag set when this manager comes to co-observe a table identity with
	-- another, so `Coverage.IsTrackable` forces its writes to flush (so a write by
	-- a member with no local listeners still diffs and fans out). See `Propagation`.
	_suppressLinkFanOut: boolean?,
	_sharesObservers: boolean?,
	_janitor: Janitor,

	_opaqueRegistries: OpaqueRegistries,
	_ignoreTrie: IgnoreTrieNode,

	-- Re-fires listeners/signals for an op that has ALREADY been applied to the
	-- shared raw, WITHOUT mutating or snapshot-diffing. Used only by cross-manager
	-- fan-out (see `Propagation`); `op.Path` is in this manager's own coordinates.
	_NotifyApplied: (self: TM_Internal<T>, op: AppliedOp) -> (),
	_doFlush: (self: TM_Internal<T>, path: PathArray) -> (),
}

export type TableManagerLike = TM_Internal<{[any]:any}>

return {}
