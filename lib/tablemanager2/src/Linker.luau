--!strict
--[=[
	@class Linker

	Per-instance facade hosting all linking operations for a TableManager,
	reachable via `tm.Linker`. Hosts the linking methods so they do not crowd the
	core TableManager surface; the heavy state (`_linkGroups`) and the hot-path
	fan-out / auto-link hooks live on the manager itself, so the zero-ceremony
	`AutoLink` path never goes through this facade.
]=]

const LinkGroupModule = require("./LinkGroup")
const PathHelpers = require("./PathHelpers")

type Path<S> = PathHelpers.Path<S>
type LinkGroup = LinkGroupModule.LinkGroup

--[=[
	@within Linker
	@private

	Minimal structural view of the TableManager this Linker is attached to.
	Kept local (and minimal) to avoid a circular require with TableManager.luau,
	which requires this module to build `self.Linker`.
]=]
export type LinkerHost = {
	_linkGroups: { LinkGroup }?,
}

export type Linker = {
	With: (self: Linker, other: any, selfPath: Path<any>?, otherPath: Path<any>?) -> (),
	Ensure: (self: Linker, path: Path<any>?) -> (),
	Unlink: (self: Linker, target: any?) -> (),
	GetManagers: (self: Linker) -> { any },
	IsLinkedWith: (self: Linker, other: any) -> boolean,
	GetGroups: (self: Linker) -> { LinkGroup },
}

-- Implementation-side view of `Linker`, including the back-reference to the
-- host TableManager. `Linker` itself never exposes `_tm`.
type LinkerImpl = Linker & { _tm: LinkerHost }

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const Linker = {}
const Linker_MT = { __index = Linker }

--[=[
	@within Linker
	@private

	Constructs the lazy `Linker` facade for `tm`. Allocated once at
	construction; negligible next to the other per-instance state.
]=]
const function new(tm: LinkerHost): Linker
	return setmetatable({ _tm = tm }, Linker_MT) :: any
end

--[=[
	@within Linker
	Links this manager to `other` so writes fan out between them. With no paths,
	both anchors are the managers' roots; pass `selfPath`/`otherPath` to link
	interior nodes that resolve to the same shared table by identity.
]=]
function Linker.With(self: LinkerImpl, other: any, selfPath: Path<any>?, otherPath: Path<any>?)
	LinkGroupModule.Link({ { self._tm :: any, selfPath }, { other, otherPath } })
end

--[=[
	@within Linker
	Scans this manager's subtree at `path` (default root) and links any node that
	is the root of another `AutoLink` manager. The explicit, recursive form of the
	direct write-path auto-link; use after a nested/bulk insert. Idempotent.
]=]
function Linker.Ensure(self: LinkerImpl, path: Path<any>?)
	LinkGroupModule.FindChildLinks(self._tm :: any, path)
end

--[=[
	@within Linker
	Removes this manager from `target`: `nil` → all of its groups; a manager →
	every group also containing that manager; a `LinkGroup` → just that group.
]=]
function Linker.Unlink(self: LinkerImpl, target: any?)
	const tm = self._tm
	const groups = tm._linkGroups

	-- Whole detach (no target).
	if target == nil then
		if groups == nil then
			return
		end
		for _, g in table.clone(groups) do
			g:Remove(tm :: any)
		end
		return
	end

	-- A LinkGroup carries `_members`; anything else is treated as a manager.
	if type(target) == "table" and (target :: any)._members ~= nil then
		(target :: any):Remove(tm :: any)
		return
	end

	if groups == nil then
		return
	end
	for _, g in table.clone(groups) do
		if g:HasMember(target) then
			g:Remove(tm :: any)
		end
	end
end

--[=[
	@within Linker
	Returns the managers currently linked to this one (de-duplicated across
	groups, excluding self).
]=]
function Linker.GetManagers(self: LinkerImpl): { any }
	const tm = self._tm
	const result = {}
	const groups = tm._linkGroups
	if groups == nil then
		return result
	end
	const seen: { [any]: true } = {}
	for _, g in groups do
		for _, m in g:Members() do
			if m ~= tm and not seen[m] then
				seen[m] = true
				table.insert(result, m)
			end
		end
	end
	return result
end

--[=[
	@within Linker
	Returns true if this manager shares a group with `other`.
]=]
function Linker.IsLinkedWith(self: LinkerImpl, other: any): boolean
	const groups = self._tm._linkGroups
	if groups == nil then
		return false
	end
	for _, g in groups do
		if g:HasMember(other) then
			return true
		end
	end
	return false
end

--[=[
	@within Linker
	Advanced: the underlying `LinkGroup`s this manager participates in (a copy).
]=]
function Linker.GetGroups(self: LinkerImpl): { LinkGroup }
	const groups = self._tm._linkGroups
	return if groups then table.clone(groups) else {}
end

return {
	new = new,
}
