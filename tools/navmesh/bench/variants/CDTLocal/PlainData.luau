--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class PlainData

	Checks that a value is **plain data** that survives RemoteEvent / Actor transfer intact.
	This is the authority for "network-safe state" (Triangulation, NavMeshData): specs assert
	every built state passes it.

	Accepted: `nil` (top level only), booleans, finite-or-infinite numbers (not NaN), strings,
	buffers, native `vector` values (Roblox `Vector3`), and tables that are either a dense 1..n array or a dictionary with only string
	keys. Rejected: functions, threads, userdata, metatables, mixed or sparse tables,
	non-string dictionary keys, and cycles.
]=]

local PlainData = {}

local function check(value: unknown, path: string, visiting: { [any]: boolean }): (boolean, string?)
	local kind = type(value)
	if kind == "boolean" or kind == "string" then
		return true, nil
	elseif kind == "number" then
		if value ~= value then
			return false, `{path}: NaN`
		end
		return true, nil
	elseif kind == "buffer" or kind == "vector" then
		-- `vector` is Roblox's Vector3 and Lune's vector.create value: a plain value type.
		return true, nil
	elseif kind ~= "table" then
		return false, `{path}: {kind} is not plain data`
	end

	local tbl = value :: { [any]: any }
	if getmetatable(tbl) ~= nil then
		return false, `{path}: has a metatable`
	end
	if visiting[tbl] then
		return false, `{path}: cycle`
	end
	visiting[tbl] = true

	local count, maxIndex = 0, 0
	local hasString, hasNumber = false, false
	for key, child in tbl do
		count += 1
		if type(key) == "string" then
			hasString = true
		elseif type(key) == "number" and key % 1 == 0 and key >= 1 then
			hasNumber = true
			maxIndex = math.max(maxIndex, key)
		else
			visiting[tbl] = nil
			return false, `{path}: key {tostring(key)} ({type(key)}) is not a string or array index`
		end
		local ok, err = check(child, `{path}.{tostring(key)}`, visiting)
		if not ok then
			visiting[tbl] = nil
			return false, err
		end
	end
	visiting[tbl] = nil

	if hasString and hasNumber then
		return false, `{path}: mixes array indices and string keys`
	elseif hasNumber and maxIndex ~= count then
		return false, `{path}: sparse array ({count} entries, max index {maxIndex})`
	end
	return true, nil
end

--[=[
	@within PlainData
	Returns `true` when `value` is network-safe plain data, otherwise `false` and the path of
	the first offending value.
]=]
function PlainData.Check(value: unknown): (boolean, string?)
	return check(value, "root", {})
end

return PlainData
