--!strict
--[=[
	@ignore
	@class Shadow

	A persistent, plain (unfrozen) deep-copied mirror of live data for
	observed regions only — the diff baseline ("old") that `TableManager:Flush`
	reads from, replacing a fresh per-write snapshot. Opaque values/children
	are kept BY REFERENCE (never copied), mirroring `Diff.snapshot`'s opacity
	handling, so identity comparison against them still works.

	The mirror is seeded lazily: `Materialize` is only ever called for a path
	some caller has independently established is worth tracking (see
	`Coverage.IsTrackable`), so regions nobody observes are simply absent from
	the mirror. Plain (unfrozen) tables make `Reconcile` a cheap child-reference
	swap and keep ancestor views automatically consistent — callers must not
	mutate a value handed to them as `oldValue` (the same contract the rest of
	TableManager already relies on for frozen snapshot values).
]=]

const PathHelpers = require("./PathHelpers")
const Diff = require("./Diff")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type table = { [any]: any }

--[=[
	Optional routing hook (injected by `TableManager`, backed by `LinkGroup`).
	Given a path in this shadow's owner's coordinates, returns the GROUP-owned
	shared shadow, the anchor-relative path within it, and the shared-object root
	to read live values from — or `nil` to operate on this shadow's own mirror.
	Lets linked members keep ONE shared baseline for a shared region instead of
	a private copy each (see `LinkGroup.ResolveSharedShadow`).
]=]
export type Resolver = (path: PathArray) -> (Shadow?, PathArray?, any?)

export type Shadow = {
	_mirror: any,
	_resolver: Resolver?,
	--- Returns the last-flushed value at `path` (the diff baseline). `nil`
	--- when `path` (or an ancestor of it) was never materialized.
	Get: (self: Shadow, path: PathArray) -> any,
	--- Sets the mirror at `path` to a fresh `copyForShadow` of `live`'s
	--- current value there. Requires `path`'s parent to already exist in the
	--- mirror; use `Materialize` to seed a never-before-tracked path.
	Reconcile: (self: Shadow, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	--- Seeds the mirror spine down to `path` (creating missing intermediate
	--- tables) and then `Reconcile`s the leaf. Safe to call on an
	--- already-materialized path.
	Materialize: (self: Shadow, path: PathArray, live: any, ctx: Diff.Ctx?) -> (),
	--- Drops the mirror subtree at `path`. No-op if `path`'s parent isn't materialized.
	Release: (self: Shadow, path: PathArray) -> (),
	--- Like `Release`, but always operates on THIS shadow's own mirror, never
	--- routing to a shared shadow. Used by `LinkGroup` lifecycle to clear a
	--- member's private region when it starts/stops sharing.
	ReleaseLocal: (self: Shadow, path: PathArray) -> (),
	--- Installs (or clears) the routing hook. See `Resolver`.
	SetResolver: (self: Shadow, resolver: Resolver?) -> (),
}

const Shadow = {}
const Shadow_MT = { __index = Shadow }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Mirrors Diff.snapshot's shape decisions, but produces a plain (unfrozen)
-- table and keeps opaque values/children by reference instead of cloning.
const function copyForShadow(value: any, ctx: Diff.Ctx?): any
	if type(value) ~= "table" then
		return value
	end
	if ctx ~= nil and ctx.isOpaque(value) then
		return value
	end
	const childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(value)
	const out = {}
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

-- Routes `path` through the optional resolver. Returns `(target, routedPath,
-- liveRoot)`: when `path` falls in a sharing-active link region, `target` is
-- the GROUP shadow, `routedPath` is anchor-relative, and `liveRoot` is the
-- shared object (the root to read live values from for Reconcile/Materialize).
-- Otherwise `target == self`, `routedPath == path`, `liveRoot == nil`. The
-- group shadow itself carries no resolver, so a routed call recurses only once.
const function route(self: Shadow, path: PathArray): (Shadow, PathArray, any)
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

function Shadow.new(): Shadow
	return (setmetatable({ _mirror = nil, _resolver = nil }, Shadow_MT) :: any) :: Shadow
end

--- Installs (or clears) the routing hook used to redirect shared-region paths
--- to a group-owned shadow. See `Resolver`.
function Shadow.SetResolver(self: Shadow, resolver: Resolver?)
	self._resolver = resolver
end

--[=[
	Returns the last-flushed value at `path` (the diff baseline). `nil` when
	`path` (or an ancestor of it) was never materialized — callers must not
	treat this as "the real value is nil" without checking coverage first.
]=]
function Shadow.Get(self: Shadow, path: PathArray<any>): any
	const target, routedPath = route(self, path)
	if target ~= self then
		return target:Get(routedPath)
	end
	return resolveAtPath(self._mirror, path)
end

--[=[
	Sets the mirror at `path` to a fresh `copyForShadow` of `live`'s current
	value there. Requires `path`'s parent to already exist in the mirror (root
	always does); use `Materialize` to seed a never-before-tracked path.
]=]
function Shadow.Reconcile(self: Shadow, path: PathArray, live: any, ctx: Diff.Ctx?)
	const target, routedPath, liveRoot = route(self, path)
	if target ~= self then
		-- Read live from the shared object (liveRoot), at the anchor-relative path.
		target:Reconcile(routedPath, liveRoot, ctx)
		return
	end
	const value = resolveAtPath(live, path)
	const copy = copyForShadow(value, ctx)
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

--[=[
	Seeds the mirror spine down to `path` (creating any missing intermediate
	tables) and then `Reconcile`s the leaf. Safe to call on an
	already-materialized path — the spine walk is then a no-op and the leaf is
	just freshly re-copied.

	A newly-created intermediate node is seeded with a full `copyForShadow` of
	its CURRENT live value, not an empty table: coverage here can come from a
	connected global Signal, which makes every path independently trackable
	without ever materializing a whole subtree up front. Without this, a
	sibling key that's never itself the target of a write (e.g. `mana` next to
	a repeatedly-written `health`) would be silently absent from the mirror —
	and a LATER wholesale replacement of the shared ancestor would fail to
	report that sibling's removal, since the diff sees it as "already absent"
	on both sides instead of genuinely removed.
]=]
function Shadow.Materialize(self: Shadow, path: PathArray, live: any, ctx: Diff.Ctx?)
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
			node[segment] = copyForShadow(resolveAtPath(live, partialPath), ctx)
		end
		node = node[segment]
	end
	self:Reconcile(path, live, ctx)
end

--[=[
	Drops the subtree at `path` (e.g. once nothing covers it anymore). Routes to
	the shared shadow for a shared-region path; otherwise drops from this
	shadow's own mirror. No-op if `path`'s parent isn't materialized.
]=]
function Shadow.Release(self: Shadow, path: PathArray)
	const target, routedPath = route(self, path)
	if target ~= self then
		target:Release(routedPath)
		return
	end
	self:ReleaseLocal(path)
end

--[=[
	Drops the subtree at `path` from THIS shadow's own mirror, never routing.
	Used by `LinkGroup` lifecycle to clear a member's private region as it starts
	or stops sharing, independent of whether routing is currently active.
]=]
function Shadow.ReleaseLocal(self: Shadow, path: PathArray)
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

return Shadow
