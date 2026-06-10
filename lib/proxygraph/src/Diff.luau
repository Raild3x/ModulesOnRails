--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
-- Ported from tablemanager2/Diff.luau — functional core only.

-- ─── Types ───────────────────────────────────────────────────────────────────

export type Path = { string | number | boolean }
export type DiffType = "changed" | "added" | "removed" | "descendantChanged"

export type DiffEntry = {
	path: Path,
	type: DiffType,
	old: any,
	new: any,
}

export type DiffTree = { [string | number | boolean]: DiffNode }

export type DiffNode = {
	type: DiffType,
	old: any,
	new: any,
	children: DiffTree?,
}

export type Snapshot = {
	value: any,
	ref: any,
	children: { [any]: Snapshot }?,
}

-- ─── Snapshot ────────────────────────────────────────────────────────────────

local function snapshot(value: any): Snapshot
	if type(value) ~= "table" then
		return { value = value, ref = nil, children = nil }
	end

	local children = {}
	local copy = {}
	for k, v in value do
		local childSnap = snapshot(v)
		children[k] = childSnap
		copy[k] = childSnap.value
	end

	return { value = table.freeze(copy), ref = value, children = children }
end

-- ─── Internal helpers ────────────────────────────────────────────────────────

local function make_removal_tree(value: any): DiffNode
	if type(value) ~= "table" then
		return { type = "removed", old = value, new = nil, children = nil }
	end
	local children: DiffTree = {}
	for k, v in pairs(value) do
		children[k] = make_removal_tree(v)
	end
	return { type = "removed", old = value, new = nil, children = children }
end

local function make_addition_tree(value: any): DiffNode
	if type(value) ~= "table" then
		return { type = "added", old = nil, new = value, children = nil }
	end
	local children: DiffTree = {}
	for k, v in pairs(value) do
		children[k] = make_addition_tree(v)
	end
	return { type = "added", old = nil, new = value, children = children }
end

local function make_descendant_node(old: any, new: any, children: DiffTree): DiffNode
	return { type = "descendantChanged", old = old, new = new, children = children }
end

-- ─── Core diff ───────────────────────────────────────────────────────────────

local function diff_tables(t1: { [any]: any }, t2: { [any]: any }, snap1: Snapshot?, snap2: Snapshot?): DiffTree?
	local tree: DiffTree = {}
	local visited = {}

	for k, v1 in pairs(t1) do
		visited[k] = true
		local v2 = t2[k]

		local child_snap1 = if snap1 and snap1.children then snap1.children[k] else nil
		local child_snap2 = if snap2 and snap2.children then snap2.children[k] else nil

		local ref1 = if child_snap1 then child_snap1.ref else nil
		local ref2 = if child_snap2 then child_snap2.ref else nil

		local is_v1_table = type(v1) == "table"
		local is_v2_table = type(v2) == "table"

		if v2 == nil then
			tree[k] = make_removal_tree(v1)
		elseif is_v1_table and is_v2_table then
			local ref_changed = ref1 ~= nil and ref2 ~= nil and ref1 ~= ref2
			local child_tree = diff_tables(v1, v2, child_snap1, child_snap2)

			if ref_changed and child_tree == nil then
				tree[k] = { type = "changed", old = v1, new = v2, children = nil }
			elseif child_tree ~= nil then
				tree[k] = make_descendant_node(v1, v2, child_tree)
			end
		elseif is_v1_table and not is_v2_table then
			local children: DiffTree = {}
			local removal = make_removal_tree(v1)
			if removal.children then
				for ck, cv in pairs(removal.children) do
					children[ck] = cv
				end
			end
			children[""] = { type = "added", old = nil, new = v2, children = nil }
			tree[k] = make_descendant_node(v1, v2, children)
		elseif not is_v1_table and is_v2_table then
			local children: DiffTree = {}
			children[""] = { type = "removed", old = v1, new = nil, children = nil }
			local addition = make_addition_tree(v2)
			if addition.children then
				for ck, cv in pairs(addition.children) do
					children[ck] = cv
				end
			end
			tree[k] = make_descendant_node(v1, v2, children)
		elseif v1 ~= v2 then
			tree[k] = { type = "changed", old = v1, new = v2, children = nil }
		end
	end

	for k, v2 in pairs(t2) do
		if not visited[k] then
			tree[k] = make_addition_tree(v2)
		end
	end

	return if next(tree) ~= nil then tree else nil
end

local function diff(v1: any, v2: any, snap1: Snapshot?, snap2: Snapshot?): DiffNode?
	local is_v1_table = type(v1) == "table"
	local is_v2_table = type(v2) == "table"

	if is_v1_table and is_v2_table then
		local children = diff_tables(v1, v2, snap1, snap2)
		if children then
			return make_descendant_node(v1, v2, children)
		end
		return nil
	elseif is_v1_table and not is_v2_table then
		local tree: DiffTree = {}
		local removal = make_removal_tree(v1)
		if removal.children then
			for k, v in pairs(removal.children) do
				tree[k] = v
			end
		end
		if v2 ~= nil then
			tree[""] = { type = "added", old = nil, new = v2, children = nil }
		end
		return make_descendant_node(v1, v2, tree)
	elseif not is_v1_table and is_v2_table then
		local tree: DiffTree = {}
		if v1 ~= nil then
			tree[""] = { type = "removed", old = v1, new = nil, children = nil }
		end
		local addition = make_addition_tree(v2)
		if addition.children then
			for k, v in pairs(addition.children) do
				tree[k] = v
			end
		end
		return make_descendant_node(v1, v2, tree)
	else
		if v1 == nil and v2 ~= nil then
			return { type = "added", old = nil, new = v2, children = nil }
		elseif v1 ~= nil and v2 == nil then
			return { type = "removed", old = v1, new = nil, children = nil }
		elseif v1 ~= v2 then
			return { type = "changed", old = v1, new = v2, children = nil }
		end
	end

	return nil
end

-- ─── Flatten ─────────────────────────────────────────────────────────────────

local function flatten_node(node: DiffNode, path: Path, result: { DiffEntry })
	if node.type ~= "descendantChanged" then
		table.insert(result, { path = path, type = node.type, old = node.old, new = node.new })
	end
	if node.children then
		for k, child in pairs(node.children) do
			local child_path: Path = table.clone(path)
			if k ~= "" then
				table.insert(child_path, k)
			end
			flatten_node(child, child_path, result)
		end
	end
end

local function flatten(root: DiffNode?, path: Path?): { DiffEntry }
	local finalPath: Path = path or {}
	local result: { DiffEntry } = {}
	if root then
		flatten_node(root, finalPath, result)
	end
	return result
end

-- ─── Snapshot-aware diff ─────────────────────────────────────────────────────

local function diff_from_snapshot(before: Snapshot, after_value: any): DiffNode?
	local after = snapshot(after_value)
	return diff(before.value, after.value, before, after)
end

local function capture(value: any): (any) -> DiffNode?
	local before = snapshot(value)
	return function(after_value: any): DiffNode?
		return diff_from_snapshot(before, after_value)
	end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local Diff = {}
Diff.diff = diff
Diff.flatten = flatten
Diff.snapshot = snapshot
Diff.capture = capture
Diff.diffFromSnapshot = diff_from_snapshot

return Diff
