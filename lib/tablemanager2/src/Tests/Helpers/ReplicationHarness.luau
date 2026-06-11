--!strict
--[[
	Test helper for the replication-fidelity spec.

	Wires a SOURCE TableManager to an independent REPLICA TableManager using
	only one of two candidate "replication feeds":

	- "signals": the leaf-only public Signals (ValueChanged, ArrayInserted,
	  ArrayRemoved, ArraySet). KeyAdded/KeyRemoved/KeyChanged/ArrayMoved are
	  connected for diagnostics only (logged, never applied) since they are
	  redundant with the above for replication purposes.
	- "diff": the metadata.OriginDiff tree delivered once per operation to a
	  root `OnChange({}, ...)` listener, walked via Diff.flatten and applied
	  with a small array-vs-dict heuristic.

	Every value crossing from Source to Replica is passed through `wireCopy`,
	a deep copy with cycle detection that simulates a network boundary -
	proving the feed payloads are self-contained and not shared Luau
	references.
]]

local TableManager = require("../../TableManager")
local Diff = require("../../Diff")

export type FeedMode = "signals" | "diff"

export type OpLogEntry = {
	Signal: string,
	[string]: any,
}

--// wireCopy //--

local function wireCopy(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end

	local memo = seen or {}
	if memo[value] ~= nil then
		return memo[value]
	end

	local copy = {}
	memo[value] = copy
	for k, v in value do
		copy[wireCopy(k, memo)] = wireCopy(v, memo)
	end
	return copy
end

--// deepEqual //--

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	if #a ~= #b then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function isArrayLike(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

--// Harness //--

local ReplicationHarness = {}
ReplicationHarness.__index = ReplicationHarness

export type ReplicationHarness = typeof(setmetatable(
	{} :: {
		Source: any,
		Replica: any,
		_feedMode: FeedMode,
		_connections: { any },
		_opLog: { OpLogEntry },
		_replicaOpLog: { OpLogEntry },
	},
	ReplicationHarness
))

-- `sourceConfig` (optional) is passed to the SOURCE TableManager only; the
-- replica is always config-free, like a client that trusts the wire.
function ReplicationHarness.new(sourceInitialData: any, feedMode: FeedMode?, sourceConfig: any?): ReplicationHarness
	local self = setmetatable({}, ReplicationHarness) :: any

	self.Source = TableManager.new(sourceInitialData, sourceConfig)
	self.Replica = TableManager.new(wireCopy(sourceInitialData))
	self._feedMode = feedMode or "signals"
	self._connections = {}
	self._opLog = {}
	self._replicaOpLog = {}

	return self
end

--// Replica echo recorder //--

--[[
	Records the events the REPLICA emits while the feed is applied to it, so
	tests can assert the replica re-emits an equivalent event stream ("echo").
	Only the four state-bearing signals are recorded; KeyAdded/KeyRemoved/
	KeyChanged/ArrayMoved are derivable diagnostics on both sides.
]]
function ReplicationHarness._connectReplicaRecorders(self: ReplicationHarness)
	local replica = self.Replica
	local connections = self._connections
	local replicaOpLog = self._replicaOpLog

	table.insert(
		connections,
		replica.ValueChanged:Connect(function(path, newValue, oldValue)
			table.insert(
				replicaOpLog,
				{ Signal = "ValueChanged", Path = wireCopy(path), New = newValue, Old = oldValue } :: OpLogEntry
			)
		end)
	)
	table.insert(
		connections,
		replica.ArrayInserted:Connect(function(path, index, newValue)
			table.insert(
				replicaOpLog,
				{ Signal = "ArrayInserted", Path = wireCopy(path), Index = index, New = newValue } :: OpLogEntry
			)
		end)
	)
	table.insert(
		connections,
		replica.ArrayRemoved:Connect(function(path, index, oldValue)
			table.insert(
				replicaOpLog,
				{ Signal = "ArrayRemoved", Path = wireCopy(path), Index = index, Old = oldValue } :: OpLogEntry
			)
		end)
	)
	table.insert(
		connections,
		replica.ArraySet:Connect(function(path, index, newValue, oldValue)
			table.insert(
				replicaOpLog,
				{ Signal = "ArraySet", Path = wireCopy(path), Index = index, New = newValue, Old = oldValue } :: OpLogEntry
			)
		end)
	)
end

--// Feed: signals //--

function ReplicationHarness._connectSignalFeed(self: ReplicationHarness)
	local source = self.Source
	local replica = self.Replica
	local connections = self._connections
	local opLog = self._opLog

	table.insert(
		connections,
		source.ValueChanged:Connect(function(path, newValue, oldValue)
			local wirePath = wireCopy(path)
			table.insert(opLog, { Signal = "ValueChanged", Path = wirePath, New = newValue, Old = oldValue })

			if #wirePath == 0 then
				-- Only reachable via ForceNotify(root) where old == new; nothing to apply.
				return
			end

			if newValue == nil then
				replica:Set(wirePath, nil, true)
			else
				replica:Set(wirePath, wireCopy(newValue), true)
			end
		end)
	)

	table.insert(
		connections,
		source.ArrayInserted:Connect(function(path, index, newValue)
			local wirePath = wireCopy(path)
			table.insert(opLog, { Signal = "ArrayInserted", Path = wirePath, Index = index, New = newValue })
			replica:ArrayInsert(wirePath, index, wireCopy(newValue))
		end)
	)

	table.insert(
		connections,
		source.ArrayRemoved:Connect(function(path, index, oldValue)
			local wirePath = wireCopy(path)
			table.insert(opLog, { Signal = "ArrayRemoved", Path = wirePath, Index = index, Old = oldValue })
			replica:ArrayRemove(wirePath, index)
		end)
	)

	table.insert(
		connections,
		source.ArraySet:Connect(function(path, index, newValue, oldValue)
			local wirePath = wireCopy(path)
			table.insert(opLog, { Signal = "ArraySet", Path = wirePath, Index = index, New = newValue, Old = oldValue })

			local elementPath = table.clone(wirePath)
			table.insert(elementPath, index)
			replica:Set(elementPath, wireCopy(newValue), true)
		end)
	)

	-- Diagnostics only - NOT applied. Redundant with ValueChanged for
	-- replication; applying these too would double-apply dictionary changes.
	for _, signalName in { "KeyAdded", "KeyRemoved", "KeyChanged" } do
		table.insert(
			connections,
			(source[signalName] :: any):Connect(function(path, ...)
				table.insert(opLog, { Signal = signalName, Path = wireCopy(path), Args = table.pack(...) })
			end)
		)
	end

	-- Diagnostics only - NOT applied. ArrayMoved fires alongside the
	-- ArrayRemoved/ArrayInserted pair for the same logical move; applying it
	-- too would triple-apply.
	table.insert(
		connections,
		source.ArrayMoved:Connect(function(path, fromIndex, toIndex, value)
			table.insert(opLog, {
				Signal = "ArrayMoved",
				Path = wireCopy(path),
				FromIndex = fromIndex,
				ToIndex = toIndex,
				New = value,
			})
		end)
	)
end

--// Feed: diff //--

--[[
	Applies a single flattened Diff.DiffEntry to the replica.

	`type=="changed"` is always a Set (dict key change OR array element
	overwrite - neither shifts). `type=="added"`/`"removed"` at a numeric
	leaf key whose parent is currently array-like in the replica are treated
	as ArrayInsert/ArrayRemove (which shift); everything else is a Set to the
	new value (or nil for removal).

	NOTE: this heuristic cannot distinguish "insert into an array, shifting
	later elements" from "add a new sparse/boundary numeric dict key" purely
	from the diff - see the replication-fidelity spec's "ambiguity" section.
]]
local function applyDiffEntry(replica: any, entry: Diff.DiffEntry)
	local path = wireCopy(entry.path)
	if #path == 0 then
		return
	end

	local parentPath = table.clone(path)
	local lastKey = table.remove(parentPath)

	if entry.type == "removed" then
		if type(lastKey) == "number" then
			local parent = replica:Get(parentPath, true)
			if isArrayLike(parent) and lastKey >= 1 and lastKey <= #parent then
				replica:ArrayRemove(parentPath, lastKey)
				return
			end
		end
		replica:Set(path, nil, true)
		return
	end

	-- "added" or "changed"
	if entry.type == "added" and type(lastKey) == "number" then
		local parent = replica:Get(parentPath, true)
		if isArrayLike(parent) and lastKey >= 1 and lastKey <= #parent + 1 then
			replica:ArrayInsert(parentPath, lastKey, wireCopy(entry.new))
			return
		end
	end

	replica:Set(path, wireCopy(entry.new), true)
end

function ReplicationHarness._connectDiffFeed(self: ReplicationHarness)
	local source = self.Source
	local replica = self.Replica
	local opLog = self._opLog

	local conn = source:OnChange({}, function(_newValue, _oldValue, metadata)
		if metadata == nil or metadata.Diff ~= nil then
			-- Only the once-per-operation root ancestor firing carries the
			-- full OriginDiff tree; skip the (non-existent at root) leaf case.
			return
		end

		local originPath = wireCopy(metadata.OriginPath)
		table.insert(opLog, { Signal = "Diff", OriginPath = originPath, OriginDiff = metadata.OriginDiff })

		-- Consumer contract (verified by the "wholesale shrink" test): numeric
		-- removals from a single diff delivery MUST be applied highest-index-first,
		-- because ArrayRemove shifts later elements down. Flatten yields children
		-- in pairs() order, so we apply non-removals first (in order), then
		-- removals sorted by descending numeric leaf key.
		local entries = Diff.flatten(metadata.OriginDiff, originPath)
		local numericRemovals: { Diff.DiffEntry } = {}
		for _, entry in entries do
			local lastKey = entry.path[#entry.path]
			if entry.type == "removed" and type(lastKey) == "number" then
				table.insert(numericRemovals, entry)
			else
				applyDiffEntry(replica, entry)
			end
		end
		table.sort(numericRemovals, function(a, b)
			return (a.path[#a.path] :: number) > (b.path[#b.path] :: number)
		end)
		for _, entry in numericRemovals do
			applyDiffEntry(replica, entry)
		end
	end)

	table.insert(self._connections, conn)
end

--// Public API //--

function ReplicationHarness.Connect(self: ReplicationHarness)
	if self._feedMode == "signals" then
		self:_connectSignalFeed()
	elseif self._feedMode == "diff" then
		self:_connectDiffFeed()
	else
		error(`ReplicationHarness: unknown feed mode "{self._feedMode}"`)
	end
	self:_connectReplicaRecorders()
end

--[[
	Re-seeds the replica from a deep copy of the source's CURRENT state,
	modelling a late-joining client that receives a snapshot before streaming
	begins. Call before Connect(); pre-connect source mutations are otherwise
	never delivered.
]]
function ReplicationHarness.ResyncReplica(self: ReplicationHarness)
	local snapshot = wireCopy(self.Source.Raw)

	-- Collect stale keys before mutating; removing keys while iterating the
	-- live table would be unsafe.
	local staleKeys = {}
	for key in self.Replica.Raw do
		if snapshot[key] == nil then
			table.insert(staleKeys, key)
		end
	end
	for _, key in staleKeys do
		self.Replica:Set({ key }, nil, true)
	end

	for key, value in snapshot do
		self.Replica:Set({ key }, value, true)
	end
	-- Anything the replica emitted while re-seeding is join-time noise, not echo.
	table.clear(self._replicaOpLog)
end

--[[
	Runs one source operation, then reports whether the replica converged.
	Lets multi-operation tests prove state equality after EVERY step rather
	than only at the end.
]]
function ReplicationHarness.Step(self: ReplicationHarness, fn: () -> ()): boolean
	fn()
	return self:IsConverged()
end

function ReplicationHarness.OpCount(self: ReplicationHarness): number
	return #self._opLog
end

--[[
	Normalizes an op-log entry to its state-bearing core so the source and
	replica streams can be compared even though a replica can only re-emit
	through the public API:
	- ValueChanged(path, new)        -> set(path, new)
	- ArraySet(path, i, new)         -> set(path..i, new)  (a replica applies
	  ArraySet via :Set, which re-emits ValueChanged at the element path)
	- ArrayInserted / ArrayRemoved   -> kept as-is
	- diagnostics (Key*, ArrayMoved) -> dropped (derivable on both sides)
]]
local function normalizeForEcho(opLog: { OpLogEntry }): { any }
	local normalized: { any } = {}
	for _, entry in opLog do
		if entry.Signal == "ValueChanged" then
			table.insert(normalized, { Kind = "set", Path = entry.Path, Value = entry.New })
		elseif entry.Signal == "ArraySet" then
			local elementPath = table.clone(entry.Path)
			table.insert(elementPath, entry.Index)
			table.insert(normalized, { Kind = "set", Path = elementPath, Value = entry.New })
		elseif entry.Signal == "ArrayInserted" then
			table.insert(normalized, { Kind = "insert", Path = entry.Path, Index = entry.Index, Value = entry.New })
		elseif entry.Signal == "ArrayRemoved" then
			table.insert(normalized, { Kind = "remove", Path = entry.Path, Index = entry.Index })
		end
	end
	return normalized
end

--[[
	True when the replica re-emitted the same normalized event stream, in the
	same order, as the source produced. Only meaningful in "signals" mode: the
	diff feed's source log holds Diff entries, which normalize to nothing.
]]
function ReplicationHarness.EchoMatches(self: ReplicationHarness): boolean
	local sourceStream = normalizeForEcho(self._opLog)
	local replicaStream = normalizeForEcho(self._replicaOpLog)

	local matches = deepEqual(sourceStream, replicaStream)
	if not matches and ReplicationHarness.DEBUG then
		print(self:Diagnose())
	end
	return matches
end

--[[
	Deeply serializes a value to a stable, sorted string for debug output.
	Sorts keys so Source and Replica dumps are directly comparable line-by-line.
]]
local function serialize(value: any, indent: string?): string
	indent = indent or ""
	if type(value) ~= "table" then
		if type(value) == "string" then
			return `"{value}"`
		end
		return tostring(value)
	end

	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	if #keys == 0 then
		return "{}"
	end

	local childIndent = (indent :: string) .. "  "
	local parts = {}
	for _, k in keys do
		local keyStr = if type(k) == "string" then `"{k}"` else tostring(k)
		table.insert(parts, `{childIndent}[{keyStr}] = {serialize(value[k], childIndent)}`)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. (indent :: string) .. "}"
end

--[[
	Serializes one op-log entry to a single readable line.
]]
local function serializeOp(entry: OpLogEntry): string
	local parts = { entry.Signal }
	for k, v in entry do
		if k ~= "Signal" then
			table.insert(parts, `{k}={serialize(v)}`)
		end
	end
	return table.concat(parts, " ")
end

-- Set to true to make IsConverged() dump full Source/Replica state + op log
-- whenever it returns false. Only the failing tests print, so this stays quiet
-- for the rest of the suite.
ReplicationHarness.DEBUG = true

function ReplicationHarness.IsConverged(self: ReplicationHarness): boolean
	local converged = deepEqual(self.Source.Raw, self.Replica.Raw)
	if not converged and ReplicationHarness.DEBUG then
		print(self:Diagnose())
	end
	return converged
end

function ReplicationHarness.Diagnose(self: ReplicationHarness): string
	local lines = {
		`\n===== ReplicationHarness divergence (feed: {self._feedMode}) =====`,
		`--- Op log ({#self._opLog} entries, in apply order) ---`,
	}
	for i, entry in self._opLog do
		table.insert(lines, `  {i}. {serializeOp(entry)}`)
	end
	table.insert(lines, `--- Replica echo log ({#self._replicaOpLog} entries) ---`)
	for i, entry in self._replicaOpLog do
		table.insert(lines, `  {i}. {serializeOp(entry)}`)
	end
	table.insert(lines, `--- Source.Raw ---`)
	table.insert(lines, serialize(self.Source.Raw))
	table.insert(lines, `--- Replica.Raw ---`)
	table.insert(lines, serialize(self.Replica.Raw))
	table.insert(lines, "================================================\n")
	return table.concat(lines, "\n")
end

function ReplicationHarness.Destroy(self: ReplicationHarness)
	for _, conn in self._connections do
		conn:Disconnect()
	end
	self.Source:Destroy()
	self.Replica:Destroy()
end

ReplicationHarness.wireCopy = wireCopy
ReplicationHarness.deepEqual = deepEqual
ReplicationHarness.isArrayLike = isArrayLike

return ReplicationHarness
