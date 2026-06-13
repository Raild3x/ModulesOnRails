-- ─── Types ───────────────────────────────────────────────────────────────────

export type Path = { string | number | boolean }

export type DiffType = "changed" | "added" | "removed" | "descendantChanged"

export type DiffEntry = {
	path: Path,
	type: DiffType,
	old: any,
	new: any,
}

export type DiffTree = { [any]: DiffNode }

-- Sentinel key used inside a DiffTree to carry the scalar side of a
-- table<->scalar transition (e.g. the old scalar when a key becomes a table).
-- A unique userdata is used rather than "" so a genuine empty-string user key
-- cannot collide with it. `flatten`/`ChangeDetector` skip this key when building
-- paths. Exported so ChangeDetector can recognise it.
local SCALAR_SENTINEL = newproxy(false)

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
		const childSnap = snapshot(v)
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
			children[SCALAR_SENTINEL] = { type = "added", old = nil, new = v2, children = nil }
			tree[k] = make_descendant_node(v1, v2, children)
		elseif not is_v1_table and is_v2_table then
			-- scalar/nil -> table. Carry the whole new table on the node (`new`) so
			-- the value is authoritative regardless of child traversal order, and
			-- attach the new table's keys as children for granular listeners. No
			-- scalar sentinel is needed here (the node itself records old/new).
			local children: DiffTree = {}
			local addition = make_addition_tree(v2)
			if addition.children then
				for ck, cv in pairs(addition.children) do
					children[ck] = cv
				end
			end
			local has_children = next(children) ~= nil
			tree[k] = {
				type = if v1 == nil then "added" else "changed",
				old = v1,
				new = v2,
				children = if has_children then children else nil,
			}
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
			-- Wrap in a root node with descendantChanged type
			return make_descendant_node(v1, v2, children)
		end
		return nil -- No changes
	elseif is_v1_table and not is_v2_table then
		if v2 == nil then
			-- The whole table was removed (table -> nil). Emit a "removed" root so
			-- consumers receive a removal event at THIS path, not only at the leaf
			-- descendants. Otherwise a consumer that applies leaf removals would be
			-- left with an empty table here instead of removing it entirely.
			return make_removal_tree(v1)
		end
		local tree: DiffTree = {}
		local removal = make_removal_tree(v1)
		if removal.children then
			for k, v in pairs(removal.children) do
				tree[k] = v
			end
		end
		tree[SCALAR_SENTINEL] = { type = "added", old = nil, new = v2, children = nil }
		return make_descendant_node(v1, v2, tree)
	elseif not is_v1_table and is_v2_table then
		local children: DiffTree = {}
		local addition = make_addition_tree(v2)
		if addition.children then
			for k, v in pairs(addition.children) do
				children[k] = v
			end
		end
		local has_children = next(children) ~= nil

		if v1 == nil then
			-- nil -> table: a pure addition. Keep the existing descendantChanged
			-- shape for non-empty tables (their leaf adds drive consumers). But an
			-- EMPTY table has no leaves, and a childless descendantChanged node fires
			-- no signal, so the key would never reach a consumer — emit an "added"
			-- leaf node instead (defect: empty-table assignment was silent).
			if has_children then
				return make_descendant_node(v1, v2, children)
			end
			return { type = "added", old = nil, new = v2, children = nil }
		end

		-- scalar -> table: a direct change. Carry the whole new table on the node
		-- (`new`) so the value is order-independent, with the table's keys as
		-- children for granular listeners. No "" sentinel is used, so a genuine ""
		-- key is not folded into the parent path.
		return { type = "changed", old = v1, new = v2, children = if has_children then children else nil }
	else
		-- Scalar to scalar comparison
		if v1 == nil and v2 ~= nil then
			return { type = "added", old = nil, new = v2, children = nil }
		elseif v1 ~= nil and v2 == nil then
			return { type = "removed", old = v1, new = nil, children = nil }
		elseif v1 ~= v2 then
			return { type = "changed", old = v1, new = v2, children = nil }
		end
	end

	return nil -- No changes
end

-- ─── Flatten ─────────────────────────────────────────────────────────────────

local function flatten_node(node: DiffNode, path: Path, result: { DiffEntry })
	-- Add this node if it's not descendantChanged
	if node.type ~= "descendantChanged" then
		table.insert(result, {
			path = path,
			type = node.type,
			old = node.old,
			new = node.new,
		})
	end

	-- Recurse into children
	if node.children then
		for k, child in pairs(node.children) do
			local child_path: Path = table.clone(path)
			if k ~= SCALAR_SENTINEL then
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

local function validate_snapshot_node(node: any, breadcrumb: string)
	if type(node) ~= "table" then
		error(`Invalid snapshot object for Diff.diffFromSnapshot: expected table at {breadcrumb}.`)
	end

	if node.children ~= nil and type(node.children) ~= "table" then
		error(`Invalid snapshot object for Diff.diffFromSnapshot: children must be a table at {breadcrumb}.`)
	end

	local is_table_value = type(node.value) == "table"
	if is_table_value and type(node.ref) ~= "table" then
		error(`Invalid snapshot object for Diff.diffFromSnapshot: table values require table refs at {breadcrumb}.`)
	end

	if is_table_value and node.children == nil then
		error(`Invalid snapshot object for Diff.diffFromSnapshot: table values require children at {breadcrumb}.`)
	end

	if not is_table_value and node.children ~= nil then
		error(`Invalid snapshot object for Diff.diffFromSnapshot: scalar values cannot have children at {breadcrumb}.`)
	end

	if node.children then
		for key, child in pairs(node.children) do
			validate_snapshot_node(child, `{breadcrumb}.{tostring(key)}`)
		end
	end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local function diff_from_snapshot(before: Snapshot, after_value: any, safe_mode: boolean?): DiffNode?
	if safe_mode then
		validate_snapshot_node(before, "<root>")
	end
	local after = snapshot(after_value)
	return diff(before.value, after.value, before, after)
end

--------------------------------------------------------------------------------
--// Final Return //--
--------------------------------------------------------------------------------

local Module = {}

Module.diff = diff
Module.flatten = flatten
Module.snapshot = snapshot
Module.diffFromSnapshot = diff_from_snapshot
-- The sentinel DiffTree key for the scalar side of a table<->scalar transition.
Module.ScalarSentinel = SCALAR_SENTINEL

return Module
