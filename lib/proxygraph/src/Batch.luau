--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Batch

	Defers signal firing across multiple writes. Within a Batch(fn) call,
	every node that fires signals instead records its (old, new) pair here.
	On batch end the registered flush function is called ONCE with the full
	ordered list of pending changes so that ProxyNode can stamp one
	generation for the entire flush (ensuring diamond-graph dedup works
	across all deferred changes, not just per-node).

	Multiple writes to the same node coalesce: the original `old` is
	preserved and `new` is updated to the latest value.

	ProxyNode registers a flush callback via registerFlushFn to avoid a
	circular import.
]=]

local Batch = {}

export type FlushItem = { node: any, new: any, old: any }

local _batchDepth: number = 0
local _pendingList: { { node: any, entry: { old: any, new: any } } } = {}
local _pendingSet: { [any]: { old: any, new: any } } = {}
local _flushFn: (({ FlushItem }) -> ())?

--[=[
	Called once by ProxyNode at module load time. `fn` receives the complete
	ordered list of pending changes and is responsible for bumping the
	generation once before iterating.
]=]
function Batch.registerFlushFn(fn: ({ FlushItem }) -> ())
	_flushFn = fn
end

--[=[
	Returns true while inside a Batch(fn) call.
]=]
function Batch.isBatching(): boolean
	return _batchDepth > 0
end

--[=[
	Records a pending change for `node`. Coalesces multiple writes: the
	original `old` is preserved; `new` is always updated to the latest value.
]=]
function Batch.record(node: any, oldValue: any, newValue: any)
	local existing = _pendingSet[node]
	if existing then
		existing.new = newValue
	else
		local entry = { old = oldValue, new = newValue }
		_pendingSet[node] = entry
		table.insert(_pendingList, { node = node, entry = entry })
	end
end

local function flush()
	local list = _pendingList
	_pendingList = {}
	_pendingSet = {}

	local fn = _flushFn
	if fn == nil or #list == 0 then
		return
	end

	-- Build the typed item list for the callback.
	local items: { FlushItem } = table.create(#list)
	for i, item in ipairs(list) do
		items[i] = { node = item.node, new = item.entry.new, old = item.entry.old }
	end

	fn(items)
end

--[=[
	Runs `fn` inside a batch. Signal firing is deferred until `fn` returns
	(or throws). Nested Batch calls increment the depth; flush only happens
	when the outermost batch ends.
]=]
function Batch.Batch(fn: () -> ())
	_batchDepth += 1
	local ok, err = pcall(fn)
	_batchDepth -= 1
	if _batchDepth == 0 then
		flush()
	end
	if not ok then
		error(err, 2)
	end
end

return Batch
