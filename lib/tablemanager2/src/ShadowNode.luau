--!strict
--[=[
	@ignore
	@class ShadowNode

	Identity-keyed variant of the `Shadow` baseline store (selected via
	`Baseline.NewStore()` when `Baseline.USE_SHADOW_NODE` is set).

	For a single manager it behaves EXACTLY like `Shadow` — same
	`Get`/`Reconcile`/`Materialize`/`Release` results and the same per-viewer
	opacity handling (opaque values/children kept by reference, never copied or
	walked). The one addition is `_nodes`: a weak-keyed index from each live
	table's identity to the baseline copy that mirrors it.

	That index is the foundation for the later phases:
	- Phase 3 (sharing = linking): two managers/paths that reference the same live
	  table resolve to the SAME baseline node, so a shared region has one baseline
	  and one set of observers.
	- Phase 4 (lazy slots): populate a child node only when a transparent observer
	  covers it (opaque branches already cost just a by-reference entry here).

	`_nodes` is populated but NOT yet consulted by `Get` (which still walks the
	`_mirror` tree), so single-manager behavior is byte-for-byte `Shadow`'s. The
	index uses weak keys (`__mode = "k"`) so it never pins live data alive — a
	live table that is collected drops its index entry automatically.
]=]

const PathHelpers = require("./PathHelpers")
const Diff = require("./Diff")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type table = { [any]: any }

-- The resolver may route to EITHER a `ShadowNode` or a `Shadow` (the group-owned
-- shared baseline is a `Shadow`), so the target is typed loosely; both conform
-- to the same Get/Reconcile/Materialize/Release surface.
export type Resolver = (path: PathArray) -> (any, PathArray?, any?)

export type ShadowNode = {
	_mirror: any,
	_nodes: { [table]: table },
	_resolver: Resolver?,
	Get: (self: ShadowNode, path: PathArray) -> any,
	Reconcile: (self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	Materialize: (self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	-- See `Shadow.ApplyArrayOp`: applies a known array op directly to the
	-- existing mirror array instead of re-copying it. Returns `false` when
	-- `path` is not yet materialized (caller falls back to `Materialize`).
	ApplyArrayOp: (
		self: ShadowNode,
		path: PathArray,
		live: any,
		opKind: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
		index: number,
		newValue: any,
		ctx: Diff.Ctx?
	) -> boolean,
	Release: (self: ShadowNode, path: PathArray) -> (),
	ReleaseLocal: (self: ShadowNode, path: PathArray) -> (),
	SetResolver: (self: ShadowNode, resolver: Resolver?) -> (),
}

const ShadowNode = {}
const ShadowNode_MT = { __index = ShadowNode }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Identical shape decisions to `Shadow.copyForShadow` (plain unfrozen table;
-- opaque values/children kept BY REFERENCE), with the added side effect of
-- indexing each produced baseline copy by the identity of the live table it
-- mirrors. Opaque tables are kept by reference and are deliberately NOT indexed:
-- they have no baseline node (they cost just the by-reference entry in their
-- parent), matching the "opaque branch = one ref, no node" design.
const function copyForShadow(self: ShadowNode, value: any, ctx: Diff.Ctx?): any
	if type(value) ~= "table" then
		return value
	end
	if ctx ~= nil and ctx.isOpaque(value) then
		return value
	end
	const childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)
	const out = {}
	self._nodes[value] = out
	for k, v in value do
		if childrenOpaque and type(v) == "table" then
			out[k] = v
		else
			out[k] = copyForShadow(self, v, ctx)
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

-- Routes `path` through the optional resolver (see `Shadow.route`). Returns
-- `(target, routedPath, liveRoot)`; `target == self` when the path is not in a
-- sharing-active region.
const function route(self: ShadowNode, path: PathArray): (any, PathArray, any)
	const resolver = self._resolver
	if resolver ~= nil then
		const target, routedPath, liveRoot = resolver(path)
		if target ~= nil then
			return target, routedPath :: PathArray<any>, liveRoot
		end
	end
	return self, path, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ShadowNode.new(): ShadowNode
	const self = setmetatable({
		_mirror = nil,
		-- Weak keys: a live table that is collected drops its index entry, so the
		-- index never pins live data alive.
		_nodes = (setmetatable({}, { __mode = "k" }) :: any) :: { [table]: table },
		_resolver = nil,
	}, ShadowNode_MT)
	return (self :: any) :: ShadowNode
end

function ShadowNode.SetResolver(self: ShadowNode, resolver: Resolver?)
	self._resolver = resolver
end

function ShadowNode.Get(self: ShadowNode, path: PathArray<any>): any
	const target, routedPath = route(self, path)
	if target ~= self then
		return target:Get(routedPath)
	end
	return resolveAtPath(self._mirror, path)
end

function ShadowNode.Reconcile(self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?)
	const target, routedPath, liveRoot = route(self, path)
	if target ~= self then
		target:Reconcile(routedPath, liveRoot, ctx)
		return
	end
	const value = resolveAtPath(live, path)
	const copy = copyForShadow(self, value, ctx)
	if #path == 0 then
		self._mirror = copy
		return
	end
	const parentPath, key = PathHelpers.GetPathParentAndKey(path)
	const parent = resolveAtPath(self._mirror, parentPath)
	if type(parent) == "table" then
		parent[key] = copy
	end
end

function ShadowNode.Materialize(self: ShadowNode, path: PathArray, live: any, ctx: Diff.Ctx?)
	const target, routedPath, liveRoot = route(self, path)
	if target ~= self then
		target:Materialize(routedPath, liveRoot, ctx)
		return
	end
	if #path == 0 then
		self:Reconcile(path, live, ctx)
		return
	end
	if self._mirror == nil then
		self._mirror = {}
	end
	local node = self._mirror
	const partialPath: { any } = {}
	for i = 1, #path - 1 do
		const segment = path[i]
		table.insert(partialPath, segment)
		if type(node[segment]) ~= "table" then
			node[segment] = copyForShadow(self, resolveAtPath(live, partialPath), ctx)
		end
		node = node[segment]
	end
	self:Reconcile(path, live, ctx)
end

-- See `Shadow.ApplyArrayOp`. Uses this module's own `copyForShadow` so a newly
-- inserted/set table value is indexed into `_nodes` exactly like a full
-- Materialize would have indexed it.
function ShadowNode.ApplyArrayOp(
	self: ShadowNode,
	path: PathArray,
	live: any,
	opKind: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	index: number,
	newValue: any,
	ctx: Diff.Ctx?
): boolean
	const target, routedPath, liveRoot = route(self, path)
	if target ~= self then
		return target:ApplyArrayOp(routedPath, liveRoot, opKind, index, newValue, ctx)
	end
	const mirrorArray = resolveAtPath(self._mirror, path)
	if type(mirrorArray) ~= "table" then
		return false
	end
	if mirrorArray == resolveAtPath(live, path) then
		return true -- stored by reference (opaque): already current by definition.
	end
	if opKind == "ArrayInserted" then
		table.insert(mirrorArray, index, copyForShadow(self, newValue, ctx))
	elseif opKind == "ArrayRemoved" then
		table.remove(mirrorArray, index)
	elseif opKind == "ArraySet" then
		mirrorArray[index] = copyForShadow(self, newValue, ctx)
	end
	return true
end

function ShadowNode.Release(self: ShadowNode, path: PathArray)
	const target, routedPath = route(self, path)
	if target ~= self then
		target:Release(routedPath)
		return
	end
	self:ReleaseLocal(path)
end

function ShadowNode.ReleaseLocal(self: ShadowNode, path: PathArray)
	if #path == 0 then
		self._mirror = nil
		return
	end
	const parentPath, key = PathHelpers.GetPathParentAndKey(path)
	const parent = resolveAtPath(self._mirror, parentPath)
	if type(parent) == "table" then
		parent[key] = nil
	end
end

return ShadowNode
