--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class IgnoreTrie

	A per-manager prefix trie of paths whose writes should skip the
	diff/snapshot/event machinery entirely (`TableManagerConfig.IgnoredPaths`,
	`TableManager:SetPathIgnored`). Marking is purely structural — literal
	path segments, no wildcards — so prefix queries are O(depth).

	A leaf module (only depends on `PathHelpers`) so both `Mutator` (the
	write-side pre-prune) and `ChangeDetector` (the diff-tree descendant
	prune) can require it without creating a cycle through `Emitter`.
]=]

local PathHelpers = require("./PathHelpers")

const IGNORED_KEY = newproxy()
export type Node = { [any]: Node }

local IgnoreTrie = {}

function IgnoreTrie.new(): Node
	return {} :: any
end

function IgnoreTrie.SetPathIgnored<S>(root: Node, path: PathHelpers.Path<S>, ignored: boolean)
	local parsedPath = PathHelpers.ParsePath(path)
	local node = root
	for _, segment in parsedPath do
		local child = node[segment]
		if child == nil then
			child = {}
			node[segment] = child :: any
		end
		node = child
	end
	node[IGNORED_KEY] = if ignored then true else nil
end

-- `path` must already be a parsed PathArray (no string-path parsing here —
-- both call sites are on hot paths and already hold one).
function IgnoreTrie.IsPathIgnored(root: Node?, path: { any }): boolean
	if root == nil then
		return false
	end
	local node: Node? = root
	if node and node[IGNORED_KEY] then
		return true
	end
	for _, segment in path do
		if node == nil then
			return false
		end
		node = node[segment]
		if node and node[IGNORED_KEY] then
			return true
		end
	end
	return false
end

return IgnoreTrie
