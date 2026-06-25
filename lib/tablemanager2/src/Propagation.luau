--!strict
--[=[
	@ignore
	@class Propagation

	Cross-manager change propagation via a global, identity-keyed **observer
	registry** — the successor to `LinkGroup`. "Sharing a table identity = being
	linked": any live table reachable (transparently) in two or more managers'
	trees is observed by all of them, and a write through one is fanned out
	(notify-only, never re-mutated) to the others, translated into each
	recipient's own path coordinates.

	There is no group object and no membership bookkeeping: the single source of
	truth is `OBSERVERS[liveTable] -> set of managers`. Linking is implicit
	(`RegisterSubtree` records observership as tables enter a tree) and opacity is
	the boundary (an opaque value/child is never registered, so it never
	propagates). Divergence needs no explicit severing: when a manager replaces a
	shared reference it simply stops resolving a live path to that identity, so
	dispatch to it is skipped (and its stale observer entry is dropped by the weak
	registry once the identity is unreferenced).

	Recipient-side dispatch (re-firing a manager's own listeners for an op already
	applied to the shared raw) lives on `TableManager._NotifyApplied`, which this
	module calls — it needs TableManager-internal emit helpers. This module owns
	*discovery* (who observes the changed region) and *translation* (the op into
	their coordinates), deduplicated so each recipient fires exactly once per
	change even when it shares several nested identities along the path.
]=]

const PathHelpers = require("./PathHelpers")
const TMTypes = require("./TMTypes")
const Diff = require("./Diff")

type PathArray<S = string> = PathHelpers.PathArray<S>
type DiffNode = Diff.DiffNode
type TableManagerLike = TMTypes.TableManagerLike
export type AppliedOp = TMTypes.AppliedOp
export type ArrayOpPayload = TMTypes.ArrayOpPayload

type opKind = "Set" | "ArrayInsert" | "ArrayRemove" | "ArraySet"

--------------------------------------------------------------------------------
--// Observer registry //--
--------------------------------------------------------------------------------

-- Identity -> set of managers that currently contain that table (transparently).
-- Both levels are weak-keyed so a collected table or manager drops out
-- automatically; the registry never pins anything alive. Stale entries (a
-- manager that no longer holds the table) are harmless: dispatch path-checks via
-- `pathOfTableIn` and skips any observer whose live path no longer resolves.
const OBSERVERS: { [any]: { [any]: true } } = setmetatable({}, { __mode = "k" }) :: any

-- Returns the path from `root` to the first node whose identity is `target`,
-- or nil if `target` is not reachable. `{}` when `root == target`.
const function findPathOf(root: any, target: any): PathArray?
	if type(root) ~= "table" then
		return nil
	end
	const seen: { [any]: true } = {}
	const function recurse(node: any, path: PathArray): PathArray?
		if type(node) ~= "table" or seen[node] then
			return nil
		end
		seen[node] = true
		if node == target then
			return path
		end
		for key, child in node do
			if type(child) == "table" then
				const found = recurse(child, PathHelpers.Append(path, key))
				if found ~= nil then
					return found
				end
			end
		end
		return nil
	end
	return recurse(root, {})
end

-- Resolves the live path to `target` within `manager`, preferring the proxy
-- graph (correct across array shifts / MoveTo / Swap) and falling back to a DFS
-- of the raw tree. nil if `target` is not (or no longer) in the manager.
const function pathOfTableIn(manager: TableManagerLike, target: any): PathArray?
	const proxyManager = manager._proxyManager
	if proxyManager then
		const existing = proxyManager:GetProxyFromOriginal(target)
		if existing ~= nil then
			const livePath = proxyManager:GetPath(existing)
			if livePath ~= nil then
				return livePath
			end
		end
	end
	return findPathOf(manager:Get({}, true), target)
end

-- Records `manager` as an observer of table `t`. When `t` gains a second live
-- observer, both managers are flagged `_sharesObservers` so `Coverage.IsTrackable`
-- forces their writes to flush (so a write by a member with no local listeners
-- still diffs and fans out). The flag is sticky (never reset): a manager that
-- later diverges just over-tracks slightly, which is correct (it fans out to no
-- one) and avoids a reverse-index for decrementing.
-- True when SOME manager currently observes `t` transparently (i.e. `t` was
-- registered as an observed node and that set is non-empty). This is the global
-- "is anyone transparent here?" signal the baseline keys its slot shape on:
-- because `registerSubtree` skips opaque nodes, `OBSERVERS[t]` contains exactly
-- the managers that see `t` transparently, so an empty/absent entry means `t` is
-- opaque to everyone (or unobserved).
const function isObserved(t: any): boolean
	const observers = OBSERVERS[t]
	return observers ~= nil and next(observers) ~= nil
end

const function registerOwner(manager: TableManagerLike, t: any)
	local observers = OBSERVERS[t]
	if observers == nil then
		observers = setmetatable({}, { __mode = "k" }) :: any
		OBSERVERS[t] = observers
	end
	if observers[manager] then
		return
	end
	for other in observers do
		if other ~= manager and not (other :: TableManagerLike)._Destroyed then
			manager._sharesObservers = true
			;(other :: TableManagerLike)._sharesObservers = true
		end
	end
	observers[manager] = true
end

--[=[
	@within Propagation

	Walks `value`'s table graph (cycle-guarded) recording each node as observed by
	`manager`. Stops at the opacity boundary: an opaque table is neither registered
	nor descended into, and the table children of an `OpaqueChildren` parent are
	skipped — so opaque regions never participate in implicit sharing. Called as
	tables enter a manager's tree (construction / table writes / array inserts /
	root replacement).
]=]
const function registerSubtree(manager: TableManagerLike, value: any)
	if type(value) ~= "table" then
		return
	end
	const ctx = manager._changeDetector:GetOpaqueCtx()
	const seen: { [any]: true } = {}
	const function recurse(node: any)
		if type(node) ~= "table" or seen[node] then
			return
		end
		if ctx ~= nil and ctx.isOpaque(node) then
			return
		end
		seen[node] = true
		registerOwner(manager, node)
		const childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(node)
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

--------------------------------------------------------------------------------
--// Fan-out (discovery + translation + dispatch) //--
--------------------------------------------------------------------------------

-- Delivers `appliedOp` to `recipient` in isolation: a throwing listener on one
-- recipient must not block delivery to the rest.
const function deliver(recipient: TableManagerLike, appliedOp: AppliedOp)
	const ok, err = pcall(recipient._NotifyApplied, recipient, appliedOp)
	if not ok then
		task.spawn(error, err, 0)
	end
end

-- Finds every OTHER manager that observes a table identity at or above
-- `path[1..maxPrefix]` in `self`'s live tree, deduplicated to the SHALLOWEST
-- shared identity per recipient. Returns `recipient -> { Anchor, RelStart }`
-- where `Anchor` is the recipient's live path to that identity and `RelStart` is
-- the index in `path` where the recipient-relative remainder begins.
const function collectRecipients(
	self: TableManagerLike,
	path: PathArray,
	maxPrefix: number
): { [TableManagerLike]: { Anchor: PathArray, RelStart: number } }
	const recipients: { [TableManagerLike]: { Anchor: PathArray, RelStart: number } } = {}
	local prefixTable: any = self.Raw
	for prefixLen = 0, maxPrefix do
		if type(prefixTable) ~= "table" then
			break
		end
		const observers = OBSERVERS[prefixTable]
		if observers ~= nil then
			for other in observers do
				const otherTM = other :: TableManagerLike
				if otherTM == self or otherTM._Destroyed or recipients[otherTM] then
					continue
				end
				const anchorInOther = pathOfTableIn(otherTM, prefixTable)
				if anchorInOther ~= nil then
					recipients[otherTM] = { Anchor = anchorInOther, RelStart = prefixLen + 1 }
				end
			end
		end
		if prefixLen < maxPrefix then
			prefixTable = prefixTable[path[prefixLen + 1]]
		end
	end
	return recipients
end

-- Appends `path[relStart..#path]` onto a clone of `anchor`.
const function translate(anchor: PathArray, path: PathArray, relStart: number): PathArray
	const out = table.clone(anchor)
	for i = relStart, #path do
		table.insert(out, path[i])
	end
	return out
end

--[=[
	@within Propagation

	Fan-out hook for "Set"-kind changes (called from the OnValueChanged emit).
	`path` is the changed location in `self`'s own coordinates. Propagates to
	every other observer of a shared table strictly above `path`, once each.
]=]
const function fanOutSet(self: TableManagerLike, path: PathArray, newValue: any, oldValue: any, diffNode: DiffNode?)
	-- Phase B reuse is only safe when the origin has no PER-MANAGER opacity (see
	-- `_NotifyApplied`); recipients re-check their own.
	const originHasNoOpacity = self._opaqueRegistries.Count == 0
	-- Only identities STRICTLY above `path` contain this change; `path` itself
	-- being shared is a reference-replacement (divergence), not interior fan-out.
	const recipients = collectRecipients(self, path, #path - 1)
	for recipient, info in recipients do
		deliver(recipient, {
			Kind = "Set",
			Path = translate(info.Anchor, path, info.RelStart),
			NewValue = newValue,
			OldValue = oldValue,
			Diff = diffNode,
			OriginHasNoOpacity = originHasNoOpacity,
		})
	end
end

--[=[
	@within Propagation

	Fan-out hook for array-op changes (called from `fireArrayOperation`).
	`basePath` is the array's own path in `self`'s coordinates. The array itself
	may be the shared identity, so identities at or above `basePath` are eligible.
]=]
const function fanOutArrayOp(
	self: TableManagerLike,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray,
	payload: ArrayOpPayload
)
	const kind: opKind = if eventName == "ArrayInserted"
		then "ArrayInsert"
		elseif eventName == "ArrayRemoved" then "ArrayRemove"
		else "ArraySet"
	const recipients = collectRecipients(self, basePath, #basePath)
	for recipient, info in recipients do
		deliver(recipient, {
			Kind = kind,
			Path = translate(info.Anchor, basePath, info.RelStart),
			NewValue = payload.NewValue,
			OldValue = payload.OldValue,
			Index = payload.Index,
		})
	end
end

--------------------------------------------------------------------------------
--// Introspection (TableManager:GetLinkedManagers / :IsLinkedWith) //--
--------------------------------------------------------------------------------

-- Returns the OTHER managers currently co-observing at least one live table
-- identity with `manager` (de-duplicated, excluding self and destroyed/stale).
const function getCoObservers(manager: TableManagerLike): { TableManagerLike }
	const result: { TableManagerLike } = {}
	const seen: { [any]: true } = {}
	const ctx = manager._changeDetector:GetOpaqueCtx()
	const root = manager:Get({}, true)
	const visited: { [any]: true } = {}
	const function recurse(node: any)
		if type(node) ~= "table" or visited[node] then
			return
		end
		-- Mirror `registerSubtree`'s opacity boundary: a region `manager` treats as
		-- opaque was never registered as observed, so it must not count as sharing.
		if ctx ~= nil and ctx.isOpaque(node) then
			return
		end
		visited[node] = true
		const observers = OBSERVERS[node]
		if observers ~= nil then
			for other in observers do
				const otherTM = other :: TableManagerLike
				if otherTM ~= manager and not otherTM._Destroyed and not seen[otherTM] then
					-- Only count it as live sharing if `other` still holds this identity.
					if pathOfTableIn(otherTM, node) ~= nil then
						seen[otherTM] = true
						table.insert(result, otherTM)
					end
				end
			end
		end
		const childrenOpaque = ctx ~= nil and ctx.hasOpaqueChildren(node)
		if childrenOpaque then
			return
		end
		for _, child in node do
			if type(child) == "table" then
				recurse(child)
			end
		end
	end
	recurse(root)
	return result
end

const function isLinkedWith(manager: TableManagerLike, other: TableManagerLike): boolean
	for _, co in getCoObservers(manager) do
		if co == other then
			return true
		end
	end
	return false
end

return {
	RegisterSubtree = registerSubtree,
	IsObserved = isObserved,
	FanOutSet = fanOutSet,
	FanOutArrayOp = fanOutArrayOp,
	FindPathOf = findPathOf,
	GetCoObservers = getCoObservers,
	IsLinkedWith = isLinkedWith,
}
