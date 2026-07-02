--!strict
--[=[
	@ignore
	@class OpApplier
	@client

	Replays a decoded `{BufferedOp}` list onto a client `TableManager`. The
	whole list (one replicator's ops for one flush) is wrapped in a single
	`manager:Batch(...)`, so the client's own listeners see one coalesced
	update per flush regardless of how many writes the server made -- nested
	`BatchBegin`/`BatchEnd` markers (mapped straight to `Suspend`/`Resume`)
	are themselves no-ops within that outer window per TableManager2's batch
	nesting rules (CONTRACT.md S6), so they "just work" without special-casing.
]=]

local Types = require("../Shared/Types")

type TableManager<T> = Types.TableManager<T>
type BufferedOp = Types.BufferedOp

local OpApplier = {}

--[=[
	Applies `ops` (already in `Set`/`ArrayInsert`/`ArrayRemove`/`ArraySet`/
	`BatchBegin`/`BatchEnd` form) to `manager`, in order. Mirrors the
	"ops" feed contract in `ReplicationHarness._connectOpsFeed`: `Set` and
	`ArraySet` both go through `:Set` (`true` lets it build intermediate
	tables dynamically, matching a from-scratch client tree); array
	insert/remove go through their shift-aware Mutator methods so indices
	stay faithful to the server's shifts.
]=]
function OpApplier.Apply(manager: TableManager<any>, ops: { BufferedOp })
	manager:Batch(function()
		for _, op in ops do
			if op.Kind == "Set" then
				manager:Set(op.Path, op.Value, true)
			elseif op.Kind == "ArrayInsert" then
				manager:ArrayInsert(op.Path, op.Index :: number, op.Value)
			elseif op.Kind == "ArrayRemove" then
				manager:ArrayRemove(op.Path, op.Index :: number)
			elseif op.Kind == "ArraySet" then
				local elementPath = table.clone(op.Path)
				table.insert(elementPath, op.Index)
				manager:Set(elementPath, op.Value, true)
			elseif op.Kind == "BatchBegin" then
				manager:Suspend()
			elseif op.Kind == "BatchEnd" then
				manager:Resume()
			end
		end
	end)
end

return OpApplier
