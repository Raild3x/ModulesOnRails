--!strict
--[=[
	@ignore
	@class BatchUtils

	Internal utilities for batch operation tracking and snapshot management.
	These functions handle serialization, state management, and snapshot navigation
	for TableManager's batch system.
]=]

--// Imports //--
const ChangeDetector = require("../Diffing/ChangeDetector")
const Diff = require("../Diffing/Diff")

--// Types //--
type PathArray = { any }
-- Structural (not `TMTypes.TableManagerLike`) on purpose: `TMTypes` itself
-- requires this module (for `BatchState`), so importing it back here would be
-- a cyclic require. Only the two fields `BuildOldSnapshot` actually reads.
type ManagerForOldSnapshot = {
	_listenerRegistry: { SnapshotRootFor: (self: any, path: PathArray) -> PathArray? },
	_changeDetector: { GetOpaqueCtx: (self: any) -> Diff.Ctx? },
}

export type BatchState = {
	StartSnapshot: ChangeDetector.Snapshot,
	TrackedPaths: { [string]: PathArray },
	DirtyBranches: { [any]: boolean },
	-- Table values detached during the batch (overwritten/removed). Proxy-graph
	-- pruning is deferred to the end of Resume so values re-homed later in the
	-- same batch (e.g. by Swap) are spared by PruneOriginal's liveness guard.
	PendingPrunes: { any },
	Flushing: boolean,
}

const BatchUtils = {}

-- Creates the ChangeMetadata.Snapshot context for array operations and
-- ForceNotify, which bypass normal ChangeDetector flow. Only RootTable is
-- ever read (ancestor value navigation), so no deep copy is taken.
function BatchUtils.CreateAncestorSnapshot<T>(rootTable: T): ChangeDetector.AncestorSnapshot<T>
	return {
		RootTable = rootTable,
	}
end

-- Serializes a path to a string key for batch tracking.
function BatchUtils.SerializeBatchPath(path: PathArray): string
	if #path == 0 then
		return "__root__"
	end
	local parts = table.create(#path)
	for i, seg in path do
		parts[i] = tostring(seg)
	end
	return table.concat(parts, "\0")
end

-- Navigates a ChangeDetector Snapshot's Diff.Snapshot children down to
-- `path`, returning the node found there (or nil if `path` doesn't resolve).
-- Shared by GetSnapshotValue/GetSnapshotRef below.
const function navigateSnapshot(snapshot: ChangeDetector.Snapshot, path: PathArray): any?
	local snap: any = snapshot.Data
	for _, key in path do
		if not snap or not snap.children then
			return nil
		end
		snap = (snap.children :: any)[key]
	end
	return snap
end

-- Returns the deep-copied value stored at `path` (i.e., the pre-batch state).
function BatchUtils.GetSnapshotValue(snapshot: ChangeDetector.Snapshot, path: PathArray): any?
	local snap = navigateSnapshot(snapshot, path)
	return snap and snap.value or nil
end

-- Like GetSnapshotValue but returns the ORIGINAL table reference captured at
-- `path` pre-batch (Diff.Snapshot.ref), not the frozen copy.
function BatchUtils.GetSnapshotRef(snapshot: ChangeDetector.Snapshot, path: PathArray): any?
	local snap = navigateSnapshot(snapshot, path)
	return snap and snap.ref or nil
end

--[=[
	Builds the `ChangeDetector.AncestorSnapshot.OldSnapshot` payload for a change
	at `basePath` whose pre-change value is `oldValue`, or `nil` when no
	`SnapshotOldValues` listener covers this change (see
	`ListenerRegistry.SnapshotRootFor`).

	`oldValue` must be the value AT `basePath` (not some ancestor of it). The
	snapshot is taken at the shallowest path that still covers every opted-in
	listener (`SnapshotRootFor`'s result), which may be `basePath` itself or a
	descendant of it -- so `oldValue` is navigated down to that path BEFORE the
	(possibly expensive) copy is taken, instead of copying the whole `oldValue`.

	`alreadyFrozen` skips the `Diff.snapshot` copy: callers that already hold a
	frozen, immutable copy of `oldValue` (e.g. `BatchFlush`'s pre-batch
	snapshot data) pass `true` so this only slices, never re-copies.
]=]
function BatchUtils.BuildOldSnapshot(
	manager: ManagerForOldSnapshot,
	basePath: PathArray,
	oldValue: any,
	alreadyFrozen: boolean?
): { Value: any, RootPath: PathArray }?
	local rootPath = manager._listenerRegistry:SnapshotRootFor(basePath)
	if rootPath == nil then
		return nil
	end

	local valueAtRoot: any = oldValue
	for i = #basePath + 1, #rootPath do
		if type(valueAtRoot) ~= "table" then
			valueAtRoot = nil
			break
		end
		valueAtRoot = valueAtRoot[rootPath[i]]
	end

	if alreadyFrozen then
		return { Value = valueAtRoot, RootPath = rootPath }
	end

	local ctx = manager._changeDetector:GetOpaqueCtx()
	return { Value = Diff.snapshot(valueAtRoot, ctx).value, RootPath = rootPath }
end

--[=[
	Like `BuildOldSnapshot`, but for an old value that is itself already a leaf
	(e.g. a single array element from a direct `ArrayRemove`/`ArraySet`/
	`ArraySwapRemove` call) rather than a container `SnapshotRootFor` could
	usefully descend into. `gatePath` is the path used to check coverage (the
	array's own registry node, so an array-level `SnapshotOldValues` listener
	still covers per-element fires); `leafPath` is `oldValue`'s own absolute
	path, used unchanged as the snapshot's `RootPath` (no navigation -- there is
	nothing between `gatePath` and `leafPath` to slice through).
]=]
function BatchUtils.BuildOldSnapshotForLeaf(
	manager: ManagerForOldSnapshot,
	gatePath: PathArray,
	leafPath: PathArray,
	oldValue: any
): { Value: any, RootPath: PathArray }?
	if manager._listenerRegistry:SnapshotRootFor(gatePath) == nil then
		return nil
	end
	local ctx = manager._changeDetector:GetOpaqueCtx()
	return { Value = Diff.snapshot(oldValue, ctx).value, RootPath = leafPath }
end

-- Gets the top-level key (first segment) for a path, used for batch branch tracking.
function BatchUtils.GetBatchBranchKey(path: PathArray): any
	return if #path > 0 then path[1] else "__root__"
end

-- Marks a branch as having changes during a batch operation.
function BatchUtils.MarkBatchBranchDirty(batch: BatchState?, path: PathArray)
	if batch then
		batch.DirtyBranches[BatchUtils.GetBatchBranchKey(path)] = true
	end
end

-- Ensures a path is being tracked in the batch for the flush's array diff.
function BatchUtils.EnsureBatchPathTracking(batch: BatchState, path: PathArray)
	local pathKey = BatchUtils.SerializeBatchPath(path)
	if batch.TrackedPaths[pathKey] then
		return
	end

	batch.TrackedPaths[pathKey] = table.clone(path)
end

return BatchUtils
