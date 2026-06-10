--!strict
--[=[
	@ignore
	@class PathHelpers
	
	Utility functions for working with listener paths in nested table structures.
	These functions handle path navigation, matching, and cleanup for the TableManager system.
	
	All functions are pure and stateless - they work on any nested table structure
	that follows the __callbacks convention.
]=]

--// Types //--

--[=[
	@within PathHelpers
	@type Path { any } | string
	Defines a path to a value in the nested table structure.
	Paths are represented as arrays of keys, where each key can be any Lua type (string, number, boolean, etc.).

	For example, the path to access `Data.player.level` would be represented as `{"player", "level"}`.

	Note: Using `any` here is intentional and necessary since Lua tables support any type as a key.
]=]
export type Path<S = string> = S | "" | { any }
export type PathArray<S = string> = { any }
export type function PathString(S: type)
	if S:is("table") then
		return types.intersectionof(types.singleton("[UNKNOWN_PATH]"), types.any)
	end
	return S
end

-- Expects a table type `T` and a path type `S`, and recursively resolves the type at that path.
export type function ValueAtPathFn(T: type, S: type): type
	if not T:is("table") then
		return types.never
	end

	-- Array/tuple path: {"Hello", "World"}. Luau doesnt support this yet so we have to fall back to 'any'
	if S:is("table") or S:is("string") then
		return types.any
	end

	if not S:is("singleton") then
		error("Path type must be a singleton string or a table of any keys. Defaulting to 'never'.")
		return types.never
	end

	-- String path: "Hello.World" (existing behavior)
	local str = S:value()
	if typeof(str) ~= "string" then
		error("Path type must be a singleton string or a table of any keys. Defaulting to 'never'.")
		return types.never
	end
	if str == "" then -- if the path is empty, return the original type
		return T
	end

	local dot = string.find(str, ".", 1, true)
	if dot == nil then
		local result = T:readproperty(types.singleton(str))
		if result == nil then
			error(`Path segment "{str}" does not exist in the table`)
			return types.never
		end
		return result
	else
		local head = string.sub(str, 1, dot - 1)
		local tail = string.sub(str, dot + 1)
		local inner = T:readproperty(types.singleton(head))
		if inner == nil then
			error(`Path segment "{head}" does not exist in the table`)
			return types.never
		end
		return ValueAtPathFn(inner, types.singleton(tail))
	end
end
export type ValueAtPath<T, S> = any --ValueAtPathFn(T, S)

export type DataChangeSource = "self" | "child" | "parent"

--[=[
	@within PathHelpers
	@type ListenerCallback (...any) -> ()

	A listener callback function that receives change notifications.
	
	Note: Using `any` for parameters is intentional since callbacks receive different
	argument types depending on the event type (ValueChanged, KeyAdded, etc.).
]=]
export type ListenerCallback = (...any) -> ()

--[[
	Internal structure for storing listeners at a specific path.
	Contains an array of callbacks under the special `__callbacks` key.
]]
export type ListenerTable = {
	__callbacks: { ListenerCallback }?,
	[any]: ListenerTable?,
}

--[[
	Root storage structure for all listeners of a specific event type.
]]
export type ListenerRoot = {
	[any]: ListenerTable,
}

local PathHelpers = {}

--[=[
	Parses a path string into a Path array.
	If the input is already a table, it returns it directly.
	
	@param pathString The path as a string (e.g., "player.level") or an array of keys
	@return The parsed Path array
]=]
function PathHelpers.ParsePath<S>(pathString: Path<S>): PathArray<S>
	if typeof(pathString) == "table" then
		return pathString :: PathArray<S>
	end
	return table.freeze(string.split(pathString, ".")) :: PathArray<S>
end

--[=[
	Checks if a listener path matches or is a parent of a change path.
	
	@param listenerPath The path where a listener is registered
	@param changePath The path where a change occurred
	@return "self" if paths match exactly, "child" if changePath is deeper, "parent" if changePath is shallower, nil if no match
]=]
function PathHelpers.GetPathRelation(listenerPath: PathArray, changePath: PathArray): DataChangeSource?
	-- Check if paths match exactly
	if #listenerPath == #changePath then
		for i = 1, #listenerPath do
			if listenerPath[i] ~= changePath[i] then
				return nil -- Paths don't match
			end
		end
		return "self" -- Exact match
	end

	-- Check if changePath is deeper (listener is parent of change)
	if #listenerPath < #changePath then
		-- Check if changePath starts with listenerPath
		for i = 1, #listenerPath do
			if listenerPath[i] ~= changePath[i] then
				return nil -- Paths don't match
			end
		end
		return "child" -- Change is in a child path
	end

	-- Check if changePath is shallower (listener is child of change)
	if #listenerPath > #changePath then
		-- Check if listenerPath starts with changePath
		for i = 1, #changePath do
			if listenerPath[i] ~= changePath[i] then
				return nil -- Paths don't match
			end
		end
		return "parent" -- Change is in a parent path
	end

	return nil
end

--[=[
	Navigates to or creates a nested listener structure for a path.
	
	The structure uses actual path values as keys (supporting all Lua types)
	and stores callbacks in a special `__callbacks` key at the final level.
	
	@param listenerRoot The root listener table (e.g., listeners.ValueChanged)
	@param path The path array to navigate/create
	@param createIfMissing If true, creates missing nested tables along the path
	@return The table at the end of the path, or nil if path doesn't exist and createIfMissing is false
]=]
function PathHelpers.GetListenerTableForPath(
	listenerRoot: ListenerRoot,
	path: PathArray,
	createIfMissing: boolean
): ListenerTable?
	local current: ListenerRoot | ListenerTable = listenerRoot

	for _, key in ipairs(path) do
		local next = current[key]
		if next == nil then
			if createIfMissing then
				local newTable: ListenerTable = {}
				current[key] = newTable
				current = newTable
			else
				return nil
			end
		else
			current = next :: ListenerTable
		end
	end

	-- The final level should have a special marker to distinguish it from path segments
	-- We use __callbacks as the key to store the actual callback array
	local currentTable = current :: ListenerTable
	if currentTable.__callbacks == nil and createIfMissing then
		currentTable.__callbacks = {}
	end

	return currentTable
end

--[=[
	Cleans up empty nested tables after removing a listener.
	
	Recursively removes empty parent tables if they have no callbacks or children.
	This prevents memory bloat from accumulating empty table structures.
	
	@param listenerRoot The root listener table
	@param path The path where a listener was removed
]=]
function PathHelpers.CleanupEmptyListenerTables(listenerRoot: ListenerRoot, path: PathArray)
	if #path == 0 then
		return
	end

	-- Navigate to the parent of the target
	local parents: { { table: ListenerTable | ListenerRoot, key: any } } = {}
	local current: ListenerTable | ListenerRoot = listenerRoot

	for _, key in ipairs(path) do
		table.insert(parents, { table = current, key = key })
		local next = current[key]
		if next == nil then
			return -- Path doesn't exist, nothing to clean
		end
		current = next :: ListenerTable
	end

	-- Check if the final table is empty (no callbacks and no nested paths)
	local function isEmpty(t: ListenerTable): boolean
		if t.__callbacks and #t.__callbacks > 0 then
			return false -- Has callbacks
		end

		for key, _ in pairs(t) do
			if key ~= "__callbacks" then
				return false -- Has nested paths
			end
		end

		return true
	end

	-- Walk backwards, removing empty tables
	for i = #parents, 1, -1 do
		local parent = parents[i].table
		local key = parents[i].key
		local child = parent[key]

		if child and isEmpty(child :: ListenerTable) then
			parent[key] = nil
		else
			break -- Stop if we find a non-empty table
		end
	end
end

--[=[
	Iterates over all listener paths that should be notified of a change at the given path.
	
	This includes:
	1. Exact match (relation: "self")
	2. Parent paths (relation: "child" - change happened in their child)
	3. Child paths (relation: "parent" - change happened in their parent)
	
	Calls the callback for each matching listener.
	
	@param listenerRoot The root listener table
	@param changePath The path where a change occurred
	@param callback Function called for each match: (listenerPath, callbacks, relation) -> ()
]=]
function PathHelpers.ForEachMatchingListener(
	listenerRoot: ListenerRoot,
	changePath: PathArray,
	callback: (
		listenerPath: PathArray,
		callbacks: { ListenerCallback },
		relation: DataChangeSource
	) -> ()
)
	-- Part 1: Check parent paths and self (prefixes of changePath)
	-- These listeners will receive relation "child" or "self"

	-- Start with empty path (root listener)
	local listenerTable = PathHelpers.GetListenerTableForPath(listenerRoot, {}, false)
	if listenerTable and listenerTable.__callbacks and #listenerTable.__callbacks > 0 then
		local relation = PathHelpers.GetPathRelation({}, changePath)
		if relation then
			callback({}, listenerTable.__callbacks, relation :: DataChangeSource)
		end
	end

	-- Check paths of depth 1 through #changePath (all parent paths + exact match)
	for depth = 1, #changePath do
		local listenerPath = {}
		for i = 1, depth do
			table.insert(listenerPath, changePath[i])
		end

		listenerTable = PathHelpers.GetListenerTableForPath(listenerRoot, listenerPath, false)
		if listenerTable and listenerTable.__callbacks and #listenerTable.__callbacks > 0 then
			local relation = PathHelpers.GetPathRelation(listenerPath, changePath)
			if relation then
				callback(listenerPath, listenerTable.__callbacks, relation :: DataChangeSource)
			end
		end
	end

	-- Part 2: Recursively check all child paths (extensions of changePath)
	-- These listeners will receive relation "parent"
	local function checkChildPaths(currentTable: ListenerRoot | ListenerTable, currentPath: PathArray)
		-- Check each key in the current table (except __callbacks)
		for key, value in currentTable do
			if key ~= "__callbacks" and type(value) == "table" then
				local childPath = table.clone(currentPath)
				table.insert(childPath, key)
				local childTable = value :: ListenerTable

				-- Check if this child path has callbacks
				if childTable.__callbacks and #childTable.__callbacks > 0 then
					local relation = PathHelpers.GetPathRelation(childPath, changePath)
					if relation then
						callback(childPath, childTable.__callbacks, relation :: DataChangeSource)
					end
				end

				-- Recursively check deeper child paths
				checkChildPaths(childTable, childPath)
			end
		end
	end

	-- Start recursive check from changePath
	local changeTable = PathHelpers.GetListenerTableForPath(listenerRoot, changePath, false)
	if changeTable then
		checkChildPaths(changeTable, changePath)
	end
end

function PathHelpers.ArePathsEqual(a: Path, b: Path): boolean
	if a == b then
		return true
	end

	local aArray: PathArray = PathHelpers.ParsePath(a)
	local bArray: PathArray = PathHelpers.ParsePath(b)
	if #aArray ~= #bArray then
		return false
	end

	for i = 1, #aArray do
		if aArray[i] ~= bArray[i] then
			return false
		end
	end

	return true
end

--[=[
	Converts a path array to a dot-separated string representation.
	Useful for debugging and error messages.

	@param path The path array to convert
	@return A string representation (e.g., "player.stats.health" or "<root>" for empty path)
]=]
function PathHelpers.PathToString(path: PathArray): string
	if #path == 0 then
		return "<root>"
	end
	local parts = table.create(#path)
	for i, segment in path do
		parts[i] = tostring(segment)
	end
	return table.concat(parts, ".")
end

--[=[
	Checks if one path is a prefix of another.

	@param prefix The potential prefix path
	@param fullPath The full path to check against
	@return true if prefix matches the start of fullPath
]=]
function PathHelpers.IsPrefixPath(prefix: PathArray, fullPath: PathArray): boolean
	if #prefix > #fullPath then
		return false
	end
	for i = 1, #prefix do
		if prefix[i] ~= fullPath[i] then
			return false
		end
	end
	return true
end

--[=[
	Extracts the parent path and the last key from a path.

	@param path The path array
	@return The parent path array and the last key
	@throws If path is empty (has no last key)
]=]
function PathHelpers.GetPathParentAndKey(path: PathArray): (PathArray, any)
	local parentPath = table.clone(path)
	local key = table.remove(parentPath)
	assert(key ~= nil, "Path requires at least one segment")
	return parentPath, key
end

return PathHelpers
