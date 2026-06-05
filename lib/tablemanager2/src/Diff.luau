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
			-- Wrap in a root node with descendantChanged type
			return make_descendant_node(v1, v2, children)
		end
		return nil -- No changes
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

local function capture(value: any): (any, boolean?) -> DiffNode?
	local before = snapshot(value)
	return function(after_value: any, safe_mode: boolean?): DiffNode?
		return diff_from_snapshot(before, after_value, safe_mode)
	end
end

-- ─── Test Helpers ────────────────────────────────────────────────────────────

local function get_node(root: DiffNode?, path: Path): DiffNode?
	if not root then
		return nil
	end

	if #path == 0 then
		return root
	end

	local node = root
	for i = 1, #path do
		if node == nil then
			return nil
		end
		local children = node.children
		if children == nil then
			return nil
		end
		node = children[path[i]]
	end

	return node
end

local function assert_node(root: DiffNode?, path: Path, expected: DiffNode, label: string)
	local node = get_node(root, path)

	if node == nil then
		print(("  FAIL: %s — node not found at path [%s]"):format(label, table.concat(path :: { string }, ", ")))
		return
	end

	local type_ok = node.type == expected.type
	local old_ok = node.old == expected.old
	local new_ok = node.new == expected.new

	if type_ok and old_ok and new_ok then
		print(`  PASS: {label}`)
	else
		warn(`  FAIL: {label}`)
		if not type_ok then
			warn(`    type: expected "{expected.type}", got "{node.type}"`)
		end
		if not old_ok then
			warn(`    old:  expected {tostring(expected.old)}, got {tostring(node.old)}`)
		end
		if not new_ok then
			warn(`    new:  expected {tostring(expected.new)}, got {tostring(node.new)}`)
		end
	end
end

-- Only checks type — use for descendantChanged nodes where old/new are tables
-- that can't be compared by reference in test literals
local function assert_node_type(root: DiffNode?, path: Path, expected_type: DiffType, label: string)
	local node = get_node(root, path)
	if node == nil then
		print(("  FAIL: %s — node not found at path [%s]"):format(label, table.concat(path :: { string }, ", ")))
		return
	end
	if node.type == expected_type then
		print(`  PASS: {label}`)
	else
		warn(`  FAIL: {label} — expected type "{expected_type}", got "{node.type}"`)
	end
end

local function assert_no_node(root: DiffNode?, path: Path, label: string)
	local node = get_node(root, path)
	if node == nil or (node :: any).type == nil then
		warn(`  PASS: {label}`)
	else
		warn(`  FAIL: {label} — unexpected node found with type "{node.type}"`)
	end
end

local function assert_empty(root: DiffNode?, label: string)
	if root == nil then
		print(`  PASS: {label}`)
	else
		warn(`  FAIL: {label} — expected nil/empty root, got node with type "{root.type}"`)
	end
end

local function assert_flat_contains(entries: { DiffEntry }, expected: DiffEntry, label: string)
	for _, entry in ipairs(entries) do
		if entry.type == expected.type and entry.old == expected.old and entry.new == expected.new then
			local path_match = #entry.path == #expected.path
			if path_match then
				for i, seg in ipairs(expected.path) do
					if entry.path[i] ~= seg then
						path_match = false
						break
					end
				end
			end
			if path_match then
				print(`  PASS: {label}`)
				return
			end
		end
	end
	local pathStr = table.concat(expected.path :: { string }, ", ")
	warn(`  FAIL: {label} — entry not found`)
	warn(
		`    Expected: type={expected.type}, path=[{pathStr}], old={tostring(expected.old)}, new={tostring(expected.new)}`
	)
	warn(`    Got {#entries} entries:`)
	for _, e in ipairs(entries) do
		local ps = {}
		for _, seg in ipairs(e.path) do
			table.insert(ps, tostring(seg))
		end
		warn(`      type={e.type}, path=[{table.concat(ps, ", ")}], old={tostring(e.old)}, new={tostring(e.new)}`)
	end
end

local function assert_flat_count(entries: { DiffEntry }, expected_count: number, label: string)
	if #entries == expected_count then
		print(`  PASS: {label}`)
	else
		print(`  FAIL: {label} — expected {expected_count} entries, got {#entries}`)
	end
end

-- ─── Tree Structure Tests ────────────────────────────────────────────────────

local function run_tests()
	print("1. Scalar changed — tree has changed node")
	do
		local tree = diff({ x = 1 }, { x = 2 })
		assert_node(tree, { "x" }, { type = "changed", old = 1, new = 2 }, "x is changed")
	end

	print("2. Scalar added — tree has added node")
	do
		local tree = diff({}, { y = 42 })
		assert_node(tree, { "y" }, { type = "added", old = nil, new = 42 }, "y is added")
	end

	print("3. Scalar removed — tree has removed node")
	do
		local tree = diff({ y = 42 }, {})
		assert_node(tree, { "y" }, { type = "removed", old = 42, new = nil }, "y is removed")
	end

	print("4. No changes — tree is empty")
	do
		local tree = diff({ a = 1, b = "hello" }, { a = 1, b = "hello" })
		assert_empty(tree, "empty tree")
	end

	print("5. Nested scalar changed — ancestor is descendantChanged")
	do
		local tree = diff({ a = { b = { c = "old" } } }, { a = { b = { c = "new" } } })
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged")
		assert_node_type(tree, { "a", "b" }, "descendantChanged", "a.b is descendantChanged")
		assert_node(tree, { "a", "b", "c" }, { type = "changed", old = "old", new = "new" }, "a.b.c is changed")
	end

	print("6. Nested scalar added — ancestors are descendantChanged")
	do
		local tree = diff({ a = { b = {} } }, { a = { b = { c = 99 } } })
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged")
		assert_node_type(tree, { "a", "b" }, "descendantChanged", "a.b is descendantChanged")
		assert_node(tree, { "a", "b", "c" }, { type = "added", old = nil, new = 99 }, "a.b.c is added")
	end

	print("7. Nested scalar removed — ancestors are descendantChanged")
	do
		local tree = diff({ a = { b = { c = 99 } } }, { a = { b = {} } })
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged")
		assert_node_type(tree, { "a", "b" }, "descendantChanged", "a.b is descendantChanged")
		assert_node(tree, { "a", "b", "c" }, { type = "removed", old = 99, new = nil }, "a.b.c is removed")
	end

	print("8. Table replaced by scalar — children removed, scalar added at sentinel")
	do
		local tree = diff({ config = { host = "localhost", port = 8080 } }, { config = "disabled" })
		assert_node_type(tree, { "config" }, "descendantChanged", "config is descendantChanged")
		assert_node(
			tree,
			{ "config", "host" },
			{ type = "removed", old = "localhost", new = nil },
			"config.host is removed"
		)
		assert_node(tree, { "config", "port" }, { type = "removed", old = 8080, new = nil }, "config.port is removed")
	end

	print("9. Scalar replaced by table — scalar removed at sentinel, children added")
	do
		local tree = diff({ config = "disabled" }, { config = { host = "localhost", port = 8080 } })
		assert_node_type(tree, { "config" }, "descendantChanged", "config is descendantChanged")
		assert_node(
			tree,
			{ "config", "host" },
			{ type = "added", old = nil, new = "localhost" },
			"config.host is added"
		)
		assert_node(tree, { "config", "port" }, { type = "added", old = nil, new = 8080 }, "config.port is added")
	end

	print("10. Integer keys")
	do
		local tree = diff({ [1] = "a", [2] = "b" }, { [1] = "a", [2] = "changed" })
		assert_node(tree, { 2 }, { type = "changed", old = "b", new = "changed" }, "[2] is changed")
		assert_no_node(tree, { 1 }, "[1] unchanged — no node")
	end

	print("11. Boolean keys")
	do
		local tree = diff({ [true] = "yes", [false] = "no" }, { [true] = "yes", [false] = "maybe" })
		assert_node(tree, { false }, { type = "changed", old = "no", new = "maybe" }, "[false] is changed")
		assert_no_node(tree, { true }, "[true] unchanged — no node")
	end

	print("12. Multiple simultaneous changes")
	do
		local tree = diff({ a = 1, b = 2, c = 3 }, { a = 1, b = 99, d = 4 })
		assert_node(tree, { "b" }, { type = "changed", old = 2, new = 99 }, "b is changed")
		assert_node(tree, { "c" }, { type = "removed", old = 3, new = nil }, "c is removed")
		assert_node(tree, { "d" }, { type = "added", old = nil, new = 4 }, "d is added")
		assert_no_node(tree, { "a" }, "a unchanged — no node")
	end

	print("13. Identical nested tables — empty tree")
	do
		local tree = diff({ a = { b = { c = 42 } } }, { a = { b = { c = 42 } } })
		assert_empty(tree, "empty tree")
	end

	print("14. Entire nested table added — all leaves are added nodes")
	do
		local tree = diff({}, { settings = { volume = 80, muted = false } })
		assert_node(tree, { "settings", "volume" }, { type = "added", old = nil, new = 80 }, "settings.volume is added")
		assert_node(
			tree,
			{ "settings", "muted" },
			{ type = "added", old = nil, new = false },
			"settings.muted is added"
		)
	end

	print("15. Entire nested table removed — all leaves are removed nodes")
	do
		local tree = diff({ settings = { volume = 80, muted = false } }, {})
		assert_node(
			tree,
			{ "settings", "volume" },
			{ type = "removed", old = 80, new = nil },
			"settings.volume is removed"
		)
		assert_node(
			tree,
			{ "settings", "muted" },
			{ type = "removed", old = false, new = nil },
			"settings.muted is removed"
		)
	end

	-- ─── Root-level scalar/nil tests ─────────────────────────────────────────────

	print("16. nil to scalar — sentinel added")
	do
		local tree = diff(nil, 42)
		assert_node(tree, {}, { type = "added", old = nil, new = 42 }, "root scalar added")
	end

	print("17. scalar to nil — sentinel removed")
	do
		local tree = diff(42, nil)
		assert_node(tree, {}, { type = "removed", old = 42, new = nil }, "root scalar removed")
	end

	print("18. nil to nil — empty tree")
	do
		local tree = diff(nil, nil)
		assert_empty(tree, "empty tree")
	end

	print("19. scalar to scalar, no change — empty tree")
	do
		local tree = diff(10, 10)
		assert_empty(tree, "empty tree")
	end

	print("20. scalar to scalar, changed — sentinel changed")
	do
		local tree = diff("hello", "world")
		assert_node(tree, {}, { type = "changed", old = "hello", new = "world" }, "root scalar changed")
	end

	print("21. table to scalar at root — leaves removed, scalar added")
	do
		local tree = diff({ Hello = "World", Foo = "Bar" }, 5)
		assert_node(tree, { "Hello" }, { type = "removed", old = "World", new = nil }, "Hello is removed")
		assert_node(tree, { "Foo" }, { type = "removed", old = "Bar", new = nil }, "Foo is removed")
		assert_node(tree, {}, { type = "added", old = nil, new = 5 }, "root scalar added")
	end

	print("22. scalar to table at root — scalar removed, leaves added")
	do
		local tree = diff(5, { Hello = "World", Foo = "Bar" })
		assert_node(tree, {}, { type = "removed", old = 5, new = nil }, "root scalar removed")
		assert_node(tree, { "Hello" }, { type = "added", old = nil, new = "World" }, "Hello is added")
		assert_node(tree, { "Foo" }, { type = "added", old = nil, new = "Bar" }, "Foo is added")
	end

	print("23. table to nil at root — leaves removed, no addition")
	do
		local tree = diff({ A = 1, B = 2 }, nil)
		assert_node(tree, { "A" }, { type = "removed", old = 1, new = nil }, "A is removed")
		assert_node(tree, { "B" }, { type = "removed", old = 2, new = nil }, "B is removed")
		assert_no_node(tree, {}, "no sentinel addition")
	end

	print("24. nil to table at root — leaves added, no removal")
	do
		local tree = diff(nil, { A = 1, B = 2 })
		assert_node(tree, { "A" }, { type = "added", old = nil, new = 1 }, "A is added")
		assert_node(tree, { "B" }, { type = "added", old = nil, new = 2 }, "B is added")
		assert_no_node(tree, {}, "no sentinel removal")
	end

	-- ─── Snapshot / capture tests ────────────────────────────────────────────────

	print("25. capture — no changes after no-op")
	do
		local t = { x = 1, y = 2 }
		local finish = capture(t)
		local tree = finish(t)
		assert_empty(tree, "empty tree after no-op")
	end

	print("26. capture — detects scalar change")
	do
		local t = { x = 1 }
		local finish = capture(t)
		t.x = 99
		local tree = finish(t)
		assert_node(tree, { "x" }, { type = "changed", old = 1, new = 99 }, "x is changed")
	end

	print("27. capture — detects added key")
	do
		local t = { x = 1 }
		local finish = capture(t)
		t.y = 42
		local tree = finish(t)
		assert_node(tree, { "y" }, { type = "added", old = nil, new = 42 }, "y is added")
	end

	print("28. capture — detects removed key")
	do
		local t = { x = 1, y = 2 }
		local finish = capture(t)
		t.y = nil
		local tree = finish(t)
		assert_node(tree, { "y" }, { type = "removed", old = 2, new = nil }, "y is removed")
	end

	print("29. capture — detects nested change")
	do
		local t = { a = { b = 10 } }
		local finish = capture(t)
		t.a.b = 99
		local tree = finish(t)
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged")
		assert_node(tree, { "a", "b" }, { type = "changed", old = 10, new = 99 }, "a.b is changed")
	end

	print("30. capture — reference swap with same contents is detected as changed")
	do
		local t = { a = { x = 1 } }
		local finish = capture(t)
		t.a = { x = 1 }
		local tree = finish(t)
		assert_node_type(tree, { "a" }, "changed", "a is changed despite same contents")
	end

	print("31. capture — reference swap with different contents shows descendantChanged")
	do
		local t = { a = { x = 1 } }
		local finish = capture(t)
		t.a = { x = 99 }
		local tree = finish(t)
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged")
		assert_node(tree, { "a", "x" }, { type = "changed", old = 1, new = 99 }, "a.x is changed")
	end

	print("32. capture — deeply nested reference swap with same contents")
	do
		local t = { a = { b = { z = 5 } } }
		local finish = capture(t)
		t.a.b = { z = 5 }
		local tree = finish(t)
		assert_node_type(tree, { "a" }, "descendantChanged", "a is descendantChanged due to child ref swap")
		assert_node_type(tree, { "a", "b" }, "changed", "a.b is changed despite same contents")
	end

	print("33. diff_from_snapshot — works equivalently to capture")
	do
		local t = { x = 1 }
		local before = snapshot(t)
		t.x = 50
		local tree = diff_from_snapshot(before, t)
		assert_node(tree, { "x" }, { type = "changed", old = 1, new = 50 }, "x is changed via diff_from_snapshot")
	end

	-- ─── Flatten tests ────────────────────────────────────────────────────────────

	print("34. flatten — descendantChanged nodes are excluded")
	do
		local tree = diff({ a = { b = 1 } }, { a = { b = 2 } })
		local entries = flatten(tree)
		assert_flat_count(entries, 1, "one flat entry")
		assert_flat_contains(
			entries,
			{ path = { "a", "b" }, type = "changed", old = 1, new = 2 },
			"a.b changed in flat list"
		)
	end

	print("35. flatten — all leaf types present")
	do
		local tree = diff({ a = 1, b = 2, c = 3 }, { a = 1, b = 99, d = 4 })
		local entries = flatten(tree)
		assert_flat_count(entries, 3, "three flat entries")
		assert_flat_contains(entries, { path = { "b" }, type = "changed", old = 2, new = 99 }, "b changed")
		assert_flat_contains(entries, { path = { "c" }, type = "removed", old = 3, new = nil }, "c removed")
		assert_flat_contains(entries, { path = { "d" }, type = "added", old = nil, new = 4 }, "d added")
	end

	print("36. flatten — deep nesting produces correct paths")
	do
		local tree = diff({ a = { b = { c = "old" } } }, { a = { b = { c = "new" } } })
		local entries = flatten(tree)
		assert_flat_count(entries, 1, "one flat entry")
		assert_flat_contains(
			entries,
			{ path = { "a", "b", "c" }, type = "changed", old = "old", new = "new" },
			"a.b.c in flat list"
		)
	end

	print("37. flatten — root scalar sentinel has empty path")
	do
		local tree = diff("hello", "world")
		local entries = flatten(tree)
		assert_flat_count(entries, 1, "one flat entry")
		assert_flat_contains(
			entries,
			{ path = {}, type = "changed", old = "hello", new = "world" },
			"root scalar in flat list"
		)
	end

	print("38. flatten — table-to-scalar produces leaf removals and scalar addition")
	do
		local tree = diff({ config = { host = "localhost", port = 8080 } }, { config = "disabled" })
		local entries = flatten(tree)
		assert_flat_count(entries, 3, "three flat entries")
		assert_flat_contains(
			entries,
			{ path = { "config", "host" }, type = "removed", old = "localhost", new = nil },
			"config.host removed"
		)
		assert_flat_contains(
			entries,
			{ path = { "config", "port" }, type = "removed", old = 8080, new = nil },
			"config.port removed"
		)
		assert_flat_contains(
			entries,
			{ path = { "config" }, type = "added", old = nil, new = "disabled" },
			"config scalar added"
		)
	end
end

--------------------------------------------------------------------------------
--// Final Return //--
--------------------------------------------------------------------------------

local Module = {}

Module.runTests = run_tests
Module.capture = capture
Module.diff = diff
Module.flatten = flatten
Module.snapshot = snapshot
Module.diffFromSnapshot = diff_from_snapshot

return Module
