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

	Each table slot's shape — a deep content node vs. the live ref — is chosen by
	GLOBAL observership (the injected `isObserved` predicate), NOT by the
	reconciling manager's opacity: a content node iff SOME manager observes the
	child transparently, otherwise the live ref (opaque to everyone / unobserved —
	never copied, never walked). Because the choice is global, every manager
	reconciles a shared slot to the SAME shape, so co-observers that disagree on a
	child's opacity cannot corrupt each other's baseline. An opaque viewer reading
	a content-node slot still recovers the child's identity via `IdentityOf`, so
	identity comparison keeps working exactly as before.
]=]

const PathHelpers = require("./PathHelpers")
const Diff = require("./Diff")

--// Types //--
type PathArray = PathHelpers.PathArray<string>
type table = { [any]: any }

export type ShadowNode = {
	_manager: any,
	-- Injected at construction (see `new`): the global "is anyone observing this
	-- table transparently?" predicate. Decides each table slot's shape — content
	-- node vs. live ref — independently of any one manager's opacity.
	_isObserved: (child: any) -> boolean,
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

-- Node -> live identity back-reference. Records, for every content node built by
-- `copyForShadow`, the live table it mirrors. Weak in BOTH keys and values so it
-- never pins a node or a live table alive (the baseline must hold copies, not
-- live data — see `MemoryLeaks.spec`). Read via `ShadowNode.IdentityOf`: lets an
-- opaque viewer reading a CONTENT-node slot recover the child's real identity to
-- compare against live, instead of comparing the (always-unequal) copy.
const IDENTITY_OF: { [table]: any } = (setmetatable({}, { __mode = "kv" }) :: any) :: { [table]: any }

-- Default observership predicate for stores constructed without an injected one
-- (e.g. the isolated `ShadowNode` unit tests, which never register observership):
-- treat every table as observed, reproducing the pre-fix "always build a content
-- node" behavior so those tests stay byte-identical.
const function DEFAULT_IS_OBSERVED(_child: any): boolean
	return true
end

-- Refreshes (or creates) `REGISTRY[value]` to mirror `value`'s CURRENT
-- content, recursing into observed children. Reuses the SAME node table on
-- every call so every other slot already holding a reference to it (from a
-- different manager, or a different path in this one) sees the refresh
-- without needing to re-fetch it.
--
-- The slot shape is chosen by GLOBAL observership, not by any one manager's
-- opacity: a table is stored as a content node iff SOME manager observes it
-- transparently (`isObserved`), otherwise it is kept BY REFERENCE (opaque to
-- everyone / unobserved — never copied, never walked). Because the gate is
-- global, every manager reconciles the same slot to the same shape, so two
-- co-observers with different opacity can no longer corrupt each other.
const function copyForShadow(value: any, isObserved: (any) -> boolean): any
	if type(value) ~= "table" then
		return value
	end
	if not isObserved(value) then
		return value
	end
	local out = REGISTRY[value]
	if out == nil then
		out = {}
		REGISTRY[value] = out
	else
		table.clear(out)
	end
	IDENTITY_OF[out] = value
	for k, v in value do
		out[k] = copyForShadow(v, isObserved)
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

function ShadowNode.new(manager: any, isObserved: ((child: any) -> boolean)?): ShadowNode
	const self = setmetatable({
		_manager = manager,
		_isObserved = isObserved or DEFAULT_IS_OBSERVED,
	}, ShadowNode_MT)
	return (self :: any) :: ShadowNode
end

--[=[
	Returns the live identity that the baseline content `node` mirrors, or `nil`
	if `node` is not a registered content node. Lets the diff's opaque branch
	compare a content-node slot by the child's real identity (not the copy).
]=]
function ShadowNode.IdentityOf(node: any): any
	if type(node) ~= "table" then
		return nil
	end
	return IDENTITY_OF[node]
end

--[=[
	Returns the last-flushed value at `path` (the diff baseline), read from
	this manager's root node. `nil` when `path` (or an ancestor of it) was
	never materialized.
]=]
function ShadowNode.Get(self: ShadowNode, path: PathArray): any
	return resolveAtPath(REGISTRY[self._manager.Raw], path)
end

--[=[
	Sets the node at `path` to a fresh (or shared) mirror of `live`'s current
	value there. Requires `path`'s parent to already exist as a node; use
	`Materialize` to seed a never-before-tracked path.
]=]
function ShadowNode.Reconcile(self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?)
	const value = resolveAtPath(live, path)
	const copy = copyForShadow(value, self._isObserved)
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
			node[segment] = copyForShadow(resolveAtPath(live, partialPath), self._isObserved)
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
		table.insert(mirrorArray, index, copyForShadow(newValue, self._isObserved))
	elseif opKind == "ArrayRemoved" then
		table.remove(mirrorArray, index)
	elseif opKind == "ArraySet" then
		mirrorArray[index] = copyForShadow(newValue, self._isObserved)
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
