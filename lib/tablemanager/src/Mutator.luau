--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class Mutator

	The write core for TableManager. Owns path resolution, duplicate-reference
	checks, schema validation, the proxy-free write engine (`applyWrite`), proxy
	reparenting helpers, and the `pruneDetachedValue`/`shiftArrayKeys` post-write
	bookkeeping.
]=]

--// Imports //--
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./Batching/BatchUtils")
const ProxyManagerModule = require("./ProxyManager")
const OpaqueRegistryModule = require("./OpaqueRegistry")
const SchemaNavigatorModule = require("./SchemaNavigator")
const PropagationModule = require("./Propagation")
const EmitterModule = require("./Listening/Emitter")
const IgnoreTrieModule = require("./IgnoreTrie")
const CoverageModule = require("./Diffing/Coverage")
const CoalescedFlushModule = require("./Batching/CoalescedFlush")
const BaselineModule = require("./Baseline/Baseline")
const Diff = require("./Diffing/Diff")
const T = require("../T")
const TMTypes = require("./TMTypes")

--// Localize batch utils to avoid function call overhead //--
const markBatchBranchDirty = BatchUtilsModule.MarkBatchBranchDirty
const ensureBatchPathTracking = BatchUtilsModule.EnsureBatchPathTracking

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type Path<S> = PathHelpers.Path<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type TM_Internal<T> = TMTypes.TM_Internal<T>
type TableManagerLike = TMTypes.TableManagerLike
type ProxyManager<T> = ProxyManagerModule.ProxyManager<T>
type Proxy<T, S> = TMTypes.Proxy<T, S>

const Mutator = {}

-- ---------------------------------------------------------------------------
-- Path resolution helpers
-- ---------------------------------------------------------------------------

local function resolvePathFromPathOrProxy<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): PathArray<S>
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		if ProxyManagerModule.IsProxyValue(pathOrProxy) then
			error("GetProxy requires proxies (Config.EnableProxies = false for this TableManager)")
		end
		return PathHelpers.ParsePath(pathOrProxy :: Path<S>)
	end
	if proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<T, S>
		const potentialPath = proxyManager:GetPath(proxy)
		assert(potentialPath, "Proxy does not have a path")
		return potentialPath
	end
	return PathHelpers.ParsePath(pathOrProxy :: Path<S>)
end

function Mutator.resolveArrayForWrite<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): (PathArray<S>, { any })
	const parsedPath = resolvePathFromPathOrProxy(self, pathOrProxy)
	const array = self:Get(parsedPath)
	assert(type(array) == "table", "Target is not a table")
	return parsedPath, array :: { any }
end

local function getParentOriginalAtPath<T, S>(self: TM_Internal<T>, parentPath: PathArray<S>, opName: string): {}
	local parentOriginal = if #parentPath == 0 then self.Raw else self:Get(parentPath)
	if type(parentOriginal) ~= "table" then
		error(`{opName} destination parent must be a table`)
	end
	return parentOriginal
end

-- ---------------------------------------------------------------------------
-- Deep clone (used by CopyTo)
-- ---------------------------------------------------------------------------

local function deepCloneValue(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end
	const memo = seen or {}
	if memo[value] ~= nil then
		return memo[value]
	end
	const clone = {}
	memo[value] = clone
	for k, v in value do
		clone[deepCloneValue(k, memo)] = deepCloneValue(v, memo)
	end
	return clone
end

-- ---------------------------------------------------------------------------
-- Proxy reparenting helpers (used by MoveTo / CopyTo / Swap)
-- ---------------------------------------------------------------------------

export type ReparentRollback<T = { [any]: any }, S = string> = {
	Proxy: Proxy<T, S>,
	Parent: any?,
	Key: any?,
}

--[[
	Reparents the proxy backing `value` to `newParent`/`newKey`, returning a
	rollback handle. No-op when proxies are disabled, `value` is not a table,
	or it has no live proxy.
]]
function Mutator.reparentWithRollback<T>(
	proxyManager: ProxyManager<T>?,
	value: any,
	newParent: any,
	newKey: any
): ReparentRollback<T>?
	if proxyManager == nil or type(value) ~= "table" then
		return nil
	end
	const proxy = proxyManager:GetProxyFromOriginal(value)
	if proxy == nil then
		return nil
	end
	local oldParent: any? = nil
	local oldKey: any? = nil
	const existingMeta = proxyManager:GetMetadata(proxy)
	if existingMeta ~= nil then
		oldParent = existingMeta.Parent
		oldKey = existingMeta.Key
	end
	proxyManager:ReparentProxy(proxy, newParent, newKey)
	return {
		Proxy = proxy,
		Parent = oldParent,
		Key = oldKey,
	}
end

function Mutator.restoreReparent<T>(proxyManager: ProxyManager<T>?, rollback: ReparentRollback<T>?)
	if proxyManager == nil or rollback == nil then
		return
	end
	proxyManager:ReparentProxy(rollback.Proxy, rollback.Parent, rollback.Key)
end

-- ---------------------------------------------------------------------------
-- Array bookkeeping helpers (exported — used by _NotifyApplied and array methods)
-- ---------------------------------------------------------------------------

--[[
	Shifts Key metadata of proxies in `array` after an insert (+1) or remove (-1).
	No-op when proxies are disabled or `array` is not a table.
]]
function Mutator.shiftArrayKeys<T>(proxyManager: ProxyManager<T>?, array: any, fromIndex: number, delta: number)
	if proxyManager == nil or type(array) ~= "table" then
		return
	end
	proxyManager:ShiftKeys(array, fromIndex, delta)
end

--[[
	Evicts proxy bookkeeping for a value detached by a write. During a batch,
	the prune is deferred until Resume (so a value re-homed in the same window
	is spared by PruneOriginal's liveness guard).
]]
function Mutator.pruneDetachedValue(self: TableManagerLike, oldValue: any, newValue: any)
	if type(oldValue) ~= "table" or oldValue == newValue then
		return
	end
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		return
	end
	const batch = self._batch
	if self._batchDepth > 0 and batch then
		table.insert(batch.PendingPrunes, oldValue)
	else
		proxyManager:PruneOriginal(oldValue)
	end
end

-- ---------------------------------------------------------------------------
-- Batch tracking helper for array mutations
-- ---------------------------------------------------------------------------

--[[
	If in a batch, marks `parsedPath`'s array as tracked and its branch dirty.
	Returns `true` when in a batch (caller should skip immediate event firing).
]]
function Mutator.trackArrayMutation(self: TableManagerLike, parsedPath: PathArray): boolean
	if self._batchDepth > 0 then
		const batch = self._batch
		if batch then
			ensureBatchPathTracking(batch, parsedPath)
		end
		markBatchBranchDirty(batch, parsedPath)
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Write validation (module-internal, used only by applyWrite)
-- ---------------------------------------------------------------------------

local function validateWrite<T, S>(self: TM_Internal<T>, path: PathArray<S>, value: ValueAtPath<T, S>): (boolean, string?)
	if not self._schema then
		return true :: any
	end
	const ok, err = SchemaNavigatorModule.Validate(self._schema, path, value)
	if ok then
		return true :: any
	end
	const message = err or `Schema validation failed at {PathHelpers.PathToString(path)}`
	if self._onValidationFailed then
		self._onValidationFailed(path, value, message)
		return false, nil
	end
	return false, message
end

-- ---------------------------------------------------------------------------
-- Observation gate (module-internal, used only by applyWrite/onArrayAppended)
-- ---------------------------------------------------------------------------

-- See Coverage.luau: true if a write at `path` could be observed by anything
-- at all. False means the upcoming shadow-seed/diff is provably unobservable
-- and can be skipped. Kept as a local alias so call sites below stay unchanged.
const shouldTrackChangesAt = CoverageModule.IsTrackable

-- ---------------------------------------------------------------------------
-- Shadow seeding lives in `Baseline.SeedIfNeeded` (the baseline seam). Callers
-- here still own the trackable / opaque-ancestor gate before invoking it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Array-append notification (module-internal, used only by applyWrite)
-- ---------------------------------------------------------------------------

local function onArrayAppended<T, S>(self: TM_Internal<T>, path: PathArray<S>, index: number, newValue: any)
	if self._batchDepth > 0 then
		const batch = self._batch
		if batch then
			ensureBatchPathTracking(batch, path)
		end
		markBatchBranchDirty(batch, path)
		return
	end
	if not shouldTrackChangesAt(self, path) then
		-- Nothing diffs this append, but an OnApplied subscriber still needs to
		-- see it -- ship the value directly (no diff node in hand here).
		if self._appliedListeners[1] ~= nil then
			EmitterModule.emitReplicationOp(self, "ArrayInsert", path, newValue, index, nil)
		end
		return
	end
	const insertPath: { any } = PathHelpers.Append(path :: any, index)
	const metadata = EmitterModule.makeSyntheticMetadata(self.Raw, insertPath, "added", index, newValue, nil)
	-- The gate above already proved this path trackable; let the baseline
	-- sync inside skip re-deriving it.
	EmitterModule.fireArrayOperation(self, "ArrayInserted", path, insertPath, {
		Index = index,
		NewValue = newValue,
		Metadata = metadata,
	}, true)
end

-- ---------------------------------------------------------------------------
-- Duplicate-reference policy (module-internal)
--
-- A table written to a SECOND live location is, by default ("allow"), a
-- supported multi-location reference: both paths simply share identity, and
-- this write fires its own independent change events at the new path (the
-- proxy graph still reports a single "primary" anchor — see
-- `ProxyManager._originalToProxy`'s single-slot memo). "copy" opts OUT of
-- sharing for this one write by deep-cloning the value first.
-- ---------------------------------------------------------------------------

-- Returns the value to actually write: `value` unchanged (default), or a
-- fresh deep clone of it when `Config.DuplicateReferenceMode == "copy"`.
local function resolveDuplicateReferencePolicy<T>(self: TM_Internal<T>, value: any): any
	if self._duplicateReferenceMode == "copy" then
		return deepCloneValue(value)
	end
	return value
end

-- Returns the value to write at `writePath`: `value` unchanged unless it is
-- ALREADY live (non-orphaned) at a different path, in which case the
-- duplicate-reference policy above resolves what to write instead.
local function checkDuplicateTableWrite<T, S>(self: TM_Internal<T>, writePath: PathArray<S>, value: any): any
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		return value
	end
	const existingProxy = proxyManager:GetProxyFromOriginal(value)
	if existingProxy == nil then
		return value
	end
	const existingPath = proxyManager:GetPath(existingProxy)
	if existingPath == nil or PathHelpers.ArePathsEqual(existingPath, writePath) then
		return value
	end
	const isOrphan = self:Get(existingPath, true) ~= value
	if isOrphan then
		return value
	end
	return resolveDuplicateReferencePolicy(self, value)
end

--[[
	Replace the entire root table of the manager (the `Set({}, newRoot)` case).
	The root has no parent slot, so instead of `parentTable[key] = value` this
	swaps the manager's own root references and retargets the proxy graph, then
	fires the old→new diff via `CheckForChangesBetween`. `newRoot` must already be
	unwrapped (`ProxyManagerModule.Unwrap`). Order mirrors `applyWrite`:
	dup-check → validation → apply → link reconcile → diff.
]]
local function applyRootSet<T>(self: TM_Internal<T>, newRoot: any)
	if type(newRoot) ~= "table" then
		error("Cannot set the root to a non-table value; the root must remain a table")
	end

	const oldRoot = self.Raw
	if newRoot == oldRoot then
		return
	end

	if self._batchDepth > 0 then
		error("Cannot replace the root table inside a batch")
	end

	const rootPath = {} :: PathArray<any>

	-- If the new root is already live elsewhere in this manager, the duplicate-
	-- reference policy resolves what to actually use as the new root (itself, by
	-- default, or a fresh clone under DuplicateReferenceMode = "copy").
	if type(newRoot) == "table" and self._proxyManager ~= nil then
		newRoot = checkDuplicateTableWrite(self, rootPath, newRoot)
	end

	const ok, err = validateWrite(self, rootPath, newRoot)
	if not ok then
		if err then
			error(err, 2)
		end
		return
	end

	-- Seed the shadow from `oldRoot` BEFORE swapping `self.Raw` —
	-- `Baseline.SeedIfNeeded` reads "current live" off `self.Raw`,
	-- which is still `oldRoot` at this point.
	const trackable, diffMaxDepth = CoverageModule.ResolveWriteObservation(self, rootPath)
	if trackable then
		-- rootPath is always {}, so this never builds an intermediate spine
		-- (no opaque-ancestor risk; the root itself can never be opaque).
		BaselineModule.SeedIfNeeded(self, rootPath, oldRoot)
	end

	-- Swap identity. `oldRoot` keeps its contents (we only repoint references and
	-- never mutate the old object), so the diff below sees the true prior state.
	self.Raw = newRoot
	if self._proxyManager ~= nil then
		self._proxyManager:RetargetRoot(oldRoot, newRoot)
	end
	-- The baseline is a global identity-keyed pool; the root's identity just
	-- changed, so re-key its node from `oldRoot` to `newRoot` (interior nodes
	-- keep their identities). This must happen before the root flush below so
	-- `Baseline.Get({})` still finds the seeded pre-swap baseline.
	BaselineModule.RebindRoot(oldRoot, newRoot)

	-- Re-register the new root tree by identity. Observers of the OLD root that
	-- no longer resolve to it are skipped lazily at dispatch (see Propagation);
	-- no explicit divergence severing is needed.
	if not self._suppressLinkFanOut then
		PropagationModule.RegisterSubtree(self, newRoot)
	end

	-- Fire change events for the full root diff (shadow@{} vs the now-live
	-- newRoot), then reconcile the shadow to newRoot.
	if trackable then
		CoalescedFlushModule.Request(self, rootPath, diffMaxDepth or math.huge)
	elseif self._appliedListeners[1] ~= nil then
		-- Untracked, so nothing will diff this root replacement -- but an
		-- OnApplied subscriber still needs to see it -- ship the value directly.
		EmitterModule.emitReplicationOp(self, "Set", rootPath, newRoot, nil, nil)
	end
end

-- ---------------------------------------------------------------------------
-- Write core (exported)
-- ---------------------------------------------------------------------------

--[[
	The single proxy-free write core. `parsedPath` is the full path (including
	the final key); `value` must already be unwrapped
	(`ProxyManagerModule.Unwrap`). Order: duplicate-check → validation →
	array-append fast path → batched dirty-marking (no flush) OR
	shadow-seed/write/flush (immediate).

	`preResolvedParent` (internal, used by `applyRMW`) is the already-walked
	parent table for `parsedPath` — the value at `parsedPath[1..#parsedPath-1]`.
	Passing it skips the parent-chain walk below; the caller owns having
	validated the spine.
]]
function Mutator.applyWrite<T, S>(self: TM_Internal<T>, parsedPath: PathArray<S>, newValue: any, preResolvedParent: any?)
	const lastIdx = #parsedPath
	const key = parsedPath[lastIdx]

	-- Navigate to the parent table of the write in a single pass (no
	-- intermediate `parentPath` allocation — built lazily below only by the
	-- two branches that actually consume it). Each segment p[i] (1..lastIdx-1)
	-- is validated as a table immediately after being read, naming p[i] itself
	-- on failure — matching `TableManager.Set`'s own pre-walk convention (see
	-- the path-helper-methods error-message tests), now that `Set` short-
	-- circuits straight into this walk instead of doing its own first.
	local parentTable: any = preResolvedParent
	if parentTable == nil then
		parentTable = self.Raw
		for i = 1, lastIdx - 1 do
			const segment = parsedPath[i]
			parentTable = parentTable[segment]
			if type(parentTable) ~= "table" then
				error(`Path segment {segment} is not a table`)
			end
		end
	end

	-- If the value is a table already live at a different path, the duplicate-
	-- reference policy resolves what to actually write (itself, by default, or
	-- a fresh clone under DuplicateReferenceMode = "copy").
	if type(newValue) == "table" and self._proxyManager ~= nil then
		newValue = checkDuplicateTableWrite(self, parsedPath, newValue)
	end

	-- Verify the write against the schema, if one is configured.
	const ok, err = validateWrite(self, parsedPath, newValue)
	if not ok then
		if err then
			error(err, 2)
		end
		return
	end

	-- Ignored paths skip the diff/snapshot/event machinery entirely (the
	-- expensive part) — the value below is still written normally, so
	-- Get/Raw reflect it immediately; only change detection is short-circuited.
	const ignored = IgnoreTrieModule.IsPathIgnored(self._ignoreTrie, parsedPath)

	-- Array-append fast path (key == length + 1): apply immediately and report.
	-- "Is this an append" is fully decided by the nil guard + length check below
	-- (`#parentTable` is O(log n)) — no need to classify/enumerate the whole
	-- table just to detect this one shape.
	local isAppend = false
	if type(key) == "number" then
		isAppend = parentTable[key] == nil and key == #parentTable + 1
	end
	if isAppend then
		parentTable[key] = newValue
		if not ignored then
			const parentPath: PathArray<S> = table.move(parsedPath, 1, lastIdx - 1, 1, table.create(lastIdx - 1)) :: any
			onArrayAppended(self, parentPath, key, newValue)
		end
		if not self._suppressLinkFanOut then
			PropagationModule.RegisterSubtree(self, newValue)
		end
		return
	end

	if self._batchDepth > 0 then
		const batch = self._batch
		const parentPath: PathArray<S> = table.move(parsedPath, 1, lastIdx - 1, 1, table.create(lastIdx - 1)) :: any
		-- Only the batched path needs the full O(n) classification: it gates
		-- whether `parentPath` is tracked for Resume's LCS array-diff, which
		-- requires knowing the table is actually array-shaped (not just
		-- numeric-keyed) to avoid misdiffing sparse/dict tables as arrays.
		if type(key) == "number" and batch then
			const isArray = PathHelpers.ClassifyArray(parentTable)
			if isArray then
				ensureBatchPathTracking(batch, parentPath)
			end
		end
		markBatchBranchDirty(batch, parentPath)

		-- Batched writes don't flush per-op — Resume's two-phase flush owns
		-- firing for everything marked dirty above.
		const oldValue = parentTable[key]
		parentTable[key] = newValue
		if not self._suppressLinkFanOut then
			PropagationModule.RegisterSubtree(self, newValue)
		end
		Mutator.pruneDetachedValue(self, oldValue, newValue)
		return
	end

	const oldValue = parentTable[key]
	-- Trackability and the diff depth bound resolve together in one registry
	-- walk + one signal probe (`ResolveWriteObservation`); the depth is handed
	-- to the immediate flush below so `_doFlush` doesn't re-derive it.
	-- `diffMaxDepth == nil` means unbounded (see `Coverage.ResolveDiffMaxDepth`).
	local trackable = false
	local diffMaxDepth: number? = nil
	if not ignored then
		trackable, diffMaxDepth = CoverageModule.ResolveWriteObservation(self, parsedPath)
	end
	const ctx = if trackable then self._changeDetector:GetOpaqueCtx() else nil
	-- An opaque ancestor can't safely host a persistent shadow entry for a
	-- descendant path (see Coverage.PassesThroughOpaqueAncestor): fall back to
	-- a one-off diff using `oldValue` already read fresh above, instead of
	-- going through the shadow at all.
	const opaqueBypass = trackable and CoverageModule.PassesThroughOpaqueAncestor(self, parsedPath, ctx)

	-- Known-delta fast lane: a scalar->scalar transition at a trackable,
	-- opacity-free path in immediate flush mode IS its own complete one-node
	-- diff — `Diff.diff(oldScalar, newScalar)` can only ever return the
	-- added/removed/changed leaf synthesized below (or nil when equal). So
	-- build that node directly and dispatch it through the SAME queue and
	-- callbacks (`DispatchDiffNode`), skipping the general engine's baseline
	-- read, live re-read, `Diff.diff`, and full `Reconcile` re-copy. The
	-- baseline is instead patched incrementally (`ApplyLeafSet`), BEFORE
	-- dispatch, so a re-entrant flush at an ancestor during our callbacks
	-- already sees the new value and cannot double-report this transition.
	-- Coalesced mode is excluded: its deferred flush owns event timing, and
	-- a pending flush root may hold an unreported transition this lane's
	-- live-read `oldValue` would silently absorb.
	if
		trackable
		and not opaqueBypass
		and self._flushMode == "immediate"
		and self._pendingFlushRoot == nil
		and type(oldValue) ~= "table"
		and type(newValue) ~= "table"
	then
		if oldValue == newValue then
			-- No transition: the general engine would diff old == new and fire
			-- nothing. The raw write still happens (userdata with __eq can
			-- compare equal across distinct identities, and the new identity
			-- must land in the table exactly as before). Still seed the
			-- baseline (first-touch only) so a later explicit `Flush` at/above
			-- this path diffs quietly instead of misreading the
			-- never-materialized slot.
			BaselineModule.SeedIfNeeded(self, parsedPath, oldValue)
			parentTable[key] = newValue
			return
		end
		parentTable[key] = newValue
		-- RegisterSubtree and pruneDetachedValue are both no-ops for scalar
		-- old/new values — deliberately skipped.
		BaselineModule.ApplyLeafSet(self, parsedPath, newValue)
		-- Shapes mirror `Diff.diff`'s scalar tail exactly (childless, no `key`
		-- field) so `metadata.Diff` is indistinguishable from a diffed write.
		const diffNode: Diff.DiffNode = if oldValue == nil
			then { type = "added" :: "added", old = nil, new = newValue, children = nil }
			elseif newValue == nil then { type = "removed" :: "removed", old = oldValue, new = nil, children = nil }
			else { type = "changed" :: "changed", old = oldValue, new = newValue, children = nil }
		const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, parsedPath, oldValue)
		self._changeDetector:DispatchDiffNode(diffNode, parsedPath :: { any }, self.Raw :: any, oldSnapshot)
		return
	end

	if trackable and not opaqueBypass then
		BaselineModule.SeedIfNeeded(self, parsedPath, oldValue)
	end
	parentTable[key] = newValue
	if not self._suppressLinkFanOut then
		-- Implicit sharing: a newly-written table already observed by another
		-- manager becomes a shared region (divergence of any replaced reference
		-- is handled lazily at dispatch time — see Propagation).
		PropagationModule.RegisterSubtree(self, newValue)
	end
	Mutator.pruneDetachedValue(self, oldValue, newValue)
	if opaqueBypass then
		const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, parsedPath, oldValue)
		self._changeDetector:CheckForChangesBetween(oldValue, newValue, parsedPath, self.Raw, nil, oldSnapshot)
	elseif trackable then
		-- `nil` (unbounded) rides the plumbing as math.huge so `Request`/`_doFlush`
		-- can tell "precomputed as unbounded" apart from "no hint provided".
		CoalescedFlushModule.Request(self, parsedPath, diffMaxDepth or math.huge)
	elseif self._appliedListeners[1] ~= nil then
		-- Untracked, so nothing will diff this write -- but an OnApplied
		-- subscriber still needs to see it -- ship the value directly.
		EmitterModule.emitReplicationOp(self, "Set", parsedPath, newValue, nil, nil)
	end
end

--[[
	Shared non-wildcard read-modify-write core for `Update`/`Increment`/
	`UpdateKey`/`IncrementKey`: walks the parent chain ONCE, reads the current
	value, runs `transform` on it, and writes the result back through
	`applyWrite` with the already-resolved parent (so the chain is never walked
	twice — the old Get-then-Set shape's known inefficiency).

	The read walk mirrors `TableManager.Get`'s error convention exactly (it
	names the segment it was about to READ when the value so far is not a
	table), because that is the error today's Get-then-Set shape surfaced
	first. Once the read succeeds every intermediate is a table, so the write
	can never re-error on the spine.

	Returns `transform`'s raw result (pre-unwrap), matching what the public
	methods have always returned; the unwrapped form is what gets written.
]]
local function applyRMW<T, S>(
	self: TM_Internal<T>,
	parsedPath: PathArray<S>,
	transform: (oldValue: any) -> any
): any
	const lastIdx = #parsedPath

	-- Empty path: read-modify-write the root itself (today's Get-then-Set
	-- shape supported this as a root replacement; keep it working).
	if lastIdx == 0 then
		const newValue = transform(self.Raw)
		local unwrappedValue = ProxyManagerModule.Unwrap(newValue)
		unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)
		applyRootSet(self, unwrappedValue)
		return newValue
	end

	local parentTable: any = self.Raw
	for i = 1, lastIdx - 1 do
		const segment = parsedPath[i]
		if type(parentTable) ~= "table" then
			error(`Path segment {segment} is not a table`)
		end
		parentTable = parentTable[segment]
	end
	if type(parentTable) ~= "table" then
		error(`Path segment {parsedPath[lastIdx]} is not a table`)
	end

	const newValue = transform(parentTable[parsedPath[lastIdx]])
	local unwrappedValue = ProxyManagerModule.Unwrap(newValue)
	unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)
	Mutator.applyWrite(self, parsedPath, unwrappedValue, parentTable)
	return newValue
end

--[[
	Read-modify-write entry for `Update`/`Increment`. A non-wildcard path takes
	the single-walk core above. A wildcard path fans out to one read-modify-write
	per matched concrete path -- the value is re-read immediately before each
	write (not taken from the expansion snapshot) so a `transform` that touches
	other matched paths never operates on stale data, and `transform` also
	receives the keys matched by each `"*"` (left-to-right, one per wildcard)
	plus the fully concrete path. Multiple writes are batched so listeners see
	one coherent flush.

	Returns the scalar transform result; `nil` for wildcard paths.
]]
function Mutator.RMW<T, S>(
	self: TM_Internal<T>,
	parsedPath: PathArray<S>,
	transform: (oldValue: any, wildcardMatches: { any }?, path: { any }?) -> any
): any
	const wildcardIndex = PathHelpers.FindFirstWildcard(parsedPath)
	if wildcardIndex == nil then
		return applyRMW(self, parsedPath, transform)
	end

	const entries = PathHelpers.ExpandWildcardsFromRoot(self.Raw, parsedPath, wildcardIndex, false)
	if #entries == 1 then
		const entry = entries[1]
		self:Set(entry.Path, transform(self:Get(entry.Path, true), entry.WildcardMatches :: { any }, entry.Path))
	elseif #entries > 1 then
		self:Batch(function()
			for _, entry in entries do
				self:Set(entry.Path, transform(self:Get(entry.Path, true), entry.WildcardMatches :: { any }, entry.Path))
			end
		end)
	end
	return nil
end

-- Write orchestration for `Set` (see the facade doc for behavior).
-- `unwrappedValue` must already be unwrapped (`ProxyManagerModule.Unwrap` +
-- opaque registration); the facade owns that plus path parsing.
function Mutator.Set<T, S>(
	self: TM_Internal<T>,
	parsedPath: PathArray<S>,
	unwrappedValue: any,
	buildTablesDynamically: boolean?
)
	-- Empty path replaces the entire root table (identity swap + full diff).
	if #parsedPath == 0 then
		applyRootSet(self, unwrappedValue)
		return
	end

	-- Wildcard fan-out: expand "*" segments against the live data into N
	-- concrete paths, then apply N ordinary writes -- batched when N > 1 so
	-- listeners see one coherent flush. Deletes (nil) only target existing
	-- values; non-nil writes also create a missing literal final key on every
	-- matched parent, same as a plain Set would.
	const wildcardIndex = PathHelpers.FindFirstWildcard(parsedPath)
	if wildcardIndex ~= nil then
		if buildTablesDynamically then
			error(`Cannot build tables dynamically through a wildcard ("*") path segment`)
		end
		const entries = PathHelpers.ExpandWildcardsFromRoot(self.Raw, parsedPath, wildcardIndex, unwrappedValue ~= nil)
		if #entries == 1 then
			Mutator.applyWrite(self, entries[1].Path, unwrappedValue)
		elseif #entries > 1 then
			-- Fanning one table value to several paths: honor the duplicate-
			-- reference policy here, deterministically. The per-write check in
			-- `applyWrite` only catches duplicates that already have a proxy,
			-- which a value first written during this same fan-out does not.
			const clonePerPath = type(unwrappedValue) == "table"
				and self._proxyManager ~= nil
				and self._duplicateReferenceMode == "copy"
			self:Batch(function()
				for i, entry in entries do
					const valueToWrite = if clonePerPath and i > 1 then deepCloneValue(unwrappedValue) else unwrappedValue
					Mutator.applyWrite(self, entry.Path, valueToWrite)
				end
			end)
		end
		return
	end

	-- Fast path: a non-nil write with no dynamic-build request has no behavior
	-- left in the loop below beyond what `applyWrite`'s own parent-chain walk
	-- already performs (including reporting the identical "Path segment X is
	-- not a table" error) — so skip straight to the single walk instead of
	-- walking the parent chain twice.
	if unwrappedValue ~= nil and not buildTablesDynamically then
		Mutator.applyWrite(self, parsedPath, unwrappedValue)
		return
	end

	-- Only build intermediate tables when setting non-nil values; removing (nil)
	-- doesn't need them.
	const shouldBuild = buildTablesDynamically and unwrappedValue ~= nil

	local parent: any = self.Raw
	for i = 1, #parsedPath - 1 do
		const nextValue = parent[parsedPath[i]]
		if type(nextValue) ~= "table" then
			if not shouldBuild then
				-- Reaching here always means `unwrappedValue == nil`: the fast path
				-- above routes every non-nil write (when dynamic build is off) into
				-- `applyWrite`, which raises the "Path segment X is not a table"
				-- error itself, and `shouldBuild` is only false for a non-nil value
				-- when build is off. So this is the "set a nonexistent path to nil"
				-- case, which is already a no-op.
				return
			end

			-- Build intermediate tables for the remainder of the path, then apply the write.
			local nested: any = unwrappedValue
			for j = #parsedPath, i + 1, -1 do
				nested = { [parsedPath[j]] = nested }
			end
			const subPath = table.move(parsedPath, 1, i, 1, table.create(i))
			Mutator.applyWrite(self, subPath, nested)
			return
		end
		parent = nextValue
	end

	Mutator.applyWrite(self, parsedPath, unwrappedValue)
end

-- `MoveTo` core (see the facade doc): batched unset+set with the backing proxy
-- reparented so references survive, rolled back if either write fails.
function Mutator.MoveTo<T, S1, S2>(
	self: TM_Internal<T>,
	currentPath: Path<S1> | Proxy<T, S1>,
	newPath: Path<S2> | Proxy<T, S2>
)
	const sourcePath: PathArray<S1> = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath: PathArray<S2> = resolvePathFromPathOrProxy(self, newPath)

	if #sourcePath == 0 or #targetPath == 0 then
		error("MoveTo cannot move the root table")
	end

	if PathHelpers.ArePathsEqual(sourcePath, targetPath) then
		return
	end

	if PathHelpers.IsPrefixPath(sourcePath, targetPath) then
		error("MoveTo cannot move a table into one of its descendants")
	end

	const sourceValue = self:Get(sourcePath :: Path<S1>)
	if type(sourceValue) ~= "table" then
		error("MoveTo source must be a table")
	end

	const targetParentPath, targetKey = PathHelpers.GetPathParentAndKey(targetPath)
	const targetParentOriginal = getParentOriginalAtPath(self, targetParentPath, "MoveTo")

	const rollback = Mutator.reparentWithRollback(self._proxyManager, sourceValue, targetParentOriginal, targetKey)

	const ok, moveErr = pcall(function()
		self:Batch(function()
			self:Set(targetPath, sourceValue)
			self:Set(sourcePath, nil :: any)
		end)
	end)

	if not ok then
		Mutator.restoreReparent(self._proxyManager, rollback)
		error(moveErr, 2)
	end
end

-- `CopyTo` core (see the facade doc): writes a fresh deep clone, so the two
-- paths never share table identity.
function Mutator.CopyTo<T, S1, S2>(self: TM_Internal<T>, currentPath: Path<S1> | Proxy<T, S1>, newPath: Path<S2>)
	const sourcePath = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath = resolvePathFromPathOrProxy(self, newPath)

	if #targetPath == 0 then
		error("CopyTo cannot set the root table")
	end

	if PathHelpers.ArePathsEqual(sourcePath, targetPath) then
		return
	end

	-- Validate destination parent before any mutation.
	const targetParentPath: { any } = table.clone(targetPath :: any)
	table.remove(targetParentPath)
	getParentOriginalAtPath(self, targetParentPath, "CopyTo")

	const sourceValue = self:Get(sourcePath)
	const copiedValue = deepCloneValue(sourceValue)
	self:Set(targetPath, copiedValue)
end

-- `Swap` core (see the facade doc): one batched pair of writes, both backing
-- proxies reparented, rolled back when either write fails.
function Mutator.Swap<T, S1, S2>(self: TM_Internal<T>, a: Path<S1> | Proxy<T, S1>, b: Path<S2> | Proxy<T, S2>)
	const pathA = resolvePathFromPathOrProxy(self, a)
	const pathB = resolvePathFromPathOrProxy(self, b)

	if #pathA == 0 or #pathB == 0 then
		error("Swap cannot target the root table")
	end

	if PathHelpers.ArePathsEqual(pathA, pathB) then
		return
	end

	if PathHelpers.IsPrefixPath(pathA, pathB) or PathHelpers.IsPrefixPath(pathB, pathA) then
		error("Swap cannot swap ancestor/descendant paths")
	end

	const parentPathA, keyA = PathHelpers.GetPathParentAndKey(pathA)
	const parentPathB, keyB = PathHelpers.GetPathParentAndKey(pathB)
	const parentOriginalA = getParentOriginalAtPath(self, parentPathA, "Swap")
	const parentOriginalB = getParentOriginalAtPath(self, parentPathB, "Swap")

	const valueA = self:Get(pathA)
	const valueB = self:Get(pathB)

	const rollbackA = Mutator.reparentWithRollback(self._proxyManager, valueA, parentOriginalB, keyB)
	const rollbackB = Mutator.reparentWithRollback(self._proxyManager, valueB, parentOriginalA, keyA)

	const ok, swapErr = pcall(function()
		self:Batch(function()
			self:Set(pathA, valueB)
			self:Set(pathB, valueA)
		end)
	end)

	if not ok then
		Mutator.restoreReparent(self._proxyManager, rollbackA)
		Mutator.restoreReparent(self._proxyManager, rollbackB)
		error(swapErr, 2)
	end
end

-- ---------------------------------------------------------------------------
-- Array schema validation helper (exported — used by ArrayInsert)
-- ---------------------------------------------------------------------------

--[[
	Validates a value being inserted into the array at `arrayPath` against the
	schema's element check, if one is configured. Fires `onValidationFailed` and
	returns `false` (caller should return early) on failure.
]]
function Mutator.validateArrayInsert<T, S>(self: TM_Internal<T>, arrayPath: PathArray<S>, value: any): boolean
	if not self._schema then
		return true
	end
	const arrayCheck = SchemaNavigatorModule.Navigate(self._schema, arrayPath)
	if not arrayCheck then
		return true
	end
	const arrayMeta = T.GetMeta(arrayCheck)
	if not arrayMeta or arrayMeta.kind ~= "array" then
		return true
	end
	const ok, err = arrayMeta.valueCheck(value)
	if ok then
		return true
	end
	const message = err or `Schema validation failed at {PathHelpers.PathToString(arrayPath)}`
	if self._onValidationFailed then
		self._onValidationFailed(arrayPath, value, message)
		return false
	end
	error(message, 2)
end

return Mutator
