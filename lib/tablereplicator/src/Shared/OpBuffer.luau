--!strict
--[=[
	@ignore
	@class OpBuffer

	Three roles: (1) `NormalizeAppliedOp` turns a TableManager2 `AppliedOp` into
	a wire-ready `BufferedOp`, reused by `FrameCoordinator` (which now owns the
	actual per-frame ordering and flush -- a single global buffer rather than
	one per scope); (2) `PathKey`/`PathRelation`, pure path-comparison helpers
	`FrameCoordinator` uses to implement opt-in per-replicator coalescing
	(latest-wins in-place updates, ancestor subsumption, array-op barriers);
	and (3) the `Push`/`Drain` grouping buffer, kept as a small self-contained
	accumulator that groups ops per replicator in first-touched order
	(exercised directly by the specs and the end-to-end fidelity test).

	Ops are kept in strict per-replicator arrival order with no collapsing --
	`Push`/`Drain` never coalesce; that opt-in behavior lives entirely in
	`FrameCoordinator`, built on the helpers below.
]=]

local Types = require("./Types")

type Id = Types.Id
type AppliedOp = Types.AppliedOp
type BufferedOp = Types.BufferedOp
type PathArray = Types.PathArray

export type PathRelation = "equal" | "aPrefixB" | "bPrefixA" | "disjoint"

local OpBuffer = {}
OpBuffer.__index = OpBuffer

export type OpBuffer = typeof(setmetatable(
	{} :: {
		_order: { Id },
		_opsById: { [Id]: { BufferedOp } },
	},
	OpBuffer
))

function OpBuffer.new(): OpBuffer
	return setmetatable({
		_order = {},
		_opsById = {},
	}, OpBuffer)
end

-- Resolves the value a value-carrying `AppliedOp` will replicate: the `Diff`'s
-- leaf value when the op rode a diff node (a diffed op carries no `NewValue`),
-- else the raw `NewValue`. Shared by `NormalizeAppliedOp` and the server's
-- write-time value checks so both read the exact same value.
local function appliedOpValue(op: AppliedOp): any
	return if op.Diff ~= nil then (op.Diff :: any).new else op.NewValue
end
OpBuffer.AppliedOpValue = appliedOpValue

-- Converts a TableManager2 `AppliedOp` into a `BufferedOp`. For a `Set`, the
-- op's `Diff` (when present) carries the exact same value as `NewValue` would
-- have -- riding it instead of re-sending `NewValue` is free, never a
-- flatten/decomposition step (see CONTRACT.md S1.3).
local function normalizeAppliedOp(op: AppliedOp): BufferedOp
	if op.Kind == "Set" then
		return { Kind = "Set", Path = op.Path, Value = appliedOpValue(op) }
	elseif op.Kind == "ArrayInsert" or op.Kind == "ArraySet" then
		return { Kind = op.Kind :: "ArrayInsert" | "ArraySet", Path = op.Path, Value = op.NewValue, Index = op.Index }
	elseif op.Kind == "ArrayRemove" then
		return { Kind = "ArrayRemove", Path = op.Path, Index = op.Index }
	else -- BatchBegin / BatchEnd: markers carry no state.
		return { Kind = op.Kind, Path = {} }
	end
end
OpBuffer.NormalizeAppliedOp = normalizeAppliedOp

-- Type-tagging each segment before joining keeps e.g. the number `1` and the
-- string `"1"` from colliding into the same key.
local function canonicalPathKey(path: PathArray): string
	local parts = table.create(#path)
	for i, segment in path do
		parts[i] = `{typeof(segment)}:{tostring(segment)}`
	end
	return table.concat(parts, "\0")
end
OpBuffer.PathKey = canonicalPathKey

-- Compares two paths element-wise. `"equal"` means identical length and
-- elements; `"aPrefixB"`/`"bPrefixA"` means one path is a strict prefix of
-- the other (i.e. one addresses an ancestor of what the other addresses);
-- otherwise `"disjoint"`. Used by `FrameCoordinator`'s coalescing to decide
-- subsumption (a later ancestor `Set` drops buffered descendant `Set`s) and
-- array-op barriers (an array op invalidates any overlapping pending `Set`).
local function pathRelation(a: PathArray, b: PathArray): PathRelation
	local lenA, lenB = #a, #b
	local minLen = math.min(lenA, lenB)
	for i = 1, minLen do
		if a[i] ~= b[i] then
			return "disjoint"
		end
	end
	if lenA == lenB then
		return "equal"
	elseif lenA < lenB then
		return "aPrefixB"
	else
		return "bPrefixA"
	end
end
OpBuffer.PathRelation = pathRelation

--[=[
	Queues `op` (raw from `manager:OnApplied`) for replicator `id`.
]=]
function OpBuffer.Push(self: OpBuffer, id: Id, op: AppliedOp)
	local ops = self._opsById[id]
	if ops == nil then
		ops = {}
		self._opsById[id] = ops
		table.insert(self._order, id)
	end
	table.insert(ops, normalizeAppliedOp(op))
end

function OpBuffer.IsEmpty(self: OpBuffer): boolean
	return self._order[1] == nil
end

--[=[
	Returns every buffered replicator's ops, grouped and in first-touched
	order, then clears the buffer for the next frame.
]=]
function OpBuffer.Drain(self: OpBuffer): { { Id: Id, Ops: { BufferedOp } } }
	const drained = table.create(#self._order) :: { { Id: Id, Ops: { BufferedOp } } }
	for i, id in self._order do
		drained[i] = { Id = id, Ops = self._opsById[id] }
	end
	table.clear(self._order)
	table.clear(self._opsById)
	return drained
end

return OpBuffer
