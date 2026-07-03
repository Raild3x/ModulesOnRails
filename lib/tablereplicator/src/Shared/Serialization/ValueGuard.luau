--!strict
--[[
	Single source of truth for which values a `RemoteEvent` can't serialize, shared
	by two layers:

	• `BufferCodec`'s encode-time guard, which substitutes nil on the wire so one
	  bad value can't fail the whole batched message at `FireClient`; and
	• `ServerReplicator`'s optional write-time checks, which warn at the mutation
	  site (with the offending path) so the mistake is easy to find in Studio.

	`NonReplicableTypes` is deliberately a *block-list*, never an allow-list: it only
	ever names types that genuinely can't cross a remote, so a real datatype value
	is never flagged. The trade-off is that an exotic non-serializable userdata not
	listed here slips through -- extend the set as such cases surface.
]]

-- `typeof` results a RemoteEvent can't serialize. Contents never change.
const NON_REPLICABLE_TYPES: { [string]: true } = {
	["function"] = true,
	thread = true,
	RBXScriptSignal = true,
	RBXScriptConnection = true,
}

local ValueGuard = {}
ValueGuard.NonReplicableTypes = NON_REPLICABLE_TYPES

--[[
	Shallow O(1) check: returns the offending `typeof` name when `value` itself is
	a type a RemoteEvent can't serialize, along with an (empty) relative path so the
	shape matches `FindNonReplicable`. Returns `nil` when `value`'s own type is fine
	(it does NOT descend into a table's contents). Cheap enough to run on every write.
]]
const function badTopLevelType(value: any): (string?, { any }?)
	const valueType = typeof(value)
	if NON_REPLICABLE_TYPES[valueType] then
		return valueType, {}
	end
	return nil, nil
end
ValueGuard.BadTopLevelType = badTopLevelType

-- Recursive worker for `FindNonReplicable`. `seen` guards against cyclic tables.
const function find(value: any, seen: { [any]: true }): (string?, { any }?)
	const valueType = typeof(value)
	if NON_REPLICABLE_TYPES[valueType] then
		return valueType, {}
	end
	if valueType ~= "table" then
		return nil, nil
	end
	if seen[value] then
		return nil, nil
	end
	seen[value] = true

	for key, entry in value :: { [any]: any } do
		-- A non-serializable table KEY is as fatal as a value: it would encode as a
		-- nil key and error on decode. Report it at this table's own path.
		const keyType = typeof(key)
		if NON_REPLICABLE_TYPES[keyType] then
			return keyType, {}
		end
		const badType, subPath = find(entry, seen)
		if badType then
			table.insert(subPath :: { any }, 1, key)
			return badType, subPath
		end
	end
	return nil, nil
end

--[[
	Deep check: recursively scans `value`, returning the offending `typeof` name and
	the key-path to it (outermost first) at the first non-serializable node found, or
	`nil` when the whole graph is clean. Cycle-aware. Only worth running when the
	extra traversal is acceptable (see `ServerReplicator.StrictValueChecks`).
]]
const function findNonReplicable(value: any): (string?, { any }?)
	return find(value, {})
end
ValueGuard.FindNonReplicable = findNonReplicable

return ValueGuard
