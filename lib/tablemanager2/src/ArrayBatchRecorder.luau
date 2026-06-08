--!strict
--[=[
	@ignore
	@class ArrayBatchRecorder

	Records in-place array operations during a `TableManager` batch using stable element
	identities so that index churn caused by insertions and removals does not corrupt
	the operation log.

	## Why identity tagging is needed

	Array ops shift indices. An early `Insert(2)` renumbers every subsequent op. You
	cannot bucket ops by index. Solution: assign each element a stable internal id at
	batch-start time. New elements get fresh ids at insert time.

	## Workflow

	```lua
	-- At batch start, for each array path that gets touched:
	recorder:StartTracking(path, currentArray)

	-- During batch, log every in-place op:
	recorder:RecordInsert(path, index, value)
	recorder:RecordRemove(path, index)
	recorder:RecordSet(path, index, newValue, oldValue)

	-- If a direct index assignment is detected (poisoning Branch B):
	recorder:MarkPoisoned(path)

	-- At flush:
	for path, log in recorder:GetAllLogs() do
		if log.poisoned or ... then
			-- Branch A: ArrayDiff.emitDiff(log.startCopy, currentArray, emit, setMode)
		else
			-- Branch B: recorder:Coalesce(log, currentArray, emit, honorIntent)
		end
	end
	```

	## Coalesce semantics (Branch B only)

	Ops are bucketed by stable element id and the net effect per id is resolved:

	| Lifecycle                          | Event emitted                  |
	|------------------------------------|-------------------------------|
	| existed at start, untouched        | nothing                        |
	| existed at start, value changed    | `Set(firstOld, lastNew)`       |
	| existed at start, removed          | `Remove`                       |
	| born during batch, survives        | `Insert(finalValue)`           |
	| born during batch, also removed    | nothing (born-and-died)        |

	Final indices are resolved ONCE from the surviving ids in their final array order,
	not computed incrementally.

	## Move metadata

	When an element id existed at start, was removed, and a *different* id carrying the
	same value was inserted at a different position, the remove+insert pair is annotated
	with a shared `moveId` string and `fromIndex`/`toIndex` on the emitted `MoveMetadata`.
	Listeners that ignore the metadata see a normal remove+insert pair.

	## `honorIntent` flag (Branch B only)

	When `true` (default), a `RecordSet` op fires `ArraySet` even if the net
	old/new values happen to be equal. When `false`, re-derives net effect (may
	suppress the event). Branch A always uses net-effect semantics.
]=]

local PathHelpers = require(script.Parent.PathHelpers)
type Path = PathHelpers.Path
type PathArray = PathHelpers.PathArray

local ArrayDiff = require(script.Parent.ArrayDiff)
type Emit = ArrayDiff.Emit

--// Types //--

--[=[
	@within ArrayBatchRecorder
	@interface MoveMetadata
	.moveId string -- Shared id string linking the remove and insert
	.fromIndex number -- Final position of the Remove in the flush sequence
	.toIndex number -- Final position of the Insert in the flush sequence

	Optional metadata attached to an insert/remove pair that constitutes a move.
	Listeners that do not read this field see a normal remove + insert.
]=]
export type MoveMetadata = {
	moveId: string, -- Shared id string linking the remove and insert
	fromIndex: number, -- Final position of the Remove in the flush sequence
	toIndex: number, -- Final position of the Insert in the flush sequence
}

-- A single recorded operation, keyed by stable element id.
type Op = {
	type: "insert" | "remove" | "set",
	elementId: number,
	index: number, -- Index AT THE TIME of the op (for intent tracking only; not used for final index resolution)
	value: any, -- New value (for insert/set) or removed value (for remove)
	oldValue: any?, -- Only for set ops
}

-- Per-array batch log.
export type ArrayLog = {
	startRef: { [any]: any }, -- Original table reference (for reassignment detection)
	startCopy: { any }, -- Shallow copy of values at batch start (for Branch A)
	startIds: { [number]: number }, -- index -> stable id mapping at batch start
	ops: { Op }, -- Ordered op transcript
	nextId: number, -- Next fresh id to assign
	poisoned: boolean, -- True = direct index assignment detected; use Branch A
}

export type ArrayBatchRecorder = {
	-- Public API
	StartTracking: (self: ArrayBatchRecorder, path: Path, array: { any }) -> (),
	RecordInsert: (self: ArrayBatchRecorder, path: Path, index: number, value: any) -> (),
	RecordRemove: (self: ArrayBatchRecorder, path: Path, index: number) -> (),
	RecordSet: (self: ArrayBatchRecorder, path: Path, index: number, newValue: any, oldValue: any) -> (),
	MarkPoisoned: (self: ArrayBatchRecorder, path: Path) -> (),
	GetLog: (self: ArrayBatchRecorder, path: Path) -> ArrayLog?,
	GetAllLogs: (self: ArrayBatchRecorder) -> { [string]: ArrayLog },
	Coalesce: (
		self: ArrayBatchRecorder,
		log: ArrayLog,
		currentArray: { any },
		emit: Emit,
		honorIntent: boolean
	) -> (),
	Destroy: (self: ArrayBatchRecorder) -> (),

	_getOrCreateLog: (self: ArrayBatchRecorder, path: Path, array: { any }?) -> ArrayLog, -- Private helper
	_computeLiveIds: (self: ArrayBatchRecorder, log: ArrayLog) -> { number }, -- Private helper
	-- Private
	_logs: { [string]: ArrayLog }, -- keyed by serialized path
	_globalNextId: number, -- global id counter shared across all tracked arrays
}

--------------------------------------------------------------------------------
--// Helpers //--
--------------------------------------------------------------------------------

-- Serializes a path to a stable string key for use as a table key.
local function serializePath(path: Path): string
	if #path == 0 then
		return "__root__"
	end
	local parts = table.create(#path)
	for i, segment in path do
		parts[i] = tostring(segment)
	end
	return table.concat(parts, "\0")
end

-- Returns a shallow copy of an array's values (for Branch A startCopy).
local function shallowCopyArray(array: { any }): { any }
	const copy = table.create(#array)
	for i = 1, #array do
		copy[i] = array[i]
	end
	return copy
end

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ArrayBatchRecorder = {}
local ArrayBatchRecorder_MT = { __index = ArrayBatchRecorder }

--[=[
	Creates a new `ArrayBatchRecorder` instance.
]=]
function ArrayBatchRecorder.new(): ArrayBatchRecorder
	return setmetatable({
		_logs = {},
		_globalNextId = 1,
	}, ArrayBatchRecorder_MT) :: any
end

--[=[
	Gets the log for a path, creating it if it does not exist.
	Private helper.
]=]
function ArrayBatchRecorder._getOrCreateLog(self: ArrayBatchRecorder, path: Path, array: { any }?): ArrayLog
	const key = serializePath(path)
	local log = self._logs[key]
	if not log then
		-- Auto-start tracking if array is provided
		if array then
			self:StartTracking(path, array)
			log = self._logs[key]
		else
			error(
				`ArrayBatchRecorder: path {table.concat(path :: { string }, ".")} is not being tracked. Call StartTracking first.`
			)
		end
	end
	return log
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	Begins tracking the array at `path`. Must be called before any `Record*` calls
	for that path.

	Assigns stable ids to all current elements and captures the start state.
]=]
function ArrayBatchRecorder.StartTracking(self: ArrayBatchRecorder, path: Path, array: { any })
	const key = serializePath(path)
	if self._logs[key] then
		return -- Already tracking; idempotent
	end

	-- Assign stable ids to existing elements
	const startIds: { [number]: number } = {}
	for i = 1, #array do
		const id = self._globalNextId
		self._globalNextId += 1
		startIds[i] = id
	end

	self._logs[key] = {
		startRef = array,
		startCopy = shallowCopyArray(array),
		startIds = startIds,
		ops = {},
		nextId = self._globalNextId, -- snapshot of id counter at start
		poisoned = false,
	}
end

--[=[
	Records an insertion at `index` with `value`.
	The inserted element receives a fresh stable id.
]=]
function ArrayBatchRecorder.RecordInsert(self: ArrayBatchRecorder, path: PathArray, index: number, value: any)
	const log = self:_getOrCreateLog(path)

	-- Assign a fresh id for the new element
	const newId = self._globalNextId
	self._globalNextId += 1

	table.insert(log.ops, {
		type = "insert" :: "insert",
		elementId = newId,
		index = index,
		value = value,
		oldValue = nil,
	})
end

--[=[
	Records the removal of the element at `index`.
	Resolves to the stable id of that element from the live id sequence.
]=]
function ArrayBatchRecorder:RecordRemove(path: Path, index: number)
	const log = self:_getOrCreateLog(path)

	-- Replay prior ops to find the current live id at `index`
	const liveIds: { number } = self:_computeLiveIds(log)
	const elementId = liveIds[index]

	if not elementId then
		-- Out-of-bounds removal — poison and bail to Branch A
		log.poisoned = true
		return
	end

	table.insert(log.ops, {
		type = "remove" :: "remove",
		elementId = elementId,
		index = index,
		value = nil,
		oldValue = nil,
	})
end

--[=[
	Records a value change at `index` (no length change).
]=]
function ArrayBatchRecorder:RecordSet(path: Path, index: number, newValue: any, oldValue: any)
	const log = self:_getOrCreateLog(path)

	-- Resolve to stable id
	const liveIds: { number } = self:_computeLiveIds(log)
	const elementId = liveIds[index]

	if not elementId then
		log.poisoned = true
		return
	end

	table.insert(log.ops, {
		type = "set" :: "set",
		elementId = elementId,
		index = index,
		value = newValue,
		oldValue = oldValue,
	})
end

--[=[
	Marks the array at `path` as poisoned. This forces Branch A (LCS snapshot diff)
	at flush time. Call this when a direct numeric index assignment is detected.
]=]
function ArrayBatchRecorder.MarkPoisoned(self: ArrayBatchRecorder, path: Path)
	const key = serializePath(path)
	const log = self._logs[key]
	if log then
		log.poisoned = true
	end
	-- If not tracked yet, lazily mark as poisoned when StartTracking is called
	-- by poisoning immediately after creation — handled in flush routing.
end

--[=[
	Returns the `ArrayLog` for `path`, or `nil` if not tracked.
]=]
function ArrayBatchRecorder.GetLog(self: ArrayBatchRecorder, path: Path): ArrayLog?
	return self._logs[serializePath(path)]
end

--[=[
	Returns the full log table, keyed by serialized path string.
	Iterate with `for key, log in recorder:GetAllLogs() do`.
]=]
function ArrayBatchRecorder.GetAllLogs(self: ArrayBatchRecorder): { [string]: ArrayLog }
	return self._logs
end

--[=[
	Computes the **coalesced** net events for `log` and dispatches them through `emit`.

	This is Branch B. It:
	1. Buckets ops by stable element id
	2. Computes net effect per id
	3. Resolves final indices from the surviving id sequence ONCE
	4. Emits events in index order

	`honorIntent`: when `true`, a `RecordSet` op always fires `set` even if net
	old == net new. When `false`, a no-change set is suppressed.
]=]
function ArrayBatchRecorder.Coalesce(
	self: ArrayBatchRecorder,
	log: ArrayLog,
	currentArray: { any },
	emit: Emit,
	honorIntent: boolean
)
	-- ── Step 1: replay the op log to get the final live id sequence ──────────

	const finalIds = self:_computeLiveIds(log)

	-- ── Step 2: bucket ops by element id ─────────────────────────────────────

	-- Per-id summary: what is the net effect?
	type IdRecord = {
		existedAtStart: boolean,
		startValue: any, -- value at batch start (for "existed" ids)
		firstOld: any, -- earliest old value seen (for Set)
		lastNew: any, -- most recent value seen
		removed: boolean, -- was this id removed?
		hasSetOp: boolean, -- did a RecordSet op target this id?
	}

	const records: { [number]: IdRecord } = {}

	-- Pre-populate with start-state ids
	for startIndex, id in log.startIds do
		records[id] = {
			existedAtStart = true,
			startValue = log.startCopy[startIndex],
			firstOld = log.startCopy[startIndex],
			lastNew = log.startCopy[startIndex],
			removed = false,
			hasSetOp = false,
		}
	end

	-- Process ops in order
	for _, op in log.ops do
		local rec = records[op.elementId]

		if op.type == "insert" then
			if not rec then
				-- Born during batch
				records[op.elementId] = {
					existedAtStart = false,
					startValue = nil,
					firstOld = nil,
					lastNew = op.value,
					removed = false,
					hasSetOp = false,
				}
			else
				-- Re-inserted after removal (same id re-used — shouldn't happen with
				-- the current id scheme, but handle defensively)
				rec.removed = false
				rec.lastNew = op.value
			end
		elseif op.type == "remove" then
			if rec then
				rec.removed = true
			end
		elseif op.type == "set" then
			if rec then
				-- firstOld stays as-is (already set from start state or prior insert)
				rec.lastNew = op.value
				rec.hasSetOp = true
			end
		end
	end

	-- ── Step 3: resolve final indices from surviving id sequence ─────────────

	-- finalIds is the live id sequence after all ops — same order as currentArray.
	-- Map id -> final index.
	const idToFinalIndex: { [number]: number } = {}
	for finalIndex, id in finalIds do
		idToFinalIndex[id] = finalIndex
	end

	-- ── Step 4: build event list ordered by final index ──────────────────────

	type PendingEvent = {
		finalIndex: number,
		kind: "insert" | "remove" | "set",
		id: number,
		value: any,
		oldValue: any?,
		-- Move metadata (optional)
		moveId: string?,
		fromIndex: number?,
		toIndex: number?,
	}

	const pending: { PendingEvent } = {}

	-- Collect removals first (so we can match moves against inserts)
	const removedIds: { [number]: { value: any, startIndex: number } } = {}

	for id, rec in records do
		if rec.removed then
			-- Find original index (from startIds)
			local startIndex = 0
			for si, sid in log.startIds do
				if sid == id then
					startIndex = si
					break
				end
			end
			removedIds[id] = { value = rec.startValue, startIndex = startIndex }
		end
	end

	-- Move detection: for each born-and-surviving id with the same value as a removed id
	-- → link them with a shared moveId.
	local moveCounter = 0
	const moveLinks: { [number]: { partnerId: number, moveId: string } } = {}

	for newId, newRec in records do
		if not newRec.existedAtStart and not newRec.removed then
			-- Born and surviving — check if value matches any removed id
			for removedId, removedInfo in removedIds do
				if removedInfo.value == newRec.lastNew and not moveLinks[removedId] then
					moveCounter += 1
					const moveIdStr = `move_{moveCounter}`
					moveLinks[removedId] = { partnerId = newId, moveId = moveIdStr }
					moveLinks[newId] = { partnerId = removedId, moveId = moveIdStr }
					break
				end
			end
		end
	end

	-- Build pending events
	for id, rec in records do
		if rec.removed and rec.existedAtStart then
			-- Existed at start, removed
			local removedInfo = removedIds[id]
			const moveLink = moveLinks[id]
			-- Use startIndex as sort key for removals (they no longer have a final index)
			table.insert(pending, {
				finalIndex = removedInfo and removedInfo.startIndex or 0,
				kind = "remove" :: "remove",
				id = id,
				value = rec.startValue,
				oldValue = nil,
				moveId = moveLink and moveLink.moveId or nil,
				fromIndex = removedInfo and removedInfo.startIndex or nil,
				toIndex = nil,
			})
		elseif not rec.existedAtStart and not rec.removed then
			-- Born during batch, survives → Insert
			const finalIndex = idToFinalIndex[id] or 0
			const moveLink = moveLinks[id]
			table.insert(pending, {
				finalIndex = finalIndex,
				kind = "insert" :: "insert",
				id = id,
				value = rec.lastNew,
				oldValue = nil,
				moveId = moveLink and moveLink.moveId or nil,
				fromIndex = nil,
				toIndex = finalIndex,
			})
		elseif rec.existedAtStart and not rec.removed then
			-- Existed and survived — check for value change
			const valueChanged = rec.firstOld ~= rec.lastNew
			const hadSetOp = rec.hasSetOp

			if valueChanged or (honorIntent and hadSetOp) then
				const finalIndex = idToFinalIndex[id] or 0
				table.insert(pending, {
					finalIndex = finalIndex,
					kind = "set" :: "set",
					id = id,
					value = rec.lastNew,
					oldValue = rec.firstOld,
				})
			end
			-- else: untouched or no-change — no event
		end
		-- born-and-died: not existedAtStart AND removed → no event (skip)
	end

	-- Sort by final index so events are emitted in ascending position order.
	-- Removals use their start index as sort key (they're interleaved into
	-- the flush sequence based on where they were).
	table.sort(pending, function(a: any, b: any)
		return a.finalIndex < b.finalIndex
	end)

	-- ── Step 5: emit ─────────────────────────────────────────────────────────

	for _, event in pending do
		if event.kind == "remove" then
			emit.removed(event.finalIndex, event.value)
		elseif event.kind == "insert" then
			emit.inserted(event.finalIndex, event.value)
		elseif event.kind == "set" then
			emit.set(event.finalIndex, event.value, event.oldValue :: any)
		end
	end
end

--[=[
	Frees all batch state. Call after flush is complete.
]=]
function ArrayBatchRecorder:Destroy()
	table.clear(self._logs)
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

--[=[
	Replays the op log to compute the current live id sequence (array of ids
	in the same order as the current array). Used internally to resolve stable
	ids to their current index positions.
]=]
function ArrayBatchRecorder._computeLiveIds(self: ArrayBatchRecorder, log: ArrayLog): { number }
	-- Start from the id sequence at batch start
	const liveIds: { number } = {}
	for i = 1, #log.startCopy do
		liveIds[i] = log.startIds[i]
	end

	-- Apply each op to simulate the id sequence
	for _, op in log.ops do
		if op.type == "insert" then
			table.insert(liveIds, op.index, op.elementId)
		elseif op.type == "remove" then
			table.remove(liveIds, op.index)
		end
		-- "set" does not change the id sequence
	end

	return liveIds
end

return ArrayBatchRecorder
