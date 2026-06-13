--!strict
--[=[
	@ignore
	@class PathHelpers

	Utility functions for working with paths in nested table structures.
	These functions handle path parsing, comparison, and string conversion for the
	TableManager system.

	All functions are pure and stateless.
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
