--!strict
--[=[
	@ignore
	@class BatchUtils

	Internal utilities for batch operation tracking and snapshot management.
	These functions handle serialization, state management, and snapshot navigation
	for TableManager's batch system.
]=]

--// Imports //--
const ChangeDetector = require("./ChangeDetector")

--// Types //--
type PathArray = { any }

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
function BatchUtils.SerializeBatchPath(path: { any }): string
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
local function navigateSnapshot(snapshot: ChangeDetector.Snapshot, path: { any }): any?
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
function BatchUtils.GetSnapshotValue(snapshot: ChangeDetector.Snapshot, path: { any }): any?
	local snap = navigateSnapshot(snapshot, path)
	return snap and snap.value or nil
end

-- Like GetSnapshotValue but returns the ORIGINAL table reference captured at
-- `path` pre-batch (Diff.Snapshot.ref), not the frozen copy.
function BatchUtils.GetSnapshotRef(snapshot: ChangeDetector.Snapshot, path: { any }): any?
	local snap = navigateSnapshot(snapshot, path)
	return snap and snap.ref or nil
end

-- Gets the top-level key (first segment) for a path, used for batch branch tracking.
function BatchUtils.GetBatchBranchKey(path: { any }): any
	return if #path > 0 then path[1] else "__root__"
end

-- Marks a branch as having changes during a batch operation.
function BatchUtils.MarkBatchBranchDirty(batch: BatchState?, path: { any })
	if batch then
		batch.DirtyBranches[BatchUtils.GetBatchBranchKey(path)] = true
	end
end

-- Ensures a path is being tracked in the batch for the flush's array diff.
function BatchUtils.EnsureBatchPathTracking(batch: BatchState, path: { any })
	local pathKey = BatchUtils.SerializeBatchPath(path)
	if batch.TrackedPaths[pathKey] then
		return
	end

	batch.TrackedPaths[pathKey] = table.clone(path)
end

return BatchUtils
