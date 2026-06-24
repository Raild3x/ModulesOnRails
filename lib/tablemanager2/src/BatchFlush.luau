--!strict
--[=[
	@ignore
	@class BatchFlush

	Owns the Suspend/Resume batch-flush engine for TableManager: while
	suspended, writes accumulate into a `BatchState` (dirty branch keys, pending
	prunes). `Resume` then diffs the pre-batch snapshot against the live data in a
	single array-aware pass — `ChangeDetector` collects array-like nodes out of
	the dict diff (so the OriginDiff stays clean) and they are LCS-re-diffed into
	shift-faithful `Array*` events afterward — firing all the resulting change
	events.
]=]

--// Imports //--
const ArrayDiffModule = require("./ArrayDiff")
const BaselineModule = require("./Baseline")
const CoalescedFlushModule = require("./CoalescedFlush")
const DiffModule = require("./Diff")
const BatchUtilsModule = require("./BatchUtils")
const PathHelpers = require("./PathHelpers")
const TMTypes = require("./TMTypes")

--// Types //--
type PathArray = PathHelpers.PathArray
type BatchState = BatchUtilsModule.BatchState
type TableManagerLike = TMTypes.TableManagerLike

const BatchFlush = {}

--[[
	Resolves the set of top-level root keys whose branch needs a flush:
	either every dirty key tracked individually, or (when a "__root__" dirty
	marker means a root-level key was written directly) every root key,
	pre-batch and current. Shared by `flushBranches` and the post-Resume shadow
	reconciliation, which both need to iterate the exact same set.
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
	Flush pass: diff only the branches that were actually mutated during the
	batch. For each dirty branch we extract the pre-batch value from the root
	snapshot's `Diff.Snapshot` children and compare it against the current live
	value, letting `ChangeDetector` fire all leaf + ancestor events.

	Runs in ARRAY-AWARE mode (`arraySink`): array-like nodes are collected out of
	each branch's dict diff (kept out of the OriginDiff) and returned for LCS
	re-diffing by `flushCollectedArrays`. Returns the collected array changes
	(absolute paths) accumulated across all branches.
]]
const function flushBranches(
	self: TableManagerLike,
	batch: BatchState,
	branchKeys: { [any]: boolean }
): { DiffModule.ArraySinkEntry }
	const arraySink: { DiffModule.ArraySinkEntry } = {}
	if not batch.StartSnapshot then
		return arraySink
	end

	const rootSnapshotData: any = batch.StartSnapshot.Data -- Diff.Snapshot

	for branchKey in branchKeys do
		-- Extract old branch value from the pre-batch snapshot's children map.
		const oldBranchValue: any = if rootSnapshotData and rootSnapshotData.children
			then (rootSnapshotData.children :: any)[branchKey] and (rootSnapshotData.children :: any)[branchKey].value or nil
			else nil

		self._changeDetector:CheckForChangesBetween(oldBranchValue, (self.Raw :: any)[branchKey], { branchKey }, self.Raw, arraySink)
	end

	return arraySink
end

--[[
	Array flush: for each array-like node collected from the dict diff, diff the
	pre-batch value against the current value via LCS (`ArrayDiff.emitDiff`),
	emitting coalesced shift-faithful Array* events. The current value is re-read
	off live (not the collected `new`) so a re-entrant write from a dict-flush
	listener is reflected. An entry whose array was removed wholesale after
	collection (no longer a table) is skipped — its removal already flowed through
	the dict diff.
]]
const function flushCollectedArrays(self: TableManagerLike, arraySink: { DiffModule.ArraySinkEntry })
	if #arraySink == 0 then
		return
	end
	const makeEmit =
		require("./Emitter").makeEmit :: (self: TableManagerLike, path: PathArray) -> ArrayDiffModule.Emit
	for _, entry in arraySink do
		const currentArray = self:Get(entry.path :: any)
		if type(currentArray) ~= "table" then
			continue
		end
		ArrayDiffModule.emitDiff(entry.old, currentArray, makeEmit(self, entry.path :: any), true)
	end
end

--[[
	Brings the persistent shadow (see ShadowNode.luau / TableManager:Flush) up to
	date for every branch touched by this batch, so the NEXT immediate
	(non-batched) flush anywhere in this batch's touched regions diffs against
	today's post-batch state instead of a stale pre-batch one. Materializing a
	branch reconciles its whole subtree (including any arrays within it), so this
	one pass covers both the dict and array changes flushed above. Does no
	diffing/firing of its own.
]]
const function reconcileShadowAfterBatch(self: TableManagerLike, branchKeys: { [any]: boolean })
	-- The trackable / opaque-ancestor gate (Materialize can't safely persist
	-- through an opaque ancestor) lives in `Baseline.Materialize`.
	for branchKey in branchKeys do
		BaselineModule.Materialize(self, { branchKey })
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
	-- snapshot/diff work is done during the window.
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

	Flush is a single array-aware pass: per dirty branch, `CheckForChangesBetween`
	diffs the pre-batch value against the current value, collecting array-like
	nodes out of the dict diff; those are then LCS-re-diffed into shift-faithful
	Array* events.
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

	const branchKeys = resolveDirtyBranchKeys(self, batch)
	const arraySink = flushBranches(self, batch, branchKeys)
	flushCollectedArrays(self, arraySink)
	reconcileShadowAfterBatch(self, branchKeys)

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

return BatchFlush
