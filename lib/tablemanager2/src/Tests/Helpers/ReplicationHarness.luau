--!strict
--[[
	Test helper for the replication-fidelity spec.

	Wires a SOURCE TableManager to an independent REPLICA TableManager using
	only one of two candidate "replication feeds":

	- "signals": the leaf-only public Signals (ValueChanged, ArrayInserted,
	  ArrayRemoved, ArraySet). KeyAdded/KeyRemoved/KeyChanged are connected
	  for diagnostics only (logged, never applied) since they are redundant
	  with the above for replication purposes.
	- "diff": the metadata.OriginDiff tree delivered once per operation to a
	  root `OnChange({}, ...)` listener. Array operations arrive tagged with
	  metadata.ArrayOp (explicit shift semantics); everything else is walked
	  via Diff.flatten and applied as plain Sets with ancestor entries
	  shadowing their descendants. See _connectDiffFeed for the full contract.

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

-- Human-readable path label for diagnostics. tostrings every segment so
-- non-string keys (numbers, booleans) are safe to join.
local function describePath(path: { any }): string
	local parts = table.create(#path)
	for i, segment in path do
		parts[i] = tostring(segment)
	end
	return table.concat(parts, ".")
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

--[=[
	@class ReplicationHarness
	@ignore

	Test helper for the replication-fidelity spec.
]=]
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
		_applyErrors: { { Op: string, Error: string } },
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
	self._applyErrors = {}

	return self
end

--[[
	Runs one replica apply, recording (instead of swallowing) any error.

	Feed handlers run in signal-handler threads, where an uncaught error kills
	only that one invocation and is merely printed - it does NOT fail the test.
	That hid a real defect class: a redundant or late event that errors on
	apply, while the replica happens to already hold the right state (e.g. a
	child-removal event delivered after its parent was replaced by a scalar).
	Every apply goes through here, and IsConverged() reports false if ANY apply
	errored, so state-level tests also act as apply-error detectors.
]]
function ReplicationHarness._apply(self: ReplicationHarness, opDescription: string, applyFn: () -> ())
	local ok, err = pcall(applyFn)
	if not ok then
		table.insert(self._applyErrors, { Op = opDescription, Error = tostring(err) })
	end
end

--- Returns the errors recorded while applying feed events to the replica.
function ReplicationHarness.ApplyErrors(self: ReplicationHarness): { { Op: string, Error: string } }
	return self._applyErrors
end

--// Replica echo recorder //--

--[[
	Records the events the REPLICA emits while the feed is applied to it, so
	tests can assert the replica re-emits an equivalent event stream ("echo").
	Only the four state-bearing signals are recorded; KeyAdded/KeyRemoved/
	KeyChanged are derivable diagnostics on both sides.
]]
function ReplicationHarness._connectReplicaRecorders(self: ReplicationHarness)
	const replica = self.Replica
	const connections = self._connections
	const replicaOpLog = self._replicaOpLog

	const valueChangedConn = replica.ValueChanged:Connect(function(path, newValue, oldValue)
		table.insert(
			replicaOpLog,
			{ Signal = "ValueChanged", Path = wireCopy(path), New = newValue, Old = oldValue } :: OpLogEntry
		)
	end)
	table.insert(connections, valueChangedConn)

	const arrayInsertedConn = replica.ArrayInserted:Connect(function(path, index, newValue)
		table.insert(
			replicaOpLog,
			{ Signal = "ArrayInserted", Path = wireCopy(path), Index = index, New = newValue } :: OpLogEntry
		)
	end)
	table.insert(connections, arrayInsertedConn)

	const arrayRemovedConn = replica.ArrayRemoved:Connect(function(path, index, oldValue)
		table.insert(
			replicaOpLog,
			{ Signal = "ArrayRemoved", Path = wireCopy(path), Index = index, Old = oldValue } :: OpLogEntry
		)
	end)
	table.insert(connections, arrayRemovedConn)

	const arraySetConn = replica.ArraySet:Connect(function(path, index, newValue, oldValue)
		table.insert(
			replicaOpLog,
			{ Signal = "ArraySet", Path = wireCopy(path), Index = index, New = newValue, Old = oldValue } :: OpLogEntry
		)
	end)
	table.insert(connections, arraySetConn)
end

--// Feed: signals //--

function ReplicationHarness._connectSignalFeed(self: ReplicationHarness)
	const source = self.Source
	const replica = self.Replica
	const connections = self._connections
	const opLog = self._opLog

	const valueChangedConn = source.ValueChanged:Connect(function(path, newValue, oldValue)
		const wirePath = wireCopy(path)
		const opLogEntry: OpLogEntry = { Signal = "ValueChanged", Path = wirePath, New = newValue, Old = oldValue }
		table.insert(opLog, opLogEntry)

		if #wirePath == 0 then
			-- Only reachable via ForceNotify(root) where old == new; nothing to apply.
			return
		end

		self:_apply(`ValueChanged {describePath(wirePath)}`, function()
			if newValue == nil then
				replica:Set(wirePath, nil, true)
			else
				replica:Set(wirePath, wireCopy(newValue), true)
			end
		end)
	end)
	table.insert(connections, valueChangedConn)

	const arrayInsertedConn = source.ArrayInserted:Connect(function(path, index, newValue)
		const wirePath = wireCopy(path)
		const opLogEntry: OpLogEntry = { Signal = "ArrayInserted", Path = wirePath, Index = index, New = newValue }
		table.insert(opLog, opLogEntry)

		self:_apply(`ArrayInserted {describePath(wirePath)}@{index}`, function()
			replica:ArrayInsert(wirePath, index, wireCopy(newValue))
		end)
	end)
	table.insert(connections, arrayInsertedConn)

	const arrayRemovedConn = source.ArrayRemoved:Connect(function(path, index, oldValue)
		const wirePath = wireCopy(path)
		const opLogEntry: OpLogEntry = { Signal = "ArrayRemoved", Path = wirePath, Index = index, Old = oldValue }
		table.insert(opLog, opLogEntry)

		self:_apply(`ArrayRemoved {describePath(wirePath)}@{index}`, function()
			replica:ArrayRemove(wirePath, index)
		end)
	end)
	table.insert(connections, arrayRemovedConn)

	const arraySetConn = source.ArraySet:Connect(function(path, index, newValue, oldValue)
		const wirePath = wireCopy(path)
		const opLogEntry: OpLogEntry =
			{ Signal = "ArraySet", Path = wirePath, Index = index, New = newValue, Old = oldValue }
		table.insert(opLog, opLogEntry)

		self:_apply(`ArraySet {describePath(wirePath)}@{index}`, function()
			const elementPath = table.clone(wirePath)
			table.insert(elementPath, index)
			replica:Set(elementPath, wireCopy(newValue), true)
		end)
	end)
	table.insert(connections, arraySetConn)

	-- Diagnostics only - NOT applied. Redundant with ValueChanged for
	-- replication; applying these too would double-apply dictionary changes.
	for _, signalName in { "KeyAdded", "KeyRemoved", "KeyChanged" } do
		const conn = (source[signalName] :: any):Connect(function(path, ...)
			const opLogEntry: OpLogEntry = { Signal = signalName, Path = wireCopy(path), Args = table.pack(...) }
			table.insert(opLog, opLogEntry)
		end)
		table.insert(connections, conn)
	end
end

--// Feed: diff //--

-- Builds a type-qualified string key for a path so prefix lookups can't be
-- spoofed by tostring collisions (e.g. 1 vs "1").
local function diffEntryPathKey(path: { any }): string
	local parts = table.create(#path)
	for i, segment in path do
		parts[i] = `{typeof(segment)}:{tostring(segment)}`
	end
	return table.concat(parts, "\0")
end

--[[
	Diff-feed consumer contract (mirrors what a TableReplicator rebuild must do):

	1. Array operations arrive tagged with `metadata.ArrayOp` and MUST be
	   applied as array ops: ArrayInserted/ArrayRemoved SHIFT later elements,
	   ArraySet does not. A flattened "removed" entry at a numeric leaf is
	   otherwise indistinguishable from an in-place nil write (a hole).
	2. Everything else is flattened and applied as plain (non-shifting) Sets:
	   `added`/`changed` set `entry.new`, `removed` sets nil.
	3. Within one delivery, an entry whose path extends another entry's path is
	   SHADOWED and skipped: the ancestor entry's `new` carries the whole
	   subtree (e.g. a scalar<->table transition), so it is authoritative and
	   applying descendants too could target paths that no longer hold tables.
	   Surviving entries have no ancestor/descendant relation, so apply order
	   does not matter.
]]
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
		table.insert(
			opLog,
			{
				Signal = "Diff",
				OriginPath = originPath,
				OriginDiff = metadata.OriginDiff,
				ArrayOp = metadata.ArrayOp,
			} :: OpLogEntry
		)

		local arrayOp = metadata.ArrayOp
		if arrayOp then
			self:_apply(`{arrayOp.Kind} {describePath(originPath)}`, function()
				local arrayPath = table.clone(originPath)
				table.remove(arrayPath)
				if arrayOp.Kind == "ArrayInserted" then
					replica:ArrayInsert(arrayPath, arrayOp.Index, wireCopy(metadata.OriginDiff.new))
				elseif arrayOp.Kind == "ArrayRemoved" then
					replica:ArrayRemove(arrayPath, arrayOp.Index)
				else -- ArraySet: in-place element overwrite, no shift
					replica:Set(originPath, wireCopy(metadata.OriginDiff.new), true)
				end
			end)
			return
		end

		local entries = Diff.flatten(metadata.OriginDiff, originPath)

		local entryPathKeys: { [string]: boolean } = {}
		for _, entry in entries do
			entryPathKeys[diffEntryPathKey(entry.path)] = true
		end
		local function isShadowed(path: { any }): boolean
			for i = 1, #path - 1 do
				local prefix = table.create(i)
				table.move(path, 1, i, 1, prefix)
				if entryPathKeys[diffEntryPathKey(prefix)] then
					return true
				end
			end
			return false
		end

		for _, entry in entries do
			if #entry.path == 0 or isShadowed(entry.path) then
				continue
			end
			self:_apply(`Diff:{entry.type} {describePath(entry.path)}`, function()
				if entry.type == "removed" then
					replica:Set(wireCopy(entry.path), nil, true)
				else
					replica:Set(wireCopy(entry.path), wireCopy(entry.new), true)
				end
			end)
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
	- diagnostics (Key*) -> dropped (derivable on both sides)
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
	-- Apply errors fail convergence even when the final state happens to match:
	-- an event a real consumer would crash on is not a healthy feed.
	local converged = #self._applyErrors == 0 and deepEqual(self.Source.Raw, self.Replica.Raw)
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
	table.insert(lines, `--- Apply errors ({#self._applyErrors}) ---`)
	for i, applyError in self._applyErrors do
		table.insert(lines, `  {i}. [{applyError.Op}] {applyError.Error}`)
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
