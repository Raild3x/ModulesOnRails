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
export type ValueAtPath<T, S> = any --ValueAtPathFn<T, S> -- This is temporarily commented out bc luau has an internal bug preventing proper parsing

-- Resolves to the *key* type of the indexer of the container found at path `S` in
-- `T` (e.g. `string` for `{ [string]: Item }`, `number` for `{ Item }`). `never` if
-- the container has no indexer (e.g. a record with only named fields).
export type function KeyAtPathFn(T: type, S: type): type
	local container = ValueAtPathFn(T, S)
	if not container:is("table") then
		return types.never
	end
	local indexer = container:indexer()
	if indexer == nil then
		return types.never
	end
	return indexer.index
end
export type KeyAtPath<T, S> = any --KeyAtPathFn<T, S>

-- Resolves to the *element* type of the indexer of the container found at path `S`
-- in `T` (e.g. `Item` for `{ [string]: Item }` or `{ Item }`). `never` if the
-- container has no indexer.
export type function ElementAtPathFn(T: type, S: type): type
	local container = ValueAtPathFn(T, S)
	if not container:is("table") then
		return types.never
	end
	local indexer = container:indexer()
	if indexer == nil then
		return types.never
	end
	return indexer.value
end
export type ElementAtPath<T, S> = any --ElementAtPathFn<T, S>

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local PathHelpers = {}

-- Reserved path segment that matches any literal key at its position (e.g.
-- {"Players", "*", "Health"}). Shared by the listener registry (wildcard
-- listeners) and the wildcard-aware accessors (Set/Update/Increment/
-- GetMatching), so the whole API speaks one path grammar.
PathHelpers.WILDCARD = "*"

--[=[
	@within PathHelpers
	@interface WildcardExpansion
	.Path { any } -- The fully concrete path (every "*" replaced by a matched key).
	.Value any -- The value currently at `Path` (nil when the final segment does not exist yet).
	.WildcardMatches { any }? -- Keys matched by each "*" segment, left-to-right. nil when the path had no wildcard.
]=]
export type WildcardExpansion = {
	Path: PathArray,
	Value: any,
	WildcardMatches: { any }?,
}

-- Memoizes `string.split(s, ".")` results: callers pass the same handful of
-- string-literal paths over and over (every Get/Set call site), so caching
-- the frozen array avoids re-splitting + re-allocating on every call. Safe to
-- share one instance across callers because the result is frozen and every
-- mutation site (`Append`, `GetPathParentAndKey`, etc.) clones before
-- mutating rather than touching a caller-supplied path array in place.
const StringPathCache: { [string]: PathArray<any> } = {}

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
	const cached = StringPathCache[pathString :: any]
	if cached ~= nil then
		return cached :: PathArray<S>
	end
	const parsed = table.freeze(string.split(pathString :: any, "."))
	StringPathCache[pathString :: any] = parsed
	return parsed :: PathArray<S>
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

	Asserts if `path` is empty (has no last key).

	@param path The path array
	@return The parent path array and the last key
]=]
function PathHelpers.GetPathParentAndKey(path: PathArray): (PathArray, any)
	local parentPath = table.clone(path)
	local key = table.remove(parentPath)
	assert(key ~= nil, "Path requires at least one segment")
	return parentPath, key
end

--[=[
	Returns a fresh path equal to `path` with `key` appended. The input path is
	not mutated; the returned table is safe to mutate further.

	@param path The base path array
	@param key The segment to append
	@return A new path array `{...path, key}`
]=]
function PathHelpers.Append(path: PathArray, key: any): PathArray
	local result = table.clone(path)
	table.insert(result, key)
	return result
end

--[=[
	Walks `root` along `path`, returning the value found there, or `nil` if any
	intermediate segment is not a table.

	@param root The table to walk from
	@param path The path to walk
	@return The value at `path`, or nil if `path` does not resolve
]=]
function PathHelpers.ResolveAtPath(root: any, path: PathArray): any
	local current: any = root
	for _, key in path do
		if type(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

--[=[
	Returns the index of the first `"*"` (wildcard) segment in `path`, or nil if
	the path contains none. A zero-allocation scan, cheap enough to run on every
	Set/Update/Increment call.

	@param path The path array to scan
	@return The 1-based index of the first wildcard segment, or nil
]=]
function PathHelpers.FindFirstWildcard(path: PathArray): number?
	for i = 1, #path do
		if path[i] == PathHelpers.WILDCARD then
			return i
		end
	end
	return nil
end

--[=[
	Returns true if `path` contains at least one `"*"` (wildcard) segment.

	@param path The path array to scan
	@return true if any segment is the wildcard
]=]
function PathHelpers.HasWildcard(path: PathArray): boolean
	return PathHelpers.FindFirstWildcard(path) ~= nil
end

-- Recursive body of `ExpandWildcards`. `node` is the value reached so far,
-- `concretePath` the fully-literal path taken to reach it, `matches` the keys
-- consumed by each "*" so far. Collects into `results` (collect-then-return:
-- callers see a complete snapshot before mutating anything).
const function expandWildcardsInto(
	node: any,
	path: PathArray,
	index: number,
	pathLen: number,
	concretePath: PathArray,
	matches: { any },
	includeMissingFinal: boolean,
	results: { WildcardExpansion }
)
	if index > pathLen then
		table.insert(results, {
			Path = concretePath,
			Value = node,
			WildcardMatches = if #matches > 0 then matches else nil,
		})
		return
	end

	-- A branch whose remaining segments cannot resolve is silently skipped
	-- (wildcard segments match what exists) — mirrors how wildcard listeners
	-- only fire for paths that exist.
	if type(node) ~= "table" then
		return
	end

	const segment = path[index]
	if segment == PathHelpers.WILDCARD then
		for key, child in node do
			expandWildcardsInto(
				child,
				path,
				index + 1,
				pathLen,
				PathHelpers.Append(concretePath, key),
				PathHelpers.Append(matches, key),
				includeMissingFinal,
				results
			)
		end
	else
		const child = node[segment]
		-- A missing literal FINAL segment is only kept when the caller is a
		-- writer (`includeMissingFinal`): Set("Players.*.Health", v) writes
		-- Health onto every player, creating the key where absent — while a
		-- reader only reports values that exist.
		if child == nil and not (includeMissingFinal and index == pathLen) then
			return
		end
		expandWildcardsInto(
			child,
			path,
			index + 1,
			pathLen,
			PathHelpers.Append(concretePath, segment),
			matches,
			includeMissingFinal,
			results
		)
	end
end

--[=[
	Expands the wildcard segments of `path` against live data, returning one
	[WildcardExpansion] per concrete path matched. At each `"*"` segment every
	key present at that level is enumerated; multiple wildcards compose as the
	product of their branch factors. Results are fully collected before
	returning, so callers may mutate the tree afterwards without invalidating
	the expansion.

	Segments `1 .. startIndex - 1` are assumed literal and already validated by
	the caller (they seed the concrete path unchanged); expansion begins at
	`startIndex` from `node`, the value reached by that literal prefix.

	@param node The value at `path[1 .. startIndex - 1]` to expand from
	@param path The full path array (may contain "*" segments at or after `startIndex`)
	@param startIndex The segment index to begin expansion at (1 to expand the whole path)
	@param includeMissingFinal When true, a missing literal final segment still yields an entry (Value = nil) — for writers that create the key.
	@return The matched expansions (empty when nothing matches)
]=]
function PathHelpers.ExpandWildcards(
	node: any,
	path: PathArray,
	startIndex: number,
	includeMissingFinal: boolean?
): { WildcardExpansion }
	const prefixLen = startIndex - 1
	const concretePrefix = table.move(path, 1, prefixLen, 1, table.create(prefixLen))
	const results: { WildcardExpansion } = {}
	expandWildcardsInto(node, path, startIndex, #path, concretePrefix, {}, includeMissingFinal == true, results)
	return results
end

--[=[
	Classifies table shape in one pass: a table is a dense array iff every key
	is a positive integer and the set of keys is exactly `{1, .., maxIndex}`
	(so `{}` is a length-0 array).

	@param t The table to classify
	@return isArray, and (when true) its length
]=]
function PathHelpers.ClassifyArray(t: { [any]: any }): (boolean, number)
	if type(t) ~= "table" then
		return false, 0
	end

	local count = 0
	local maxIndex = 0

	for key, _ in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false, 0
		end
		count += 1
		maxIndex = math.max(maxIndex, key)
	end

	if count == maxIndex then
		return true, maxIndex
	end

	return false, 0
end

return PathHelpers
