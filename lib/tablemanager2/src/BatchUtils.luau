--!strict
--[=[
	@ignore
	@class BatchUtils

	Internal utilities for batch operation tracking and snapshot management.
	These functions handle serialization, state management, and snapshot navigation
	for TableManager's batch system.
]=]

--// Imports //--
const Diff = require("./Diff")
const ArrayBatchRecorder = require("./ArrayBatchRecorder")
const ChangeDetector = require("./ChangeDetector")

--// Types //--
type PathArray = { any }
type ArrayBatchRecorder = ArrayBatchRecorder.ArrayBatchRecorder

export type BatchState = {
	Recorder: ArrayBatchRecorder,
	StartSnapshot: ChangeDetector.Snapshot,
	TrackedPaths: { [string]: PathArray },
	DirtyBranches: { [any]: boolean },
	Flushing: boolean,
}

const BatchUtils = {}

-- Creates a synthetic snapshot for array operations and ForceNotify.
-- These operations bypass normal ChangeDetector flow, so we create a compatible
-- Snapshot payload using Diff's canonical snapshot builder.
function BatchUtils.CreateSyntheticSnapshot<T>(rootTable: T, path: { any }, value: any): ChangeDetector.Snapshot
	return {
		RootTable = rootTable,
		Path = path,
		Data = Diff.snapshot(value),
		Timestamp = os.clock(),
	}
end

-- Serializes a path to a string key for batch tracking.
-- Must match the serialization used by ArrayBatchRecorder.
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

-- Navigates a ChangeDetector Snapshot's Diff.Snapshot children and returns
-- the deep-copied value stored at `path` (i.e., the pre-batch state).
function BatchUtils.GetSnapshotValue(snapshot: ChangeDetector.Snapshot, path: { any }): any?
	local snap: any = snapshot.Data
	for _, key in path do
		if not snap or not snap.children then
			return nil
		end
		snap = (snap.children :: any)[key]
	end
	return snap and snap.value or nil
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

-- Ensures a path is being tracked in the batch, calling startTracking callback if needed.
function BatchUtils.EnsureBatchPathTracking(batch: BatchState, path: { any }, startTracking: () -> ())
	local pathKey = BatchUtils.SerializeBatchPath(path)
	if batch.TrackedPaths[pathKey] then
		return
	end

	batch.TrackedPaths[pathKey] = table.clone(path)
	startTracking()
end

return BatchUtils
