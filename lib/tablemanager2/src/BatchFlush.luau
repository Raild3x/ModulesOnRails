--!strict
--[=[
	@ignore
	@class BatchFlush

	Owns the Suspend/Resume batch-flush engine for TableManager: while
	suspended, writes accumulate into a `BatchState` (tracked array paths,
	dirty branch keys, pending prunes). `Resume` then diffs the pre-batch
	snapshot against the live data in two phases — a per-branch non-array
	diff and a per-tracked-array LCS diff — firing all the resulting change
	events.
]=]

--// Imports //--
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./BatchUtils")
const ArrayDiffModule = require("./ArrayDiff")
const BaselineModule = require("./Baseline")
const CoalescedFlushModule = require("./CoalescedFlush")
const TMTypes = require("./TMTypes")

--// Localize batch utils to avoid function call overhead //--
const serializeBatchPath = BatchUtilsModule.SerializeBatchPath
const getSnapshotValue = BatchUtilsModule.GetSnapshotValue
const getSnapshotRef = BatchUtilsModule.GetSnapshotRef

--// Types //--
type PathArray = PathHelpers.PathArray
type BatchState = BatchUtilsModule.BatchState
type TableManagerLike = TMTypes.TableManagerLike

const BatchFlush = {}

--[[
	Returns `branchValue` with every still-existing tracked-array subtree under
	`branchKey` replaced by its pre-batch snapshot value, cloning only the
	tables along each spine (live data is never mutated; returns `branchValue`
	itself when nothing is masked).

	The array flush is the sole owner of tracked-array content changes: it
	emits coalesced, shift-faithful Array* events. Leaving those changes in the
	non-array branch diff too would deliver them a second time — as in-place
	positional entries that are NOT shift-faithful — to any consumer of the
	root-listener OriginDiff delivery.

	Arrays that were removed wholesale during the batch are NOT masked (the
	array flush skips non-table paths, so their removal must flow through this
	branch diff), and arrays created during the batch are already pruned from
	TrackedPaths before this runs.
]]
const function maskTrackedArraysForBranchDiff(
	self: TableManagerLike,
	batch: BatchState,
	branchKey: any,
	branchValue: any
): any
	if type(branchValue) ~= "table" then
		return branchValue
	end

	-- Deepest-first so a shallower mask planted later wholesale-replaces (and
	-- never walks through) a frozen subtree planted by a deeper mask.
	const pathsToMask: { { any } } = {}
	for _, trackedPath in batch.TrackedPaths do
		if trackedPath[1] == branchKey then
			table.insert(pathsToMask, trackedPath)
		end
	end
	table.sort(pathsToMask, function(a: { any }, b: { any })
		return #a > #b
	end)

	local masked = branchValue
	for _, trackedPath in pathsToMask do
		-- Only mask while the array still exists as a table.
		local liveValue: any = self.Raw
		for _, key in trackedPath do
			if type(liveValue) ~= "table" then
				break
			end
			liveValue = liveValue[key]
		end
		if type(liveValue) ~= "table" then
			continue
		end

		const preBatchValue = getSnapshotValue(batch.StartSnapshot, trackedPath)
		if preBatchValue == nil then
			continue
		end

		if #trackedPath == 1 then
			-- The branch itself is the tracked array.
			masked = preBatchValue
			continue
		end

		-- Clone the spine from the branch root down to the array's parent and
		-- plant the pre-batch value, so the diff sees this subtree as unchanged.
		if masked == branchValue then
			masked = table.clone(branchValue)
		end
		local cursor: any = masked
		for i = 2, #trackedPath - 1 do
			const key = trackedPath[i]
			if type(cursor[key]) ~= "table" then
				cursor = nil
				break
			end
			cursor[key] = table.clone(cursor[key])
			cursor = cursor[key]
		end
		if cursor ~= nil then
			cursor[trackedPath[#trackedPath]] = preBatchValue
		end
	end

	return masked
end

--[[
	Removes TrackedPaths entries for arrays that did not exist in the pre-batch
	snapshot (created during the batch). A newly-created array's container does
	not yet exist on a downstream consumer, so coalesced Array* events (which
	assume the container exists) cannot be applied. Instead the non-array flush
	emits its creation as ordinary key/value adds (the same path a non-batched
	creation takes), which build the container and its elements. Removing them
	here also stops `BatchFlush.ShouldSuppress` from suppressing those adds.
]]
const function pruneArraysCreatedDuringBatch(batch: BatchState)
	for pathKey, path in batch.TrackedPaths do
		if getSnapshotRef(batch.StartSnapshot, path) == nil then
			batch.TrackedPaths[pathKey] = nil
		end
	end
end

--[[
	Resolves the set of top-level root keys whose branch needs a flush:
	either every dirty key tracked individually, or (when a "__root__" dirty
	marker means a root-level key was written directly) every root key,
	pre-batch and current. Shared by `flushNonArrayBranches` and the
	post-Resume shadow reconciliation, which both need to iterate the exact
	same set.
]]
const function resolveDirtyBranchKeys(self: TableManagerLike, batch: BatchState): { [any]: boolean }
	const rootSnapshot = batch.StartSnapshot
	const rootSnapshotData: any = if rootSnapshot then rootSnapshot.Data else nil

	local branchKeys: { [any]: boolean } = {}
	if batch.DirtyBranches["__root__"] then
		if rootSnapshotData and rootSnapshotData.children then
			for key in rootSnapshotData.children :: any do
				branchKeys[key] = true
			end
		end
		for key in self.Raw :: any do
			branchKeys[key] = true
		end
	else
		for branchKey in batch.DirtyBranches do
			branchKeys[branchKey] = true
		end
	end
	return branchKeys
end

--[[
	Non-array flush: diff only the branches that were actually mutated during
	the batch. This avoids traversing the whole table when only a small subset
	of keys changed. For each dirty branch key we extract the pre-batch value
	from the root snapshot's Diff.Snapshot children and compare it against the
	current live value, letting ChangeDetector fire all leaf + ancestor events.

	Tracked-array subtrees are MASKED out of each branch diff (see
	maskTrackedArraysForBranchDiff): flushTrackedArrays is the sole owner of
	their content changes, so the branch diff must not also carry them.
]]
const function flushNonArrayBranches(self: TableManagerLike, batch: BatchState, branchKeys: { [any]: boolean })
	if not batch.StartSnapshot then
		return
	end

	const rootSnapshot = batch.StartSnapshot
	const rootSnapshotData: any = rootSnapshot.Data -- Diff.Snapshot

	for branchKey in branchKeys do
		-- Extract old branch value from the pre-batch snapshot's children map.
		const oldBranchValue: any = if rootSnapshotData and rootSnapshotData.children
			then (rootSnapshotData.children :: any)[branchKey] and (rootSnapshotData.children :: any)[branchKey].value or nil
			else nil

		-- Current live value for this branch, with still-existing tracked
		-- arrays substituted by their pre-batch values (no change to report).
		const newBranchValue: any = maskTrackedArraysForBranchDiff(self, batch, branchKey, (self.Raw :: any)[branchKey])

		self._changeDetector:CheckForChangesBetween(oldBranchValue, newBranchValue, { branchKey }, self.Raw)
	end
end

--[[
	Array flush: for each tracked array path, diff the pre-batch snapshot value
	against the current value via LCS (`ArrayDiff.emitDiff`), emitting coalesced
	Array* events. Arrays removed wholesale during the batch are skipped here —
	their removal flows through the non-array branch diff instead.
]]
const function flushTrackedArrays(self: TableManagerLike, batch: BatchState)
	const makeEmit =
		require("./Emitter").makeEmit :: (self: TableManagerLike, path: PathHelpers.PathArray) -> ArrayDiffModule.Emit
	for _, path in batch.TrackedPaths do
		const currentArray = self:Get(path)
		if type(currentArray) ~= "table" then
			continue
		end

		const oldArray: { any } = getSnapshotValue(batch.StartSnapshot, path) or {}
		ArrayDiffModule.emitDiff(oldArray, currentArray, makeEmit(self, path), true)
	end
end

--[[
	Brings the persistent shadow (see ShadowNode.luau / TableManager:Flush) up to
	date for every branch/array touched by this batch, so the NEXT immediate
	(non-batched) flush anywhere in this batch's touched regions diffs against
	today's post-batch state instead of a stale pre-batch one. Only the two
	per-op flush phases above actually fired events for this batch — this
	pass does no diffing/firing of its own, just `Materialize`s whichever
	touched paths are still trackable now that the batch is done.
]]
const function reconcileShadowAfterBatch(self: TableManagerLike, batch: BatchState, branchKeys: { [any]: boolean })
	-- The trackable / opaque-ancestor gate (Materialize can't safely persist
	-- through an opaque ancestor) lives in `Baseline.Materialize`.
	for branchKey in branchKeys do
		BaselineModule.Materialize(self, { branchKey })
	end
	for _, path in batch.TrackedPaths do
		BaselineModule.Materialize(self, path)
	end
end

--[=[
	Suspends all signal and listener firing.

	Pair with `Resume()`. Nested calls are no-ops (the outermost window wins).
]=]
function BatchFlush.Suspend(self: TableManagerLike)
	if self._batchDepth > 0 then
		return -- Already suspended; nested Suspend is a no-op
	end
	-- Drain any outstanding coalesced flush BEFORE capturing the pre-batch
	-- snapshot below. The snapshot is read directly off live data; if a
	-- coalesced flush were still pending, that read would silently become the
	-- new baseline and the transition the pending flush was holding (shadow
	-- vs. the live value just before THIS snapshot) would never reach any
	-- listener — the pending flush later no-ops once the batch's own Resume
	-- has already reconciled the shadow past it. Flushing first makes the
	-- shadow authoritative again, so the snapshot below picks up cleanly from
	-- it.
	CoalescedFlushModule.FlushPending(self)
	-- Capture the pre-batch snapshot BEFORE suspending ChangeDetector so that
	-- CheckForChangesBetween at flush time can diff old-vs-current correctly.
	-- `CaptureSnapshot` inside `ChangeDetector` returns a sentinel (O(1)) so no
	-- snapshot/diff work is done during the window. Tracked array paths are
	-- diffed against this snapshot via LCS at flush time.
	self._batch = {
		StartSnapshot = self._changeDetector:CaptureSnapshot(self.Raw, {}),
		TrackedPaths = {},
		DirtyBranches = {},
		PendingPrunes = {},
		Flushing = false,
	}
	self._batchDepth = 1
	self._changeDetector:Suspend()
end

--[=[
	Resumes after `Suspend()` and flushes all pending changes.

	Flush is two-phase:
	1. **Non-array flush** — per dirty branch, `CheckForChangesBetween` diffs the
	   pre-batch value against the current value (with tracked-array subtrees
	   masked out — the array flush owns those), firing all non-array events.
	2. **Array flush** — For each tracked array path, diffs the pre-batch
	   snapshot against the current value via LCS (`ArrayDiff.emitDiff`).
]=]
function BatchFlush.Resume(self: TableManagerLike)
	if self._batchDepth == 0 then
		return -- Not suspended
	end

	-- Re-enable ChangeDetector before the flush so CheckForChangesBetween works normally.
	self._changeDetector:Resume()
	const batch = self._batch
	if not batch then
		self._batchDepth = 0
		return
	end
	batch.Flushing = true

	pruneArraysCreatedDuringBatch(batch)
	const branchKeys = resolveDirtyBranchKeys(self, batch)
	flushNonArrayBranches(self, batch, branchKeys)
	flushTrackedArrays(self, batch)
	reconcileShadowAfterBatch(self, batch, branchKeys)

	-- Clear batch state
	batch.Flushing = false
	self._batchDepth = 0
	self._batch = nil

	-- Prune proxy bookkeeping for values detached during the batch. Done after
	-- the flush (and after _batch is cleared, so a re-entrant write from a flush
	-- listener that detached a table prunes immediately rather than queueing
	-- into a dead batch). Values re-homed during the batch are spared by
	-- PruneOriginal's liveness guard.
	if self._proxyManager then
		for _, removedValue in batch.PendingPrunes do
			self._proxyManager:PruneOriginal(removedValue)
		end
	end
end

-- During batch array flush: suppress any change event whose location is at or
-- under a tracked array path. Those arrays emit their own coalesced Array*
-- events in the array flush phase, so the non-array flush firing here too would
-- double-apply the change for consumers (e.g. replication). This covers the
-- array container, its numeric element slots, AND string-keyed fields of array
-- elements (e.g. {"items", 1, "hp"}), which a numeric-only check would miss.
-- Arrays created during the batch are pruned from TrackedPaths before the flush
-- (see Resume) so their creation flows through the non-array flush instead.
function BatchFlush.ShouldSuppress(self: TableManagerLike, location: PathArray): boolean
	const batch = self._batch
	if batch == nil or not batch.Flushing then
		return false
	end
	const tracked = batch.TrackedPaths
	for i = 1, #location do
		const prefix = table.create(i)
		for j = 1, i do
			prefix[j] = location[j]
		end
		if tracked[serializeBatchPath(prefix)] ~= nil then
			-- Only suppress when the tracked array STILL EXISTS, because only
			-- then does the array flush re-emit its contents. If the array was
			-- removed wholesale during the batch, the array flush skips it, so its
			-- removal must be allowed through this (non-array) flush instead.
			if type(self:Get(prefix, true)) == "table" then
				return true
			end
		end
	end
	return false
end

return BatchFlush
