--!strict
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
const BatchUtilsModule = require("./BatchUtils")
const ProxyManagerModule = require("./ProxyManager")
const SchemaNavigatorModule = require("./SchemaNavigator")
const LinkGroupModule = require("./LinkGroup")
const EmitterModule = require("./Emitter")
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
-- Path resolution helpers (exported — used by public Set / array methods)
-- ---------------------------------------------------------------------------

function Mutator.resolvePathFromPathOrProxy<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): PathArray<S>
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
	const parsedPath = Mutator.resolvePathFromPathOrProxy(self, pathOrProxy)
	const array = self:Get(parsedPath)
	assert(type(array) == "table", "Target is not a table")
	return parsedPath, array :: { any }
end

function Mutator.getParentOriginalAtPath<T, S>(self: TM_Internal<T>, parentPath: PathArray<S>, opName: string): {}
	local parentOriginal = if #parentPath == 0 then self._originalData else self:Get(parentPath)
	if type(parentOriginal) ~= "table" then
		error(`{opName} destination parent must be a table`)
	end
	return parentOriginal
end

-- ---------------------------------------------------------------------------
-- Deep clone (used by CopyTo)
-- ---------------------------------------------------------------------------

function Mutator.deepCloneValue(value: any, seen: { [any]: any }?): any
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
		clone[Mutator.deepCloneValue(k, memo)] = Mutator.deepCloneValue(v, memo)
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
	const insertPath: { any } = PathHelpers.Append(path :: any, index)
	const metadata = EmitterModule.makeSyntheticMetadata(self._originalData, insertPath, "added", index, newValue, nil)
	EmitterModule.fireArrayOperation(self, "ArrayInserted", path, insertPath, {
		Index = index,
		NewValue = newValue,
		Metadata = metadata,
	})
end

-- ---------------------------------------------------------------------------
-- Duplicate-reference policy (module-internal)
-- ---------------------------------------------------------------------------

local function resolveDuplicateReferencePolicy<T, S1, S2>(
	self: TM_Internal<T>,
	writePath: PathArray<S1>,
	existingPath: PathArray<S2>,
	value: any
): boolean
	if self._duplicateReferenceMode == "allow" then
		return true
	end
	const writePathStr = PathHelpers.PathToString(writePath)
	const existingPathStr = PathHelpers.PathToString(existingPath)
	const duplicateMessage =
		`Duplicate table reference detected: existing at {existingPathStr}, attempted write to {writePathStr}`
	if self._duplicateReferenceMode == "warn" then
		warn(duplicateMessage)
		return true
	end
	if self._duplicateReferenceMode == "move" then
		if self._isDuplicateMoveInProgress then
			return true
		end
		self._isDuplicateMoveInProgress = true
		local ok, moveErr = pcall(function()
			self:MoveTo(existingPath, writePath)
		end)
		self._isDuplicateMoveInProgress = false
		if not ok then
			error(`Failed to move duplicate table reference: {tostring(moveErr)}`, 2)
		end
		if self:Get(writePath) ~= value then
			error(
				`DuplicateReferenceMode 'move' is not fully implemented yet. Expected MoveTo to place the value at {writePathStr}`,
				2
			)
		end
		return false
	end
	if self._duplicateReferenceMode == "copy" then
		error("DuplicateReferenceMode 'copy' is not implemented yet", 2)
	end
	error(duplicateMessage, 2)
end

local function checkDuplicateTableWrite<T, S>(self: TM_Internal<T>, writePath: PathArray<S>, value: any): boolean
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		return true
	end
	const existingProxy = proxyManager:GetProxyFromOriginal(value)
	if existingProxy == nil then
		return true
	end
	const existingPath = proxyManager:GetPath(existingProxy)
	if existingPath == nil or PathHelpers.ArePathsEqual(existingPath, writePath) then
		return true
	end
	const isOrphan = self:Get(existingPath, true) ~= value
	if isOrphan then
		return true
	end
	return resolveDuplicateReferencePolicy(self, writePath, existingPath, value)
end

-- ---------------------------------------------------------------------------
-- Write core (exported)
-- ---------------------------------------------------------------------------

--[[
	The single proxy-free write core. `parsedPath` is the full path (including
	the final key); `value` must already be unwrapped
	(`ProxyManagerModule.Unwrap`). Order: duplicate-check → validation →
	array-append fast path → batch dirty-marking → snapshot/write/diff.
]]
function Mutator.applyWrite<T, S>(self: TM_Internal<T>, parsedPath: PathArray<S>, value: any)
	debug.profilebegin("applyWrite")
	const parentPath, key = PathHelpers.GetPathParentAndKey(parsedPath :: any)

	local current: any = self._originalData
	for _, segment in parentPath do
		if type(current) ~= "table" then
			error(`Path segment {segment} is not a table`)
		end
		current = current[segment]
	end
	if type(current) ~= "table" then
		error(`Path segment {key} is not a table`)
	end
	const parentTable: { [any]: any } = current

	if type(value) == "table" and self._proxyManager ~= nil then
		const shouldProceed = checkDuplicateTableWrite(self, parsedPath, value)
		if not shouldProceed then
			debug.profileend()
			return
		end
	end

	const ok, err = validateWrite(self, parsedPath, value)
	if not ok then
		if err then
			error(err, 2)
		end
		debug.profileend()
		return
	end

	-- Array-append fast path (key == length + 1): apply immediately and report.
	-- Only classify the parent table when the key is numeric; classification is O(n)
	-- and its result is never used for string/non-numeric keys.
	local isArray, arrayLength = false, 0
	if type(key) == "number" then
		isArray, arrayLength = ProxyManagerModule.ClassifyTable(parentTable)
	end
	if isArray and key == arrayLength + 1 then
		parentTable[key] = value
		onArrayAppended(self, parentPath, key, value)
		if self._autoLink and not self._suppressLinkFanOut then
			LinkGroupModule.CheckAutoLink(self, parsedPath, value)
		end
		debug.profileend()
		return
	end

	if self._batchDepth > 0 then
		const batch = self._batch
		if isArray and batch then
			ensureBatchPathTracking(batch, parentPath)
		end
		markBatchBranchDirty(batch, parentPath)
	end

	const oldValue = parentTable[key]
	const snapshot = self._changeDetector:CaptureSnapshot(self._originalData, parsedPath)
	parentTable[key] = value
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
		if self._autoLink then
			LinkGroupModule.CheckAutoLink(self, parsedPath, value)
		end
	end
	Mutator.pruneDetachedValue(self, oldValue, value)
	self._changeDetector:CheckForChanges(snapshot)
	debug.profileend()
end

--[[
	Replace the entire root table of the manager (the `Set({}, newRoot)` case).
	The root has no parent slot, so instead of `parentTable[key] = value` this
	swaps the manager's own root references and retargets the proxy graph, then
	fires the old→new diff via `CheckForChangesBetween`. `newRoot` must already be
	unwrapped (`ProxyManagerModule.Unwrap`). Order mirrors `applyWrite`:
	dup-check → validation → apply → link reconcile → diff.
]]
function Mutator.applyRootSet<T>(self: TM_Internal<T>, newRoot: any)
	if type(newRoot) ~= "table" then
		error("Cannot set the root to a non-table value; the root must remain a table")
	end

	const oldRoot = self._originalData
	if newRoot == oldRoot then
		return
	end

	if self._batchDepth > 0 then
		error("Cannot replace the root table inside a batch")
	end

	const rootPath = {} :: PathArray<any>

	-- Duplicate-reference guard: an already-managed table cannot silently become
	-- the root under the configured DuplicateReferenceMode.
	if type(newRoot) == "table" and self._proxyManager ~= nil then
		const shouldProceed = checkDuplicateTableWrite(self, rootPath, newRoot)
		if not shouldProceed then
			return
		end
	end

	const ok, err = validateWrite(self, rootPath, newRoot)
	if not ok then
		if err then
			error(err, 2)
		end
		return
	end

	-- Swap identity. `oldRoot` keeps its contents (we only repoint references and
	-- never mutate the old object), so the diff below sees the true prior state.
	self._originalData = newRoot
	self.Raw = newRoot
	if self._proxyManager ~= nil then
		self._proxyManager:RetargetRoot(oldRoot, newRoot)
	end

	-- Reconcile link groups: anchors that no longer resolve to their shared
	-- object are severed (the `{}` case of the ancestor-replacement handling).
	if not self._suppressLinkFanOut then
		LinkGroupModule.OnRootReplaced(self)
	end

	-- Fire change events for the full root diff. Passing `newRoot` as the root
	-- table makes root/ancestor listeners observe post-swap state.
	self._changeDetector:CheckForChangesBetween(oldRoot, newRoot, rootPath, newRoot)
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
