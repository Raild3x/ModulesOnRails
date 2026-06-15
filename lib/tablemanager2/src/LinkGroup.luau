--!strict
--[=[
	@ignore
	@class LinkGroup

	Identity-keyed groups of TableManager "anchors" that share one underlying
	table by object identity. A write applied through any member's pipeline is
	fanned out (notify-only, never re-mutated) to every other current member of
	the group, translated into that member's own path coordinates.

	Membership is owned by the group, not by any individual TableManager, so
	destroying/unlinking one member never breaks the link between the others
	(no relay chains).
]=]

local PathHelpers = require("./PathHelpers")
local Signal = require("../Signal")

type PathArray<S = string> = PathHelpers.PathArray<S>
type Path<S> = PathHelpers.Path<S>
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

--// Types //--

-- Minimal structural view of a TableManager's ProxyManager that LinkGroup
-- itself touches (avoids a circular require of ProxyManager/TableManager).
type ProxyManagerLike = {
	IsProxy: (self: ProxyManagerLike, value: any) -> boolean,
	GetPath: (self: ProxyManagerLike, proxy: any) -> PathArray?,
}

-- Minimal structural view of a TableManager (TM_Internal) that LinkGroup
-- and the fan-out hooks need. Kept local to avoid a circular require with
-- TableManager.luau (which requires this module).
type TableManagerLike = {
	Get: (self: TableManagerLike, path: Path<any>?, raw: boolean?) -> any,
	GetProxy: (self: TableManagerLike, path: Path<any>?, raw: boolean?) -> any,
	_NotifyApplied: (self: TableManagerLike, op: AppliedOp) -> (),
	_proxyManager: ProxyManagerLike?,
	_linkGroups: { LinkGroup }?,
	_Destroyed: boolean?,
}

export type AppliedOp = {
	Kind: "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet",
	Path: PathArray,
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- A relative op (relative to the shared object) computed by the fan-out hooks,
-- before being translated into each member's own coordinates.
type RelativeOp = {
	Kind: "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet",
	RelativePath: PathArray,
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- Payload shape passed from `fireArrayOperation` for array-op fan-out.
export type ArrayOpPayload = {
	NewValue: any?,
	OldValue: any?,
	Index: number?,
}

-- A positional 2-tuple { manager, path } naming a shared node inside a TM.
export type LinkAnchor = { TableManagerLike | Path<any> }

type Member = {
	Manager: TableManagerLike, -- TM_Internal<any>
	AnchorPath: PathArray,
	AnchorProxy: any?,
}

export type LinkGroup = {
	_object: any,
	_members: { Member },
	_destroyed: boolean,
	MemberRemoved: Signal<(manager: TableManagerLike) -> (), TableManagerLike>,
	Dissolved: Signal<() -> ()>,
	Add: (self: LinkGroup, manager: TableManagerLike, path: Path<any>?) -> (),
	Remove: (self: LinkGroup, manager: TableManagerLike) -> (),
	Members: (self: LinkGroup) -> { TableManagerLike },
	HasMember: (self: LinkGroup, manager: TableManagerLike) -> boolean,
	GetAnchorPath: (self: LinkGroup, manager: TableManagerLike) -> PathArray?,
	NotifyChange: (self: LinkGroup, originManager: TableManagerLike, op: RelativeOp) -> (),
	Destroy: (self: LinkGroup) -> (),
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local LinkGroup = {}
local LinkGroup_MT = { __index = LinkGroup }

-- Weak identity-keyed registry: object (shared table) -> LinkGroup.
local OBJECT_TO_GROUP: { [any]: LinkGroup } = setmetatable({}, { __mode = "k" }) :: any

local function resolveAnchorPath(path: Path<any>?): PathArray
	if path == nil or path == "" then
		return {}
	end
	return PathHelpers.ParsePath(path)
end

--[=[
	Removes `manager` from `group`'s membership bookkeeping (both directions),
	fires `MemberRemoved`, and dissolves the group if membership drops below 2.
]=]
local function removeMember(self: LinkGroup, manager: TableManagerLike): boolean
	-- Drop manager's membership record(s) from the group's side.
	local removedAny = false
	for i = #self._members, 1, -1 do
		if self._members[i].Manager == manager then
			table.remove(self._members, i)
			removedAny = true
		end
	end

	if not removedAny then
		return false
	end

	-- Drop the group from manager's own membership list (the reverse edge).
	local groups = manager._linkGroups
	if groups then
		for i = #groups, 1, -1 do
			if groups[i] == self then
				table.remove(groups, i)
			end
		end
	end

	self.MemberRemoved:Fire(manager)

	-- A group of fewer than 2 members has nothing left to fan out to.
	if #self._members < 2 then
		self:Destroy()
	end

	return true
end

--[=[
	Joins (or updates) `manager`'s anchor on `self`. Asserts that `manager:Get(path)`
	currently resolves to the group's shared object. Idempotent: re-adding the same
	manager updates its anchor path instead of duplicating membership.
]=]
function LinkGroup.Add(self: LinkGroup, manager: TableManagerLike, path: Path<any>?)
	-- Validate the anchor: it must currently resolve to the group's shared object.
	local parsedPath = resolveAnchorPath(path)
	local value = manager:Get(parsedPath)
	assert(value == self._object, "Link anchor does not resolve to the shared object")

	-- If the anchor resolves through a proxy, remember it so GetAnchorPath can
	-- report the *live* path even after array shifts/MoveTo/Swap.
	local anchorProxy: any? = nil
	local proxyManager = manager._proxyManager
	if proxyManager and type(value) == "table" then
		local proxy = manager:GetProxy(parsedPath, true)
		if proxyManager:IsProxy(proxy) then
			anchorProxy = proxy
		end
	end

	-- Idempotent re-add: update the existing member's anchor instead of duplicating it.
	for _, member in self._members do
		if member.Manager == manager then
			member.AnchorPath = parsedPath
			member.AnchorProxy = anchorProxy
			return
		end
	end

	-- New member: record both directions of the membership edge.
	table.insert(self._members, { Manager = manager, AnchorPath = parsedPath, AnchorProxy = anchorProxy })

	local groups = manager._linkGroups
	if groups == nil then
		groups = {}
		manager._linkGroups = groups
	end
	table.insert(groups :: { LinkGroup }, self)
end

--[=[
	Removes `manager`'s anchor from the group. No-op if `manager` is not a member.
]=]
function LinkGroup.Remove(self: LinkGroup, manager: TableManagerLike)
	removeMember(self, manager)
end

--[=[
	Returns the live managers currently in this group.
]=]
function LinkGroup.Members(self: LinkGroup): { TableManagerLike }
	local result = table.create(#self._members) :: { TableManagerLike }
	for _, member in self._members do
		table.insert(result, member.Manager)
	end
	return result
end

function LinkGroup.HasMember(self: LinkGroup, manager: TableManagerLike): boolean
	for _, member in self._members do
		if member.Manager == manager then
			return true
		end
	end
	return false
end

--[=[
	Returns the live path (in `manager`'s coordinates) to the shared object, or
	`nil` if `manager` is not a member. Uses the manager's own proxy graph (if
	available) so the anchor stays correct across array shifts/MoveTo/Swap.
]=]
function LinkGroup.GetAnchorPath(self: LinkGroup, manager: TableManagerLike): PathArray?
	for _, member in self._members do
		if member.Manager == manager then
			if member.AnchorProxy ~= nil then
				local proxyManager = manager._proxyManager
				if proxyManager then
					local livePath = proxyManager:GetPath(member.AnchorProxy)
					if livePath ~= nil then
						return livePath
					end
				end
			end
			return member.AnchorPath
		end
	end
	return nil
end

--[=[
	Fans `op` (relative to the shared object) out to every other current member,
	translating into each member's own coordinates and replaying it via
	`_NotifyApplied`. Isolates each member's delivery in `pcall` so one throwing
	listener can't block delivery to the rest. Snapshots the member list so a
	member that leaves mid-dispatch (e.g. divergence detected during its own
	notify) doesn't corrupt iteration.
]=]
function LinkGroup.NotifyChange(self: LinkGroup, originManager: TableManagerLike, op: RelativeOp)
	-- Snapshot membership: a member's _NotifyApplied may itself trigger a
	-- divergence that removes a member mid-dispatch.
	local members = table.clone(self._members)
	for _, member in members do
		local manager = member.Manager
		if manager == originManager then
			continue
		end
		if manager._Destroyed then
			continue
		end
		if not self:HasMember(manager) then
			continue
		end

		local anchorPath = self:GetAnchorPath(manager)
		if anchorPath == nil then
			continue
		end

		-- Translate the op from "relative to the shared object" into this
		-- member's own root-relative coordinates.
		local translatedPath: PathArray = table.clone(anchorPath)
		for _, segment in op.RelativePath do
			table.insert(translatedPath, segment)
		end

		local appliedOp: AppliedOp = {
			Kind = op.Kind,
			Path = translatedPath,
			NewValue = op.NewValue,
			OldValue = op.OldValue,
			Index = op.Index,
		}

		-- Isolate each member's delivery: a throwing listener on one member
		-- must not block fan-out to the rest.
		local ok, err = pcall(manager._NotifyApplied, manager, appliedOp)
		if not ok then
			task.spawn(error, err, 0)
		end
	end
end

--[=[
	Tears down the group's wiring. Does NOT destroy member TableManagers.
]=]
function LinkGroup.Destroy(self: LinkGroup)
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Unlink every remaining member's reverse edge before clearing membership.
	for _, member in table.clone(self._members) do
		local groups = member.Manager._linkGroups
		if groups then
			for i = #groups, 1, -1 do
				if groups[i] == self then
					table.remove(groups, i)
				end
			end
		end
	end
	table.clear(self._members)

	-- Drop the canonical registration so a future Link on this object starts fresh.
	OBJECT_TO_GROUP[self._object] = nil

	self.Dissolved:Fire()
	self.MemberRemoved:Destroy()
	self.Dissolved:Destroy()
end

--------------------------------------------------------------------------------
--// Static Helpers //--
--------------------------------------------------------------------------------

-- Constructs a fresh, empty group for `object`. Not registered in
-- OBJECT_TO_GROUP here; callers register via getOrCreateGroup.
local function newGroup(object: any): LinkGroup
	local self = setmetatable({}, LinkGroup_MT) :: any
	self._object = object
	self._members = {}
	self._destroyed = false
	self.MemberRemoved = Signal.new() :: any
	self.Dissolved = Signal.new() :: any
	return self
end

--[=[
	Returns the canonical group for `object`'s identity, creating it if needed.
]=]
local function getOrCreateGroup(object: any): LinkGroup
	local group = OBJECT_TO_GROUP[object]
	if group == nil then
		group = newGroup(object)
		OBJECT_TO_GROUP[object] = group
	end
	return group
end

--[=[
	`TableManager.Link` implementation. Two call forms:
	- `Link({ {manager, path?}, {manager, path?}, ... })`
	- `Link(managerA, pathA, managerB, pathB)`

	All anchors must resolve to the same shared object (by identity); they are
	joined into that object's canonical `LinkGroup`.
]=]
local function link(...): LinkGroup
	local argCount = select("#", ...)

	-- Normalize both call forms into a single list of { manager, path? } anchors.
	local anchors: { LinkAnchor }
	if argCount == 1 then
		anchors = (...) :: any
	else
		local a, pathA, b, pathB = ...
		anchors = { { a, pathA }, { b, pathB } }
	end

	assert(#anchors >= 2, "Link requires at least 2 anchors")

	-- The first anchor's resolved value defines the shared object's identity
	-- and therefore which canonical LinkGroup every anchor will join.
	local firstManager = anchors[1][1] :: TableManagerLike
	local firstPath = anchors[1][2] :: Path<any>?
	local object = firstManager:Get(resolveAnchorPath(firstPath), true)
	assert(type(object) == "table", "Link anchors must resolve to a shared table")

	-- Validate and join every anchor; Add asserts identity again per-anchor.
	local group = getOrCreateGroup(object)
	for _, anchor in anchors do
		local manager = anchor[1] :: TableManagerLike
		local path = anchor[2] :: Path<any>?
		local value = manager:Get(resolveAnchorPath(path), true)
		assert(value == object, "All Link anchors must resolve to the same shared object")
		group:Add(manager, path)
	end

	return group
end

--[=[
	Identity-based divergence check, called directly from `applyWrite` right
	after a write is applied (before change detection runs). If `writePath` is
	at or above one of `self`'s link anchors and that anchor no longer resolves
	to its group's shared object (the reference was replaced), that anchor
	leaves the group.

	This is independent of the ChangeDetector diff shape: a wholesale
	reassignment of a table to a structurally-similar table is reported by
	ChangeDetector as "descendantChanged" (a deep structural diff), not as an
	identity replacement, so divergence cannot be reliably detected from the
	OnValueChanged diff metadata alone.
]=]
local function checkDivergence(self: TableManagerLike, writePath: PathArray)
	local groups = self._linkGroups
	if groups == nil then
		return
	end

	for _, group in table.clone(groups) do
		local anchorPath = group:GetAnchorPath(self)
		if anchorPath == nil then
			continue
		end

		-- Only anchors at-or-above the write could have had their identity replaced.
		if PathHelpers.IsPrefixPath(writePath, anchorPath) then
			if self:Get(anchorPath, true) ~= group._object then
				-- The anchor no longer points at the shared object: sever this
				-- member only. The rest of the group keeps the original object.
				group:Remove(self)
			end
		end
	end
end

--[=[
	Fan-out hook for "Set"-kind changes (called from the OnValueChanged
	ChangeDetector callback). `path` is the changed location, in `self`'s own
	coordinates.
]=]
local function fanOutSet(self: TableManagerLike, path: PathArray, newValue: any, oldValue: any)
	local groups = self._linkGroups
	if groups == nil then
		return
	end

	for _, group in table.clone(groups) do
		local anchorPath = group:GetAnchorPath(self)
		if anchorPath == nil then
			continue
		end

		if PathHelpers.IsPrefixPath(path, anchorPath) then
			-- `path` is the anchor itself or an ancestor of it: the shared
			-- object's reference at this anchor may have changed. Check
			-- liveness; if it diverged, this anchor leaves the group (the
			-- remaining members still share the original object untouched).
			if self:Get(anchorPath, true) ~= group._object then
				group:Remove(self)
			end
		elseif PathHelpers.IsPrefixPath(anchorPath, path) then
			-- `path` is strictly inside the anchor: compute the change's
			-- location relative to the shared object and fan it out.
			local relativePath: PathArray = {}
			for i = #anchorPath + 1, #path do
				table.insert(relativePath, path[i])
			end
			group:NotifyChange(self, {
				Kind = "Set",
				RelativePath = relativePath,
				NewValue = newValue,
				OldValue = oldValue,
			})
		end
	end
end

--[=[
	Fan-out hook for array-op changes (called from `fireArrayOperation`).
	`basePath` is the array's own path, in `self`'s own coordinates.
]=]
local function fanOutArrayOp(
	self: TableManagerLike,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray,
	payload: ArrayOpPayload
)
	local groups = self._linkGroups
	if groups == nil then
		return
	end

	-- Translate the event name into the AppliedOp vocabulary shared with fanOutSet.
	local kind: "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet" = if eventName == "ArrayInserted"
		then "ArrayInsert"
		elseif eventName == "ArrayRemoved" then "ArrayRemove"
		else "ArraySet"

	for _, group in table.clone(groups) do
		local anchorPath = group:GetAnchorPath(self)
		if anchorPath == nil then
			continue
		end

		-- relativePath stays nil unless the array itself IS (or contains) the
		-- shared object, i.e. the anchor is at or above basePath.
		local relativePath: PathArray? = nil
		if PathHelpers.ArePathsEqual(anchorPath, basePath) then
			relativePath = {}
		elseif PathHelpers.IsPrefixPath(anchorPath, basePath) then
			relativePath = {}
			for i = #anchorPath + 1, #basePath do
				table.insert(relativePath :: PathArray, basePath[i])
			end
		end

		if relativePath == nil then
			-- Anchor lives inside this array (or is unrelated). Index shifts to
			-- an anchor nested in the array are this manager's own bookkeeping
			-- (handled by ShiftKeys against its own proxy graph) and don't
			-- change the shared object's identity or content, so no fan-out.
			continue
		end

		group:NotifyChange(self, {
			Kind = kind,
			RelativePath = relativePath,
			NewValue = payload.NewValue,
			OldValue = payload.OldValue,
			Index = payload.Index,
		})
	end
end

return {
	Link = link,
	GetOrCreateGroup = getOrCreateGroup,
	CheckDivergence = checkDivergence,
	FanOutSet = fanOutSet,
	FanOutArrayOp = fanOutArrayOp,
}
