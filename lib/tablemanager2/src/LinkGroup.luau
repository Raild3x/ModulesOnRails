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
local TMTypes = require("./TMTypes")
local Diff = require("./Diff")
local ShadowModule = require("./Shadow")

type PathArray<S = string> = PathHelpers.PathArray<S>
type Path<S> = PathHelpers.Path<S>
type DiffNode = Diff.DiffNode
type Shadow = ShadowModule.Shadow
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

--// Types //--

-- `TableManagerLike` (= `TM_Internal<any>`), `AppliedOp`, `RelativeOp`,
-- `ArrayOpPayload`, `LinkAnchor`, and `LinkGroup` are defined in `TMTypes`
-- (a leaf module), so TableManager.luau can reference the real types here
-- without a circular require.
type TableManagerLike = TMTypes.TableManagerLike
export type AppliedOp = TMTypes.AppliedOp
type RelativeOp = TMTypes.RelativeOp
export type ArrayOpPayload = TMTypes.ArrayOpPayload
export type LinkAnchor = TMTypes.LinkAnchor

type Member = {
	Manager: TableManagerLike, -- TM_Internal<any>
	AnchorPath: PathArray,
	AnchorProxy: any?,
}

type opKind = "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet"

export type LinkGroup = TMTypes.LinkGroup

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

-- ---------------------------------------------------------------------------
-- Shadow sharing (Phase C)
--
-- When sharing is active, every member routes shadow access for its shared
-- region to a single group-owned shadow (`ResolveSharedShadow`), so the region
-- has ONE baseline instead of a private copy per member.
-- ---------------------------------------------------------------------------

-- A single shared shadow can serve the whole group only when no member has
-- PER-MANAGER opaque marks (those make `copyForShadow`'s shape differ per
-- member). Global opacity is shared by every manager, so it shapes the baseline
-- identically and is fine — hence the per-manager registry count check.
local function allMembersOpacityFree(self: LinkGroup): boolean
	for _, member in self._members do
		if (member.Manager :: TableManagerLike)._opaqueRegistries.Count > 0 then
			return false
		end
	end
	return true
end

-- Drops `manager`'s PRIVATE shadow content for its shared region (the subtree at
-- its live anchor) via `ReleaseLocal` (never routes). Called when the region
-- becomes group-shared, so a later fall back to the private shadow (sharing
-- deactivating, or the group dissolving) re-seeds cleanly from live instead of
-- reading stale pre-share content.
local function clearPrivateRegion(self: LinkGroup, manager: TableManagerLike)
	local anchor = self:GetAnchorPath(manager)
	if anchor ~= nil then
		manager._shadow:ReleaseLocal(anchor)
	end
end

-- Recomputes `_shadowSharingActive` and handles the transition:
--  * OFF->ON: clear every member's private region (so a later fall back re-seeds
--    cleanly rather than reading stale pre-share content).
--  * ON->OFF: abandon the shared shadow. Members fall back to their (empty)
--    private shadows and re-seed from live on their next write; dropping the
--    shared shadow means a future reactivation also starts from a fresh,
--    correctly-seeded baseline instead of reusing stale data.
local function recomputeSharing(self: LinkGroup)
	local active = #self._members >= 2 and allMembersOpacityFree(self)
	if active == self._shadowSharingActive then
		return
	end
	if active then
		for _, member in self._members do
			clearPrivateRegion(self, member.Manager)
		end
	else
		self._sharedShadow = nil
	end
	self._shadowSharingActive = active
end

--[=[
	@within LinkGroup

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
	else
		-- Membership shrank but the group survives: re-evaluate shadow sharing
		-- (e.g. the removed member was the only opacity holder).
		recomputeSharing(self)
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

	-- Phase C: re-evaluate shadow sharing now membership changed.
	local wasActive = self._shadowSharingActive
	recomputeSharing(self)
	if self._shadowSharingActive and wasActive then
		-- Joined an already-active group: `recomputeSharing` is a no-op (no
		-- transition), so clear just THIS member's stale private region here.
		clearPrivateRegion(self, manager)
	end
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
			-- Phase B: carry the origin's diff node (and its opacity state) so the
			-- recipient can replay it without re-diffing (see _NotifyApplied).
			Diff = op.Diff,
			OriginHasNoOpacity = op.OriginHasNoOpacity,
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
	-- Phase C: sharing is off once there are no members; drop the shared shadow.
	self._shadowSharingActive = false
	self._sharedShadow = nil

	-- Drop the canonical registration so a future Link on this object starts fresh.
	OBJECT_TO_GROUP[self._object] = nil

	self.Dissolved:Fire()
	self.MemberRemoved:Destroy()
	self.Dissolved:Destroy()
end

-- ---------------------------------------------------------------------------
-- Shadow sharing: resolver + opacity recompute (called from TableManager)
-- ---------------------------------------------------------------------------

-- Routing hook installed on each member's `Shadow` (see `Shadow.SetResolver`).
-- For `path` in `manager`'s coordinates, returns the group-owned shared shadow,
-- the anchor-relative path within it, and the shared object (live root) when
-- `path` falls in a sharing-active region; otherwise nil so the op runs on the
-- manager's own mirror.
local function resolveSharedShadow(manager: TableManagerLike, path: PathArray): (Shadow?, PathArray?, any?)
	local groups = manager._linkGroups
	if groups == nil then
		return nil
	end
	for _, group in groups :: { LinkGroup } do
		if group._shadowSharingActive then
			local anchorPath = group:GetAnchorPath(manager)
			if anchorPath ~= nil and PathHelpers.IsPrefixPath(anchorPath, path) then
				if group._sharedShadow == nil then
					group._sharedShadow = ShadowModule.new()
				end
				local rel: PathArray = {}
				for i = #anchorPath + 1, #path do
					rel[#rel + 1] = path[i]
				end
				return group._sharedShadow, rel, group._object
			end
		end
	end
	return nil
end

-- Re-evaluates shadow sharing for every group `manager` belongs to. Called by
-- TableManager after `manager` registers a per-manager opaque mark (which can
-- flip a group from opacity-free to not).
local function recomputeSharingForManager(manager: TableManagerLike)
	local groups = manager._linkGroups
	if groups == nil then
		return
	end
	for _, group in table.clone(groups) :: { LinkGroup } do
		recomputeSharing(group)
	end
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
	self._sharedShadow = nil
	self._shadowSharingActive = false
	self.MemberRemoved = Signal.new() :: any
	self.Dissolved = Signal.new() :: any
	return self
end

-- Returns the canonical group for `object`'s identity, creating it if needed.
local function getOrCreateGroup(object: any): LinkGroup
	local group = OBJECT_TO_GROUP[object]
	if group == nil then
		group = newGroup(object)
		OBJECT_TO_GROUP[object] = group
	end
	return group
end

--[=[
	@within LinkGroup

	`TableManager.Link` implementation. Two call forms:
	- `Link({ {manager, path?}, {manager, path?}, ... })`
	- `Link(managerA, pathA, managerB, pathB)`

	All anchors must resolve to the same shared object (by identity); they are
	joined into that object's canonical `LinkGroup`.

	@param ... Either a single list of `{manager, path?}` anchors, or pairs of `manager, path?` arguments.
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
	@within LinkGroup

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
	@within LinkGroup

	Called when `self`'s root table identity has been replaced
	(`Set({}, newRoot)`). The manager's cached anchor proxies pointed into the
	now-pruned old tree, so clear them (GetAnchorPath then falls back to the
	static AnchorPath), then run the standard divergence check at the root: any
	anchor that no longer resolves to its group's shared object is severed. This
	is the `{}` generalisation of the ancestor-replacement handling in
	`checkDivergence`.
]=]
local function onRootReplaced(self: TableManagerLike)
	local groups = self._linkGroups
	if groups == nil then
		return
	end

	for _, group in table.clone(groups) do
		for _, member in group._members do
			if member.Manager == self then
				member.AnchorProxy = nil
				break
			end
		end
	end

	checkDivergence(self, {})
end

--[=[
	@within LinkGroup

	Fan-out hook for "Set"-kind changes (called from the OnValueChanged
	ChangeDetector callback). `path` is the changed location, in `self`'s own
	coordinates.
]=]
local function fanOutSet(self: TableManagerLike, path: PathArray, newValue: any, oldValue: any, diffNode: DiffNode?)
	local groups = self._linkGroups
	if groups == nil then
		return
	end

	-- Phase B: a recipient may only reuse `diffNode` when neither side has any
	-- PER-MANAGER opaque marks. Global opacity is shared by every manager, so it
	-- shapes the origin's and the recipient's diff identically and is safe to
	-- reuse across — hence we check the per-manager registry count, NOT
	-- `GetOpaqueCtx()` (which also reflects the session-wide global count and
	-- would needlessly disable reuse). Recipients re-check their own count in
	-- `_NotifyApplied`.
	local originHasNoOpacity = self._opaqueRegistries.Count == 0

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
				Diff = diffNode,
				OriginHasNoOpacity = originHasNoOpacity,
			})
		end
	end
end

--[=[
	@within LinkGroup

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
	local kind: opKind = if eventName == "ArrayInserted"
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

--------------------------------------------------------------------------------
--// Auto-Link //--
--
-- Opt-in (`Config.AutoLink = true`) automatic linking for the "nested window"
-- pattern, where one TableManager's root table is a node inside another
-- TableManager's tree. Every auto-link anchor is a whole manager's *root*, so
-- the registry below is keyed by root identity only (one entry per manager),
-- not by every nested table.
--------------------------------------------------------------------------------

-- Weak-VALUED registry: root table -> the AutoLink manager that owns it. When a
-- manager is collected its entry vanishes (and the root key with it), so the
-- registry never pins a manager or its data alive. `UnregisterAutoLink` clears
-- entries promptly on Destroy.
local ROOT_TO_AUTOLINK_TM: { [{ [any]: any }]: TableManagerLike? } = setmetatable({}, { __mode = "kv" }) :: any

-- Returns the live AutoLink manager registered for `object`, or nil if none /
-- the registrant has been destroyed.
local function autoLinkManagerFor(object: any): TableManagerLike?
	local tm = ROOT_TO_AUTOLINK_TM[object]
	if tm == nil or tm._Destroyed then
		return nil
	end
	return tm
end

-- Depth-first search of every table reachable from `root`, invoking
-- `visit(node, path)` for each table node (including `root` itself, at path {}).
-- `path` is fresh per call (safe to keep). Cycle-guarded via a seen-set.
local function dfsTables(root: any, visit: (node: { [any]: any }, path: PathArray) -> ())
	if type(root) ~= "table" then
		return
	end
	local seen: { [any]: true } = {}
	local function recurse(node: any, path: PathArray)
		if type(node) ~= "table" or seen[node] then
			return
		end
		seen[node] = true
		visit(node, path)
		for key, child in node do
			if type(child) == "table" then
				recurse(child, PathHelpers.Append(path, key))
			end
		end
	end
	recurse(root, {})
end

-- Returns the path from `root` to the first node whose identity is `target`,
-- or nil if `target` is not reachable. `{}` when `root == target`.
local function findPathOf(root: any, target: any): PathArray?
	if type(root) ~= "table" then
		return nil
	end
	local seen: { [any]: true } = {}
	local function recurse(node: any, path: PathArray): PathArray?
		if type(node) ~= "table" or seen[node] then
			return nil
		end
		seen[node] = true
		if node == target then
			return path
		end
		for key, child in node do
			if type(child) == "table" then
				local found = recurse(child, PathHelpers.Append(path, key))
				if found ~= nil then
					return found
				end
			end
		end
		return nil
	end
	return recurse(root, {})
end

--[=[
	@within LinkGroup

	Downward pass: scans `tm`'s subtree at `path` (default root) for table nodes
	that are the root of *another* AutoLink manager, and links each at its found
	location. Recurses fully, so roots nested inside an already-found child are
	also linked (overlapping groups are fine — a manager can belong to many).
	Backs `Linker:Ensure`; also run at construction over the root.
]=]
local function findChildLinks(tm: TableManagerLike, path: Path<any>?)
	local basePath = resolveAnchorPath(path)
	local subtree = tm:Get(basePath, true)
	if type(subtree) ~= "table" then
		return
	end

	dfsTables(subtree, function(node, relPath)
		local child = autoLinkManagerFor(node)
		if child == nil or child == tm then
			return
		end
		local anchorPath = table.clone(basePath)
		for _, segment in relPath do
			table.insert(anchorPath, segment)
		end
		link { { tm, anchorPath }, { child } }
	end)
end

--[=[
	@within LinkGroup

	Upward pass for the child-created-after-parent case: if `tm`'s own root sits
	inside an already-registered AutoLink manager `Y`, link them at that location.
	Uses Y's proxy graph for the path when available, else a bounded DFS of Y.
]=]
local function findParentLinks(tm: TableManagerLike)
	local root = tm:Get({}, true)
	if type(root) ~= "table" then
		return
	end

	for _, parent in ROOT_TO_AUTOLINK_TM do
		if parent == tm or parent._Destroyed then
			continue
		end

		-- Cheap path first: ask the parent's proxy graph if it already knows
		-- `root`; fall back to a bounded DFS of the parent's raw tree.
		local anchorPath: PathArray? = nil
		local proxyManager = parent._proxyManager
		if proxyManager then
			local existing = proxyManager:GetProxyFromOriginal(root)
			if existing ~= nil then
				anchorPath = proxyManager:GetPath(existing)
			end
		end
		if anchorPath == nil then
			anchorPath = findPathOf(parent:Get({}, true), root)
		end

		if anchorPath ~= nil then
			link { { parent, anchorPath }, { tm } }
		end
	end
end

--[=[
	@within LinkGroup

	Registers `tm` as an AutoLink manager and forms any links implied by current
	tree topology — both directions: `tm` nested inside an existing manager
	(`findParentLinks`) and existing managers nested inside `tm` (`findChildLinks`).
	Registration happens last so the walks never match `tm` against itself.
]=]
local function registerAutoLink(tm: TableManagerLike)
	findParentLinks(tm)
	findChildLinks(tm, nil)
	ROOT_TO_AUTOLINK_TM[tm:Get({}, true)] = tm
end

-- Drops `tm`'s registry entry. Called from TableManager.Destroy.
local function unregisterAutoLink(tm: TableManagerLike)
	local root = tm:Get({}, true)
	if type(root) == "table" then
		ROOT_TO_AUTOLINK_TM[root] = nil
	end
end

--[=[
	@within LinkGroup

	O(1) direct write-path hook: if a *directly assigned* table value is the root
	of another AutoLink manager, link it at the write location. Only the assigned
	value itself is checked (no subtree scan) — roots buried inside a composite
	are the `Linker:Ensure` case. Called from `applyWrite` for AutoLink managers.
]=]
local function checkAutoLink(tm: TableManagerLike, writePath: PathArray, value: any)
	if type(value) ~= "table" then
		return
	end
	local other = autoLinkManagerFor(value)
	if other ~= nil and other ~= tm then
		link { { tm, writePath }, { other } }
	end
end

--------------------------------------------------------------------------------
--// Implicit sharing (Phase 3) //--
--
-- "Sharing a table identity = being linked." When enabled, any table reachable
-- in 2+ managers' trees (by identity, at ANY depth — not just manager roots like
-- AutoLink) is auto-linked at its location in each, so a change via one
-- propagates to the others through the SAME proven fan-out path as an explicit
-- `Link`. Discovery is by a global identity -> owners registry, populated as
-- tables enter a manager's tree (construction / table writes / inserts).
--
-- Gated by a runtime flag (default off) so existing behavior is unchanged until
-- validated; the Phase 0 shared-baseline goldens flip it on. Opacity is the
-- boundary: an opaque value (or an `OpaqueChildren` child) is not walked, so it
-- is never registered and never propagates — see `registerSubtree`.
--------------------------------------------------------------------------------

local IMPLICIT_SHARING = false

-- Identity -> set of managers that currently contain that table. Both levels are
-- weak-keyed so a collected table or manager drops out automatically (the index
-- never pins anything alive). Stale entries are harmless: `registerOwner`'s
-- auto-link is path-checked, so an owner that no longer holds the table is
-- skipped (its path resolves to nil).
local TABLE_TO_OWNERS: { [any]: { [any]: true } } = setmetatable({}, { __mode = "k" }) :: any

-- Resolves the live path to `target` within `manager`, preferring the proxy
-- graph (correct across array shifts / MoveTo / Swap) and falling back to a DFS
-- of the raw tree. nil if `target` is not (or no longer) in the manager.
local function pathOfTableIn(manager: TableManagerLike, target: any): PathArray?
	local proxyManager = manager._proxyManager
	if proxyManager then
		local existing = proxyManager:GetProxyFromOriginal(target)
		if existing ~= nil then
			local livePath = proxyManager:GetPath(existing)
			if livePath ~= nil then
				return livePath
			end
		end
	end
	return findPathOf(manager:Get({}, true), target)
end

-- Records `manager` as an owner of table `t`, auto-linking it with any existing
-- owners first. The link is path-checked on both sides, so a stale owner entry
-- (a manager that no longer holds `t`) is silently skipped.
local function registerOwner(manager: TableManagerLike, t: any)
	local owners = TABLE_TO_OWNERS[t]
	if owners == nil then
		owners = setmetatable({}, { __mode = "k" }) :: any
		TABLE_TO_OWNERS[t] = owners
	end
	if owners[manager] then
		return
	end
	for other in owners do
		if other ~= manager and not (other :: TableManagerLike)._Destroyed then
			local pOther = pathOfTableIn(other, t)
			local pSelf = pathOfTableIn(manager, t)
			if pOther ~= nil and pSelf ~= nil then
				link { { other, pOther }, { manager, pSelf } }
			end
		end
	end
	owners[manager] = true
end

-- Walks `value`'s table graph (cycle-guarded) registering each node as owned by
-- `manager`. Stops at the opacity boundary: an opaque table is neither registered
-- nor descended into, and the table children of an `OpaqueChildren` parent are
-- skipped — so opaque regions never participate in implicit sharing.
local function registerSubtree(manager: TableManagerLike, value: any)
	if not IMPLICIT_SHARING or type(value) ~= "table" then
		return
	end
	local ctx = manager._changeDetector:GetOpaqueCtx()
	local seen: { [any]: true } = {}
	local function recurse(node: any)
		if type(node) ~= "table" or seen[node] then
			return
		end
		if ctx ~= nil and ctx.isOpaque(node) then
			return
		end
		seen[node] = true
		registerOwner(manager, node)
		local childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(node)
		if childrenOpaque then
			return -- direct table children are opaque leaves: do not descend
		end
		for _, child in node do
			if type(child) == "table" then
				recurse(child)
			end
		end
	end
	recurse(value)
end

return {
	Link = link,
	GetOrCreateGroup = getOrCreateGroup,
	CheckDivergence = checkDivergence,
	OnRootReplaced = onRootReplaced,
	FanOutSet = fanOutSet,
	FanOutArrayOp = fanOutArrayOp,
	RegisterAutoLink = registerAutoLink,
	UnregisterAutoLink = unregisterAutoLink,
	FindChildLinks = findChildLinks,
	CheckAutoLink = checkAutoLink,
	FindPathOf = findPathOf,
	ResolveSharedShadow = resolveSharedShadow,
	RecomputeSharingForManager = recomputeSharingForManager,
	-- Implicit sharing (Phase 3)
	RegisterSubtree = registerSubtree,
	SetImplicitSharing = function(enabled: boolean)
		IMPLICIT_SHARING = enabled
	end,
	IsImplicitSharing = function(): boolean
		return IMPLICIT_SHARING
	end,
}
