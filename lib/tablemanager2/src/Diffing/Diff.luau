local PathHelpers = require("../PathHelpers")

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
	-- Cached so diff_tables/diff can skip re-probing the registry: set by
	-- `snapshot()` when this node's ref is opaque (directly marked, or a
	-- direct child of an `OpaqueChildren`-marked parent).
	opaque: boolean?,
}

-- Oracle handed in by ChangeDetector (built from OpaqueRegistry); kept as a
-- structural type here (rather than requiring OpaqueRegistry) so Diff stays
-- standalone and every function's behavior is exactly unchanged when the
-- caller passes no ctx at all.
export type Ctx = {
	isOpaque: (ref: any) -> boolean,
	hasOpaqueChildren: (ref: any) -> boolean,
	-- Resolves a baseline content node to the live identity it mirrors (nil for
	-- anything that isn't such a node). Lets the opaque branch compare a
	-- content-node slot by the child's real identity rather than the copy.
	identityOf: ((node: any) -> any?)?,
}

-- An entry collected into an `arraySink` (see `diff`): a changed array-like node
-- excluded from the dict diff tree so the flush can re-diff it via LCS into
-- shift-faithful `Array*` events. `path` is relative to the diff root.
export type ArraySinkEntry = { path: Path, old: any, new: any }

-- True if `t` is a Lua sequence (array-like): empty, or keys are exactly the
-- contiguous integers 1..#t. Used only in array-aware diff mode (`arraySink`
-- present) to decide whether a both-tables node is an array to LCS-diff rather
-- than dict-diff positionally. See `PathHelpers.ClassifyArray`.
local function isSequence(t: { [any]: any }): boolean
	local isArray = PathHelpers.ClassifyArray(t)
	return isArray
end

-- ─── Opacity helpers ─────────────────────────────────────────────────────────

-- Resolves whether `v` should be treated as an opaque leaf for diffing.
-- Prefers the cached flag on `snap` (already resolved by `snapshot()`,
-- including any parent `hasOpaqueChildren` marking) when a snapshot is
-- available; only consults `ctx` directly when there is no snapshot to read
-- (e.g. the snapshot-less `diff(oldValue, newValue)` call shape), in which
-- case `parentChildrenOpaque` (hoisted once per container by the caller)
-- covers the `hasOpaqueChildren` case.
local function isOpaqueValue(v: any, snap: Snapshot?, ctx: Ctx?, parentChildrenOpaque: boolean): boolean
	if snap ~= nil then
		return snap.opaque == true
	end
	if ctx == nil or type(v) ~= "table" then
		return false
	end
	if parentChildrenOpaque then
		return true
	end
	return ctx.isOpaque(v)
end

-- Resolves the LIVE identity for `v`, given its (possibly absent) snapshot.
-- `snap.ref` is always the live table (snapshot() never clones a ref away —
-- even an ordinary, non-opaque child's `ref` is the live table; only its
-- `.value` is a frozen copy), and is nil only for scalars, where `.value` is
-- already the literal live scalar. Used when building an opaque-leaf
-- comparison so a non-opaque side (its own `t[k]` may be a frozen clone,
-- e.g. `before.value[k]`/`after.value[k]`) still reports the real reference,
-- not the clone, as `old`/`new`.
local function liveValue(v: any, snap: Snapshot?, ctx: Ctx?): any
	if snap ~= nil and snap.ref ~= nil then
		return snap.ref
	end
	-- No live ref to read from the snapshot (snapshot-less call shape, or a
	-- scalar snapshot): `v` itself may be a baseline CONTENT NODE standing in for
	-- an opaque viewer's child slot. Resolve it to the live identity it mirrors so
	-- the opaque comparison is by reference, not against the (always-unequal) copy.
	if ctx ~= nil and ctx.identityOf ~= nil then
		local identity = ctx.identityOf(v)
		if identity ~= nil then
			return identity
		end
	end
	if snap == nil then
		return v
	end
	return snap.value
end

-- ─── Snapshot ────────────────────────────────────────────────────────────────

local function snapshot(value: any, ctx: Ctx?): Snapshot
	if type(value) ~= "table" then
		return { value = value, ref = nil, children = nil }
	end

	if ctx and ctx.isOpaque(value) then
		return { value = value, ref = value, children = nil, opaque = true }
	end

	-- Hoisted once per container: a direct table-typed child is forced into
	-- the opaque-leaf shape even if it isn't itself individually registered.
	local childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)

	local children = {}
	local copy = {}
	for k, v in value do
		local childSnap: Snapshot
		if childrenOpaque and type(v) == "table" then
			childSnap = { value = v, ref = v, children = nil, opaque = true }
		else
			childSnap = snapshot(v, ctx)
		end
		children[k] = childSnap
		copy[k] = childSnap.value
	end

	return { value = table.freeze(copy), ref = value, children = children }
end

-- ─── Internal helpers ────────────────────────────────────────────────────────

-- Callers only ever invoke this with a `value` already known to be non-opaque
-- (opacity is checked one level up, where both sides of the comparison are in
-- hand) — but `value`'s OWN children may still be opaque, hence the
-- per-child check below.
local function make_removal_tree(value: any, ctx: Ctx?): DiffNode
	if type(value) ~= "table" then
		return { type = "removed", old = value, new = nil, children = nil }
	end

	local childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)
	local children: DiffTree = {}
	for k, v in pairs(value) do
		if type(v) == "table" and (childrenOpaque or (ctx ~= nil and ctx.isOpaque(v))) then
			children[k] = { type = "removed", old = v, new = nil, children = nil }
		else
			children[k] = make_removal_tree(v, ctx)
		end
	end

	return { type = "removed", old = value, new = nil, children = children }
end

-- See `make_removal_tree` re: the non-opacity invariant on `value` itself.
local function make_addition_tree(value: any, ctx: Ctx?): DiffNode
	if type(value) ~= "table" then
		return { type = "added", old = nil, new = value, children = nil }
	end

	local childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)
	local children: DiffTree = {}
	for k, v in pairs(value) do
		if type(v) == "table" and (childrenOpaque or (ctx ~= nil and ctx.isOpaque(v))) then
			children[k] = { type = "added", old = nil, new = v, children = nil }
		else
			children[k] = make_addition_tree(v, ctx)
		end
	end

	return { type = "added", old = nil, new = value, children = children }
end

local function make_descendant_node(old: any, new: any, children: DiffTree): DiffNode
	return { type = "descendantChanged", old = old, new = new, children = children }
end

-- Builds the leaf node for an opaque slot (no children walk): nil/nil -> no
-- change (returns nil), nil-old -> added, nil-new -> removed, else changed-by-ref.
local function make_opaque_leaf(v1: any, v2: any): DiffNode?
	if v1 == nil and v2 == nil then
		return nil
	elseif v1 == nil then
		return { type = "added", old = nil, new = v2, children = nil }
	elseif v2 == nil then
		return { type = "removed", old = v1, new = nil, children = nil }
	elseif v1 ~= v2 then
		return { type = "changed", old = v1, new = v2, children = nil }
	end
	return nil
end

-- ─── Core diff ───────────────────────────────────────────────────────────────

local function diff_tables(
	t1: { [any]: any },
	t2: { [any]: any },
	snap1: Snapshot?,
	snap2: Snapshot?,
	ctx: Ctx?,
	path: Path?,
	arraySink: { ArraySinkEntry }?
): DiffTree?
	local tree: DiffTree = {}
	local visited = {}

	-- Hoisted once per container (not per key): whether t1/t2's DIRECT
	-- children should be treated as opaque leaves regardless of individual
	-- registration. Only meaningful in the ctx-fallback (no-snapshot) path —
	-- when a snapshot is present, this was already baked into each child's
	-- cached `opaque` flag by `snapshot()`.
	local parentChildrenOpaque = ctx ~= nil and (ctx.hasOpaqueChildren(t1) or ctx.hasOpaqueChildren(t2))

	for k, v1 in pairs(t1) do
		visited[k] = true
		local v2 = t2[k]

		local child_snap1 = if snap1 and snap1.children then snap1.children[k] else nil
		local child_snap2 = if snap2 and snap2.children then snap2.children[k] else nil

		if
			isOpaqueValue(v1, child_snap1, ctx, parentChildrenOpaque)
			or isOpaqueValue(v2, child_snap2, ctx, parentChildrenOpaque)
		then
			local leaf = make_opaque_leaf(liveValue(v1, child_snap1, ctx), liveValue(v2, child_snap2, ctx))
			if leaf then
				tree[k] = leaf
			end
			continue
		end

		local ref1 = if child_snap1 then child_snap1.ref else nil
		local ref2 = if child_snap2 then child_snap2.ref else nil

		local is_v1_table = type(v1) == "table"
		local is_v2_table = type(v2) == "table"

		if v2 == nil then
			tree[k] = make_removal_tree(v1, ctx)
		elseif is_v1_table and is_v2_table then
			-- Array-aware mode: a both-tables node that is array-like on BOTH sides
			-- is collected for LCS re-diffing and excluded from the dict tree (so it
			-- never appears as positional changes in the OriginDiff). Creation/removal
			-- (one side not a table) still flows through the dict add/remove paths.
			if arraySink ~= nil and isSequence(v1) and isSequence(v2) then
				table.insert(arraySink, { path = PathHelpers.Append(path :: Path, k), old = v1, new = v2 })
			else
				local ref_changed = ref1 ~= nil and ref2 ~= nil and ref1 ~= ref2
				local childPath: Path? = if arraySink ~= nil then PathHelpers.Append(path :: Path, k) else nil
				local child_tree = diff_tables(v1, v2, child_snap1, child_snap2, ctx, childPath, arraySink)

				if ref_changed and child_tree == nil then
					tree[k] = { type = "changed", old = v1, new = v2, children = nil }
				elseif child_tree ~= nil then
					tree[k] = make_descendant_node(v1, v2, child_tree)
				end
			end
		elseif is_v1_table and not is_v2_table then
			local children: DiffTree = {}
			local removal = make_removal_tree(v1, ctx)
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
			local addition = make_addition_tree(v2, ctx)
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
		if visited[k] then
			continue
		end

		local child_snap2 = if snap2 and snap2.children then snap2.children[k] else nil
		if isOpaqueValue(v2, child_snap2, ctx, parentChildrenOpaque) then
			tree[k] = { type = "added", old = nil, new = liveValue(v2, child_snap2, ctx), children = nil }
		else
			tree[k] = make_addition_tree(v2, ctx)
		end
	end

	return if next(tree) ~= nil then tree else nil
end

local function diff(
	v1: any,
	v2: any,
	snap1: Snapshot?,
	snap2: Snapshot?,
	ctx: Ctx?,
	arraySink: { ArraySinkEntry }?
): DiffNode?
	-- Opacity overrides the table/scalar branching entirely: an opaque value
	-- (or nil) on either side is compared like a scalar, regardless of what
	-- the other side is.
	if isOpaqueValue(v1, snap1, ctx, false) or isOpaqueValue(v2, snap2, ctx, false) then
		return make_opaque_leaf(liveValue(v1, snap1, ctx), liveValue(v2, snap2, ctx))
	end

	local is_v1_table = type(v1) == "table"
	local is_v2_table = type(v2) == "table"

	if is_v1_table and is_v2_table then
		-- Array-aware mode: the root itself being an array on both sides is
		-- collected for LCS re-diffing and produces no dict tree.
		if arraySink ~= nil and isSequence(v1) and isSequence(v2) then
			table.insert(arraySink, { path = {}, old = v1, new = v2 })
			return nil
		end
		local children = diff_tables(v1, v2, snap1, snap2, ctx, {}, arraySink)
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
			return make_removal_tree(v1, ctx)
		end
		local tree: DiffTree = {}
		local removal = make_removal_tree(v1, ctx)
		if removal.children then
			for k, v in pairs(removal.children) do
				tree[k] = v
			end
		end
		tree[SCALAR_SENTINEL] = { type = "added", old = nil, new = v2, children = nil }
		return make_descendant_node(v1, v2, tree)
	elseif not is_v1_table and is_v2_table then
		local children: DiffTree = {}
		local addition = make_addition_tree(v2, ctx)
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
			local child_path: Path = if k ~= SCALAR_SENTINEL then PathHelpers.Append(path, k) else table.clone(path)
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

-- ─── Public API ──────────────────────────────────────────────────────────────

--------------------------------------------------------------------------------
--// Final Return //--
--------------------------------------------------------------------------------

local Module = {}

Module.diff = diff
Module.flatten = flatten
Module.snapshot = snapshot
-- The sentinel DiffTree key for the scalar side of a table<->scalar transition.
Module.ScalarSentinel = SCALAR_SENTINEL

return Module
