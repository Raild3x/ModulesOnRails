--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class Emitter

	The single emit/notify core for TableManager. Every change event — whether
	from the diff-driven Set path (ChangeDetector callbacks) or the synthetic
	array-op path — flows through `makeEmit`/`fireArrayOperation` so the
	signal+listener dual-fire lives in exactly one place.
]=]

--// Imports //--
const PathHelpers = require("../PathHelpers")
const BatchUtilsModule = require("../Batching/BatchUtils")
const ArrayDiffModule = require("../Diffing/ArrayDiff")
const ChangeDetectorModule = require("../Diffing/ChangeDetector")
const PropagationModule = require("../Propagation")
const BaselineModule = require("../Baseline/Baseline")
const Diff = require("../Diffing/Diff")
const TMTypes = require("../TMTypes")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type MoveMetadata = ArrayDiffModule.MoveMetadata
type DiffNode = Diff.DiffNode
type TableManagerLike = TMTypes.TableManagerLike

const createAncestorSnapshot = BatchUtilsModule.CreateAncestorSnapshot

const Emitter = {}

-- ---------------------------------------------------------------------------
-- SnapshotOldValues slicing
-- ---------------------------------------------------------------------------

--[[
	Slices `metadata.Snapshot.OldSnapshot` (see `ChangeDetector.AncestorSnapshot`)
	down to the old value at `absPath`, or `nil` when no snapshot was built for
	this change (no opted-in listener covers it). `absPath` is always at or
	below `OldSnapshot.RootPath` -- guaranteed by `ListenerRegistry.SnapshotRootFor`,
	which only descends into branches that still cover an opted-in listener -- so
	the suffix walk below never has to handle `absPath` being shallower than
	`RootPath`.
]]
const function sliceOldSnapshot(metadata: ChangeMetadata?, absPath: PathArray): any?
	const oldSnapshot = if metadata then metadata.Snapshot and metadata.Snapshot.OldSnapshot else nil
	if oldSnapshot == nil then
		return nil
	end
	const rootPath = oldSnapshot.RootPath
	-- An ancestor notification's path is shorter than RootPath (RootPath is
	-- always at or below the change's basePath) -- not covered by this
	-- snapshot. Its old value is the synthetic `old == new == currentValue`
	-- anyway, so there's nothing useful to slice.
	if #absPath < #rootPath then
		return nil
	end
	local value: any = oldSnapshot.Value
	for i = #rootPath + 1, #absPath do
		if type(value) ~= "table" then
			return nil
		end
		value = value[absPath[i]]
	end
	return value
end

-- ---------------------------------------------------------------------------
-- SignalFireMode dispatch
-- ---------------------------------------------------------------------------

-- 1-based index, within a signal's packed args, of its "OldValue"-style
-- payload arg -- the one a coalesced merge must preserve from the FIRST fire
-- in the window rather than overwrite with each subsequent fire's value.
-- Signals with no such arg (KeyAdded, ArrayInserted) return nil: every
-- position there is "latest wins", so a full overwrite is already correct.
const function getOldValueArgIndex(manager: TableManagerLike, signal: any): number?
	if signal == manager.ValueChanged then
		return 3 -- path, newValue, oldValue
	elseif signal == manager.KeyChanged then
		return 4 -- path, key, newValue, oldValue
	elseif signal == manager.KeyRemoved then
		return 3 -- path, key, oldValue
	elseif signal == manager.ArrayRemoved then
		return 3 -- basePath, index, oldValue
	elseif signal == manager.ArraySet then
		return 4 -- basePath, index, newValue, oldValue
	end
	return nil
end

-- "coalesced" SignalFireMode: collapses repeated fires of the SAME signal
-- within a tick into a single `:Fire` call carrying the latest args, instead
-- of one call per fire. Implemented here (rather than as a `Signal` method)
-- because the runtime `Signal` module is resolved via `require("../Signal")`,
-- which Wally installs from the external `howmanysmall/better-signal`
-- package -- not the first-party `lib/signal` fork in this repo. A new method
-- added only to the fork would be missing on the actual installed dependency.
const function fireSignalCoalesced(manager: TableManagerLike, signal: any, ...: any)
	if not manager._signalCoalesceState then
		(manager :: any)._signalCoalesceState = {}
	end
	const state = manager._signalCoalesceState :: { [any]: { Args: { n: number, [number]: any } } }

	const entry = state[signal]
	if entry then
		const oldValueIndex = getOldValueArgIndex(manager, signal)
		const preservedOldValue = if oldValueIndex then entry.Args[oldValueIndex] else nil
		entry.Args = table.pack(...)
		if oldValueIndex then
			entry.Args[oldValueIndex] = preservedOldValue
		end
		return
	end

	const newEntry = { Args = table.pack(...) }
	state[signal] = newEntry
	task.defer(function()
		state[signal] = nil
		signal:Fire(table.unpack(newEntry.Args, 1, newEntry.Args.n))
	end)
end

-- Dispatches a fire on one of `manager`'s public per-change Signals according
-- to `manager._signalFireMode` (see `TMTypes.SignalFireMode`).
const function fireSignal(manager: TableManagerLike, signal: any, ...: any)
	const mode = manager._signalFireMode
	if mode == "deferred" then
		signal:FireDeferred(...)
	elseif mode == "bindable" then
		signal:FireBindable(...)
	elseif mode == "coalesced" then
		fireSignalCoalesced(manager, signal, ...)
	else
		signal:Fire(...)
	end
end

-- ---------------------------------------------------------------------------
-- Synthetic metadata helpers
-- ---------------------------------------------------------------------------

const function createSyntheticDiffNode(
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): DiffNode
	return {
		type = kind,
		new = newValue,
		old = oldValue,
		key = key,
	}
end

const function createSyntheticMetadata(
	rootTable: any,
	leafPath: PathArray,
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any,
	oldSnapshot: { Value: any, RootPath: PathArray }?
): ChangeMetadata
	const snapshot = createAncestorSnapshot(rootTable)
	snapshot.OldSnapshot = oldSnapshot
	return {
		Diff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		OriginPath = leafPath,
		OriginDiff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		Snapshot = snapshot,
	}
end

-- ---------------------------------------------------------------------------
-- Replication op-stream (OnApplied)
-- ---------------------------------------------------------------------------

--[[
	Fires `op` to every `OnApplied` subscriber. A non-empty `_appliedListeners`
	list IS the replication gate -- this is the only place that's checked, so
	every other call site can fire-and-forget without its own guard.
]]
function Emitter.fireApplied(manager: TableManagerLike, op: TMTypes.AppliedOp)
	const listeners = manager._appliedListeners
	if listeners[1] == nil then
		return
	end
	for _, cb in listeners do
		cb(op)
	end
end

const arrayOpKindByEventName = {
	ArrayInserted = "ArrayInsert",
	ArrayRemoved = "ArrayRemove",
	ArraySet = "ArraySet",
}

--[[
	Adaptive replication emit: when `diffNode` is already in hand (a diff ran
	for some other reason -- a covering listener, a batch flush, a ProvideDiff
	opt-in), ride it for a minimal per-leaf delta; otherwise ship `newValue`
	directly (O(1), no diff). Either way this is one `AppliedOp` per real
	changed leaf. No-ops when nothing subscribes to `OnApplied` -- this never
	triggers diffing by itself.
]]
function Emitter.emitReplicationOp(
	manager: TableManagerLike,
	kind: "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet",
	path: PathArray,
	newValue: any,
	index: number?,
	diffNode: DiffNode?
)
	if manager._appliedListeners[1] == nil then
		return
	end
	if diffNode ~= nil then
		Emitter.fireApplied(manager, { Kind = kind, Path = path, Diff = diffNode, Index = index })
	else
		Emitter.fireApplied(manager, { Kind = kind, Path = path, NewValue = newValue, Index = index })
	end
end

-- ---------------------------------------------------------------------------
-- Core notification primitives
-- ---------------------------------------------------------------------------

--[[
	Fires ancestor `ValueChanged` (and, when `includeKeyChanged` is not false,
	`KeyChanged`) listeners from `basePath` up to the root, building a
	"descendant changed" metadata for each ancestor.
]]
function Emitter.fireAncestorValueChangedNotifications(
	manager: any, -- TableManagerLike (typed `any` to avoid Luau generic-recursive poison)
	basePath: PathArray,
	metadata: ChangeMetadata,
	includeKeyChanged: boolean?
)
	debug.profilebegin("fireAncestorValueChangedNotifications")
	const ancestorMetadata: ChangeMetadata = {
		Diff = nil,
		OriginPath = metadata.OriginPath,
		OriginDiff = metadata.OriginDiff,
		Snapshot = metadata.Snapshot,
		ArrayOp = metadata.ArrayOp,
	}

	const keyChangedMode = if includeKeyChanged == false then "none" else "child"

	ChangeDetectorModule.EmitAncestorNotifications(
		basePath :: { any },
		#basePath,
		ancestorMetadata,
		nil,
		keyChangedMode,
		function(path, key, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("KeyChanged", path, {
				Key = key,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end,
		function(path, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end
	)
	debug.profileend()
end

--[[
	Fires the appropriate `Array*` signal + exact-path listeners + ancestor
	ValueChanged callbacks, and fans out to any linked managers. Must be
	called AFTER the mutation so `manager.Raw` reflects the new state.

	`knownTrackable == true` means the caller already resolved
	`Coverage.IsTrackable(manager, basePath)` for this same op (the gated
	direct-mutator paths), so the baseline sync at the bottom can skip
	re-deriving it. nil/false means "unknown" — re-derive as before.
]]
function Emitter.fireArrayOperation(
	manager: TableManagerLike,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray,
	leafPath: PathArray,
	payload: any,
	knownTrackable: boolean?
)
	-- Tag metadata with explicit shift semantics for diff-tree consumers
	-- (OriginDiff via root OnChange listeners).
	payload.Metadata.ArrayOp = { Kind = eventName, Index = payload.Index }

	-- ArrayInserted has no old value to slice; ArrayRemoved/ArraySet's shared
	-- `payload` is reused for both the element-path and array-path fires below,
	-- so the slice only needs to be computed once.
	if eventName ~= "ArrayInserted" then
		payload.OldValueSnapshot = sliceOldSnapshot(payload.Metadata, leafPath)
	end

	-- Fire at element path first (element-level listeners), then at array
	-- path (array-level listeners), then ancestors (ValueChanged).
	manager._listenerRegistry:FireListenersExact(eventName, leafPath, payload)
	manager._listenerRegistry:FireListenersExact(eventName, basePath, payload)
	Emitter.fireAncestorValueChangedNotifications(manager, basePath, payload.Metadata)

	if eventName == "ArrayInserted" then
		fireSignal(manager, manager.ArrayInserted, basePath, payload.Index, payload.NewValue)
	elseif eventName == "ArrayRemoved" then
		fireSignal(manager, manager.ArrayRemoved, basePath, payload.Index, payload.OldValue)
	elseif eventName == "ArraySet" then
		fireSignal(manager, manager.ArraySet, basePath, payload.Index, payload.NewValue, payload.OldValue)
	end

	if not manager._suppressLinkFanOut then
		PropagationModule.FanOutArrayOp(manager, eventName, basePath, payload)
	end

	-- Independent of fan-out (must still fire while replaying a propagated op,
	-- since THIS manager may have its own OnApplied subscribers): ship a
	-- replication op. Array ops never have a "no diff happening" case -- this
	-- call site is unconditional, so the array-op replication hook needs no
	-- separate apply-time fallback (unlike the dict-write Set path).
	Emitter.emitReplicationOp(
		manager,
		arrayOpKindByEventName[eventName],
		basePath,
		if eventName == "ArrayRemoved" then nil else payload.NewValue,
		payload.Index,
		nil
	)

	-- Array ops are synthetic (never diffed against the shadow), but the
	-- baseline still needs to end up reflecting the array's new contents so a
	-- LATER flush at/above `basePath` (e.g. its parent table being replaced)
	-- diffs against current data instead of a stale pre-op copy. Applied
	-- INCREMENTALLY (the same known op, not a full re-copy of the array) — see
	-- `Baseline.ApplyArrayOp`, which also owns the trackable / opaque-ancestor
	-- gate and falls back to a full `Materialize` the first time this array is
	-- tracked.
	const arrayOpValue = if eventName == "ArrayRemoved" then nil else payload.NewValue
	BaselineModule.ApplyArrayOp(manager, basePath, eventName, payload.Index, arrayOpValue, knownTrackable)
end

--[[
	The three array-op emit primitives, callable directly by single-op mutators
	(ArrayInsert/ArrayRemove/ArraySwapRemove etc.) without allocating a `makeEmit`
	closure table just to invoke one of them once. `makeEmit` below wraps these
	for callers (ArrayDiff's batch LCS re-diff) that genuinely need all three as
	a value passed around.
]]
function Emitter.emitRemoved(
	manager: TableManagerLike,
	path: PathArray,
	index: number,
	oldValue: any,
	move: MoveMetadata?,
	knownTrackable: boolean?
)
	debug.profilebegin("emitRemoved")
	const removedPath: PathArray = PathHelpers.Append(path, index)
	-- Array element old values are never a slice of some larger captured
	-- container (unlike the dict path's diff `old`, each direct array op
	-- only ever hands us the one element that changed) -- so the snapshot
	-- is anchored directly at `removedPath` itself, not `path`. Gated
	-- against `path` (the array's own registry node) so an array-level
	-- listener's `SnapshotOldValues` still covers per-element fires.
	const oldSnapshot = BatchUtilsModule.BuildOldSnapshotForLeaf(manager, path, removedPath, oldValue)
	const metadata = createSyntheticMetadata(manager.Raw, removedPath, "removed", index, nil, oldValue, oldSnapshot)
	metadata.Move = move
	Emitter.fireArrayOperation(manager, "ArrayRemoved", path, removedPath, {
		Index = index,
		OldValue = oldValue,
		Metadata = metadata,
	}, knownTrackable)
	debug.profileend()
end

function Emitter.emitInserted(
	manager: TableManagerLike,
	path: PathArray,
	index: number,
	newValue: any,
	move: MoveMetadata?,
	knownTrackable: boolean?
)
	debug.profilebegin("emitInserted")
	const insertedPath = PathHelpers.Append(path, index)
	const metadata = createSyntheticMetadata(manager.Raw, insertedPath, "added", index, newValue, nil, nil)
	metadata.Move = move
	Emitter.fireArrayOperation(manager, "ArrayInserted", path, insertedPath, {
		Index = index,
		NewValue = newValue,
		Metadata = metadata,
	}, knownTrackable)
	debug.profileend()
end

function Emitter.emitSet(
	manager: TableManagerLike,
	path: PathArray,
	index: number,
	newValue: any,
	oldValue: any,
	move: MoveMetadata?,
	knownTrackable: boolean?
)
	debug.profilebegin("emitSet")
	const setPath = PathHelpers.Append(path, index)
	const oldSnapshot = BatchUtilsModule.BuildOldSnapshotForLeaf(manager, path, setPath, oldValue)
	const metadata = createSyntheticMetadata(manager.Raw, setPath, "changed", index, newValue, oldValue, oldSnapshot)
	metadata.Move = move
	Emitter.fireArrayOperation(manager, "ArraySet", path, setPath, {
		Index = index,
		NewValue = newValue,
		OldValue = oldValue,
		Metadata = metadata,
	}, knownTrackable)
	debug.profileend()
end

--[[
	Builds the `Emit` interface for a single array path, wiring the three
	callbacks to fire `ArrayRemoved`/`ArrayInserted`/`ArraySet` signals,
	exact-path listeners, and ancestor callbacks in the correct order. Thin
	wrapper over `emitRemoved`/`emitInserted`/`emitSet` for callers (ArrayDiff's
	batch LCS re-diff) that need the three bundled as one value; single-op
	mutators should call the named functions directly instead.
]]
-- Return type is intentionally unannotated: the `set` callback accepts an
-- optional 4th `move` arg (used by ArraySwapRemove) beyond what
-- `ArrayDiff.Emit` declares, and the inferred type captures that correctly.
function Emitter.makeEmit(manager: TableManagerLike, path: PathArray)
	return {
		removed = function(index: number, oldValue: any, move: MoveMetadata?)
			Emitter.emitRemoved(manager, path, index, oldValue, move)
		end,
		inserted = function(index: number, newValue: any, move: MoveMetadata?)
			Emitter.emitInserted(manager, path, index, newValue, move)
		end,
		set = function(index: number, newValue: any, oldValue: any, move: MoveMetadata?)
			Emitter.emitSet(manager, path, index, newValue, oldValue, move)
		end,
	}
end

--[[
	Builds the synthetic-metadata struct used by the `onArrayAppended` fast path
	(for externally-supplied roots/paths/values).
]]
function Emitter.makeSyntheticMetadata(
	rootTable: any,
	leafPath: PathArray,
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): ChangeMetadata
	return createSyntheticMetadata(rootTable, leafPath, kind, key, newValue, oldValue, nil)
end

-- ---------------------------------------------------------------------------
-- ChangeDetector callback factory
-- ---------------------------------------------------------------------------

--[[
	Builds the four ChangeDetector callbacks for a newly-constructed
	TableManager, wrapping the signal+listener dual-fire in a single call site.
	Replaces the ~80 lines of near-identical inline closures in
	`TableManager.new`.
]]
function Emitter.makeChangeDetectorCallbacks(manager: TableManagerLike)
	return {
		OnKeyAdded = function(path: PathArray, key: any, newValue: any, metadata: ChangeMetadata)
			-- Signal before registry listeners: if a listener performs a re-entrant
			-- write its nested signal fires after this one, keeping the public
			-- signal stream in write-initiation order (deterministic for replication).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				fireSignal(manager, manager.KeyAdded, path, key, newValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyAdded", path, {
				NewValue = newValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyRemoved = function(path: PathArray, key: any, oldValue: any, metadata: ChangeMetadata)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				fireSignal(manager, manager.KeyRemoved, path, key, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyRemoved", path, {
				OldValue = oldValue,
				OldValueSnapshot = sliceOldSnapshot(metadata, PathHelpers.Append(path, key)),
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyChanged = function(path: PathArray, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				fireSignal(manager, manager.KeyChanged, path, key, newValue, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("KeyChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				OldValueSnapshot = sliceOldSnapshot(metadata, PathHelpers.Append(path, key)),
				Key = key,
				Metadata = metadata,
			})
		end,

		OnValueChanged = function(path: PathArray, newValue: any, oldValue: any?, metadata: ChangeMetadata)
			-- Signal before listeners (see OnKeyAdded for rationale).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				fireSignal(manager, manager.ValueChanged, path, newValue, oldValue)
			end
			manager._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				OldValueSnapshot = sliceOldSnapshot(metadata, path),
				Metadata = metadata,
			})
			-- Cross-manager fan-out: only for leaf changes, never while replaying
			-- fan-out. Pass the already-built diff node so recipients can replay it
			-- without re-diffing (see Propagation.FanOutSet / TableManager._NotifyApplied).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				if not manager._suppressLinkFanOut then
					PropagationModule.FanOutSet(manager, path, newValue, oldValue, metadata.Diff)
				end
				-- Independent of fan-out (must still fire while replaying a
				-- propagated op, since THIS manager may have its own OnApplied
				-- subscribers): ride the diff already in hand for a minimal delta.
				Emitter.emitReplicationOp(manager, "Set", path, newValue, nil, metadata.Diff)
			end
		end,
	}
end

return Emitter
