--!strict
--[=[
	@ignore
	@class OpBuffer

	Two roles: (1) `NormalizeAppliedOp` turns a TableManager2 `AppliedOp` into a
	wire-ready `BufferedOp`, reused by `FrameCoordinator` (which now owns the
	actual per-frame ordering and flush -- a single global buffer rather than
	one per scope); and (2) the `Push`/`Drain` grouping buffer, kept as a small
	self-contained accumulator that groups ops per replicator in first-touched
	order (exercised directly by the specs and the end-to-end fidelity test).

	Ops are kept in strict per-replicator arrival order with no collapsing.
	A later phase adds an opt-in `Coalesce` mode that collapses repeated
	same-path `Set`s to latest-wins for bandwidth; correctness (exact replay)
	comes first.
]=]

local Types = require("./Types")

type Id = Types.Id
type AppliedOp = Types.AppliedOp
type BufferedOp = Types.BufferedOp

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

--[=[
	Converts a TableManager2 `AppliedOp` into a `BufferedOp`. For a `Set`, the
	op's `Diff` (when present) carries the exact same value as `NewValue` would
	have -- riding it instead of re-sending `NewValue` is free, never a
	flatten/decomposition step (see CONTRACT.md S1.3).
]=]
local function normalizeAppliedOp(op: AppliedOp): BufferedOp
	if op.Kind == "Set" then
		local value = if op.Diff ~= nil then (op.Diff :: any).new else op.NewValue
		return { Kind = "Set", Path = op.Path, Value = value }
	elseif op.Kind == "ArrayInsert" or op.Kind == "ArraySet" then
		return { Kind = op.Kind, Path = op.Path, Value = op.NewValue, Index = op.Index }
	elseif op.Kind == "ArrayRemove" then
		return { Kind = "ArrayRemove", Path = op.Path, Index = op.Index }
	else -- BatchBegin / BatchEnd: markers carry no state.
		return { Kind = op.Kind, Path = {} }
	end
end
OpBuffer.NormalizeAppliedOp = normalizeAppliedOp

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
