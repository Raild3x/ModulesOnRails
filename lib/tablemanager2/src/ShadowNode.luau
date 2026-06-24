--!strict
--[=[
	@ignore
	@class ShadowNode

	The diff baseline store: a global, identity-keyed pool of mirror nodes. Two
	managers that both reach the same live table (root or interior, e.g.
	`Player.Stats` and `Tycoon.Stats`) automatically read and reconcile the SAME
	node — sharing a table identity means sharing a baseline, with no separate
	registration step and no per-manager private copy.

	A manager's own handle (`Baseline.NewStore(manager)`) just remembers the
	manager so `Get` can find its root node (`REGISTRY[manager.Raw]`); every
	other operation is handed `live` directly by `Baseline.*` and resolves
	through the registry from there.

	Opaque values/children are kept BY REFERENCE (never copied, never
	registered) — identity comparison against them still works, exactly as in
	the pre-unification `Shadow`.
]=]

const PathHelpers = require("./PathHelpers")
const Diff = require("./Diff")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type table = { [any]: any }

export type ShadowNode = {
	_manager: any,
	Get: (self: ShadowNode, path: PathArray) -> any,
	Reconcile: (self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	Materialize: (self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	-- See the original `Shadow.ApplyArrayOp`: applies a known array op directly
	-- to the existing mirror array instead of re-copying it. Returns `false`
	-- when `path` is not yet materialized (caller falls back to `Materialize`).
	ApplyArrayOp: (
		self: ShadowNode,
		path: PathArray,
		live: any,
		opKind: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
		index: number,
		newValue: any,
		ctx: Diff.Ctx?
	) -> boolean,
	RebindRoot: (self: ShadowNode, oldRoot: any, newRoot: any) -> (),
}

const ShadowNode = {}
const ShadowNode_MT = { __index = ShadowNode }

-- ---------------------------------------------------------------------------
-- The global identity -> node registry
-- ---------------------------------------------------------------------------

-- Weak keys: a live table that is collected (or stops being referenced from
-- any manager's tree) drops its node automatically, so the registry never
-- pins live data alive.
const REGISTRY: { [table]: table } = (setmetatable({}, { __mode = "k" }) :: any) :: { [table]: table }

-- Refreshes (or creates) `REGISTRY[value]` to mirror `value`'s CURRENT
-- content, recursing into transparent children. Reuses the SAME node table on
-- every call so every other slot already holding a reference to it (from a
-- different manager, or a different path in this one) sees the refresh
-- without needing to re-fetch it. Opaque values/children are kept BY
-- REFERENCE and are deliberately never registered.
const function copyForShadow(value: any, ctx: Diff.Ctx?): any
	if type(value) ~= "table" then
		return value
	end
	if ctx ~= nil and ctx.isOpaque(value) then
		return value
	end
	local out = REGISTRY[value]
	if out == nil then
		out = {}
		REGISTRY[value] = out
	else
		table.clear(out)
	end
	const childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)
	for k, v in value do
		if childrenOpaque and type(v) == "table" then
			out[k] = v
		else
			out[k] = copyForShadow(v, ctx)
		end
	end
	return out
end

-- Walks `root` along `path`, returning the value found or nil if any
-- intermediate segment is not a table.
const function resolveAtPath(root: any, path: PathArray): any
	local current: any = root
	for _, key in path do
		if type(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ShadowNode.new(manager: any): ShadowNode
	const self = setmetatable({ _manager = manager }, ShadowNode_MT)
	return (self :: any) :: ShadowNode
end

--[=[
	Returns the last-flushed value at `path` (the diff baseline), read from
	this manager's root node. `nil` when `path` (or an ancestor of it) was
	never materialized.
]=]
function ShadowNode.Get(self: ShadowNode, path: PathArray<any>): any
	return resolveAtPath(REGISTRY[self._manager.Raw], path)
end

--[=[
	Sets the node at `path` to a fresh (or shared) mirror of `live`'s current
	value there. Requires `path`'s parent to already exist as a node; use
	`Materialize` to seed a never-before-tracked path.
]=]
function ShadowNode.Reconcile(self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?)
	const value = resolveAtPath(live, path)
	const copy = copyForShadow(value, ctx)
	if #path == 0 then
		return
	end
	const parentPath, key = PathHelpers.GetPathParentAndKey(path)
	const parentNode = if #parentPath == 0 then REGISTRY[live] else REGISTRY[resolveAtPath(live, parentPath)]
	if type(parentNode) == "table" then
		parentNode[key] = copy
	end
end

--[=[
	Seeds the node spine down to `path` (creating any missing intermediate
	nodes) and then `Reconcile`s the leaf. Safe to call on an
	already-materialized path.
]=]
function ShadowNode.Materialize(self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?)
	if #path == 0 then
		self:Reconcile(path, live, ctx)
		return
	end
	if REGISTRY[live] == nil then
		REGISTRY[live] = {}
	end
	local node = REGISTRY[live]
	const partialPath: { any } = {}
	for i = 1, #path - 1 do
		const segment = path[i]
		table.insert(partialPath, segment)
		if type(node[segment]) ~= "table" then
			node[segment] = copyForShadow(resolveAtPath(live, partialPath), ctx)
		end
		node = node[segment]
	end
	self:Reconcile(path, live, ctx)
end

--[=[
	Applies a known array op (insert/remove/set, already applied to `live`)
	directly to the EXISTING node array at `path`, instead of re-copying the
	whole array. Returns `false` when `path` has no materialized node array yet
	(the caller should fall back to `Materialize`).
]=]
function ShadowNode.ApplyArrayOp(
	self: ShadowNode,
	path: PathArray,
	live: any,
	opKind: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	index: number,
	newValue: any,
	ctx: Diff.Ctx?
): boolean
	const mirrorArray = resolveAtPath(REGISTRY[live], path)
	if type(mirrorArray) ~= "table" then
		return false
	end
	if mirrorArray == resolveAtPath(live, path) then
		return true -- stored by reference (opaque): already current by definition.
	end
	if opKind == "ArrayInserted" then
		table.insert(mirrorArray, index, copyForShadow(newValue, ctx))
	elseif opKind == "ArrayRemoved" then
		table.remove(mirrorArray, index)
	elseif opKind == "ArraySet" then
		mirrorArray[index] = copyForShadow(newValue, ctx)
	end
	return true
end

--[=[
	Re-keys the root node from `oldRoot` to `newRoot` after a root-identity swap
	(`Set({}, newRoot)`). Every node is keyed by its live table's identity, and
	the root's identity is the ONE that can change wholesale; interior tables are
	retargeted by reference, so their nodes stay correctly keyed. Without this,
	`Get({})` (which keys on the now-swapped `manager.Raw`) would no longer find
	the seeded pre-swap baseline, and the root diff would misreport every key as
	newly added. The node table itself is preserved (its old contents become the
	diff "old"); the subsequent root `Reconcile` refreshes it to `newRoot`.
]=]
function ShadowNode.RebindRoot(_self: ShadowNode, oldRoot: any, newRoot: any)
	if oldRoot == newRoot then
		return
	end
	const node = REGISTRY[oldRoot]
	REGISTRY[oldRoot] = nil
	if node ~= nil then
		REGISTRY[newRoot] = node
	end
end

return ShadowNode
