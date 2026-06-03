--!strict
--[=[
	@class PathHelpers
	
	Utility functions for working with listener paths in nested table structures.
	These functions handle path navigation, matching, and cleanup for the TableManager system.
	
	All functions are pure and stateless - they work on any nested table structure
	that follows the __callbacks convention.
]=]

--// Types //--

--[=[
    Defines a path to a value in the nested table structure.
    Paths are represented as arrays of keys, where each key can be any Lua type (string, number, boolean, etc.).
    
    For example, the path to access `Data.player.level` would be represented as `{"player", "level"}`.
    
    Note: Using `any` here is intentional and necessary since Lua tables support any type as a key.
]=]
export type Path = { any }

export type DataChangeSource = "self" | "child" | "parent"

--[=[
	A listener callback function that receives change notifications.
	
	Note: Using `any` for parameters is intentional since callbacks receive different
	argument types depending on the event type (ValueChanged, KeyAdded, etc.).
]=]
export type ListenerCallback = (...any) -> ()

--[=[
	Internal structure for storing listeners at a specific path.
	Contains an array of callbacks under the special `__callbacks` key.
]=]
export type ListenerTable = {
	__callbacks: { ListenerCallback }?,
	[any]: ListenerTable?,
}

--[=[
	Root storage structure for all listeners of a specific event type.
]=]
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
function PathHelpers.ParsePath(pathString: string | Path): Path
	if typeof(pathString) == "table" then
		return pathString :: Path
	end
	return table.freeze(string.split(pathString, "."))
end

--[=[
	Checks if a listener path matches or is a parent of a change path.
	
	@param listenerPath The path where a listener is registered
	@param changePath The path where a change occurred
	@return "self" if paths match exactly, "child" if changePath is deeper, "parent" if changePath is shallower, nil if no match
]=]
function PathHelpers.GetPathRelation(listenerPath: Path, changePath: Path): DataChangeSource?
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
	path: Path,
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
function PathHelpers.CleanupEmptyListenerTables(listenerRoot: ListenerRoot, path: Path)
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
	changePath: Path,
	callback: (
		listenerPath: Path,
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
	local function checkChildPaths(currentTable: ListenerRoot | ListenerTable, currentPath: Path)
		-- Check each key in the current table (except __callbacks)
		for key, value in pairs(currentTable) do
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

return PathHelpers
