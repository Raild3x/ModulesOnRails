--!strict
--[=[
	@class TableManager

	TableManager is a wrapper around luau tables that provide easy and automatic 
	change tracking, validation, and listener management. TableManager is designed
	to handle the bulk of your volatile data management needs, emitting detailed change 
	events and snapshots for any changes made to the managed table or its descendants — all 
	without needing to manually fire events or manage listener connections.

	### What is TableManager good for?
	- Tracking changes to nested tables and arrays.
	- Emitting detailed change events for any modifications.
	- Providing snapshots of the current state for debugging or synchronization.
	- Integrating with ProfileStore for easy management of player data.

	### What TableManager is Not
	- TableManager is not a state management library, and does not include any opinionated
	features for structuring your data, managing side effects, or integrating with
	other systems. It is purely a change tracking and notification system for tables.
	- TableManager is not intended to be used with tables that are mutated by external code 
	without going through TableManager's API.
	- TableManager is not meant for data with a high frequency of updates. It focuses on providing
	detailed and accurate change information, which can be expensive to generate for large or 
	rapidly changing data.

	
	### Usage

	```lua
	local manager = TableManager.new({
		Player = { Name = "Alice", Health = 100 },
		Inventory = { "Sword", "Shield" },
	})

	-- Fire when a specific field changes.
	manager:OnValueChange("Player.Health", function(health, oldHealth)
		print(`health: {oldHealth} -> {health}`)
	end)

	-- Fire for any change under a subtree (the field OR a descendant).
	manager:OnChange("Player", function(_, _, metadata)
		print("player changed at:", table.concat(metadata.OriginPath, "."))
	end)

	manager:Set("Player.Health", 80)
	-- prints "health: 100 -> 80"
	--        "player changed at: Player.Health"

	-- Array contents have their own methods and events.
	manager:OnArrayInsert("Inventory", function(index, item)
		print(`picked up {item} (slot {index})`)
	end)
	manager:ArrayInsert("Inventory", "Potion") -- prints "picked up Potion (slot 3)"
	```

	## Good Practices
	- If you have very large datastructures, consider utilizing Opaque 
	 wrappers to avoid deep cloning and unnecessary change detection.
	- Avoid mixed tables. This is general good practice.
	- Utilize pure string keys so the linter can try to infer your types.
]=]

--// Imports //--
-- External dependencies
const T = require("../T")
const Signal = require("../Signal")
const Janitor = require("../Janitor")
const Promise = require("../Promise")
-- Internal dependencies
const Types = require("./TMTypes")
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./Batching/BatchUtils")
const BatchFlushModule = require("./Batching/BatchFlush")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./Listening/ListenerRegistry")
const ChangeDetectorModule = require("./Diffing/ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const PropagationModule = require("./Propagation")
const EmitterModule = require("./Listening/Emitter")
const MutatorModule = require("./Mutator")
const OpaqueRegistryModule = require("./OpaqueRegistry")
const IgnoreTrieModule = require("./IgnoreTrie")
const CoverageModule = require("./Diffing/Coverage")
const ForMapModule = require("./ForMap")
const CoalescedFlushModule = require("./Batching/CoalescedFlush")
const BaselineModule = require("./Baseline/Baseline")

--// Types //--
type Path<S> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type KeyAtPath<T, S> = PathHelpers.KeyAtPath<T, S>
type ElementAtPath<T, S> = PathHelpers.ElementAtPath<T, S>
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type SchemaCheck = SchemaNavigatorModule.Check
type BatchState = BatchUtilsModule.BatchState
type Promise<T...> = Promise.TypedPromise<T...>
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
type Janitor = Janitor.Janitor
type table = { [any]: any }

export type Proxy<T, S> = Types.Proxy<T, S>

export type AppliedOp = Types.AppliedOp

export type DuplicateReferenceMode = Types.DuplicateReferenceMode
export type TableManagerConfig = Types.TableManagerConfig
export type ForOptions = Types.ForOptions
export type TableManager<T = { [any]: any }> = Types.TableManager<T>

export type OpaqueWrapper<T> = Types.OpaqueWrapper<T>

export type TM_Internal<T = { [any]: any }> = Types.TM_Internal<T>
type ProxyManager<T> = ProxyManagerModule.ProxyManager<T>

--// Constants //--
-- Accepted string values for each configurable mode, used to validate the
-- static-default setters below.
const VALID_FIRE_MODES = { immediate = true, deferred = true, bindable = true, coalesced = true }
const VALID_FLUSH_MODES = { immediate = true, coalesced = true }
const VALID_DUPLICATE_REFERENCE_MODES = { allow = true, copy = true }

-- Lowercases and validates a mode string against `valid`, erroring with the
-- allowed options if it is not recognized. `label` names the mode in messages.
const function normalizeModeString(value: any, valid: { [string]: boolean }, label: string): string
	assert(type(value) == "string", `{label} must be a string, got {typeof(value)}`)
	const lowered = (value :: string):lower()
	if not valid[lowered] then
		const options = {}
		for option in valid do
			table.insert(options, `"{option}"`)
		end
		table.sort(options)
		error(`Invalid {label} "{value}". Must be one of: {table.concat(options, ", ")}`, 3)
	end
	return lowered
end

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const Static = {}
const TableManager = {}
const TableManager_MT = { __index = TableManager }

Static.T = T

--------------------------------------------------------------------------------
--// Static Default Config //--
--------------------------------------------------------------------------------
-- These class-level defaults are read once, at construction time, whenever the
-- corresponding `TableManagerConfig` field is omitted. Changing a default only
-- affects TableManagers created afterwards -- never existing instances.

--[=[
	@interface ConfigDefaults
	@within TableManager
	.ListenerFireMode ListenerFireMode?
	.SignalFireMode SignalFireMode?
	.FlushMode FlushMode?
	.DuplicateReferenceMode DuplicateReferenceMode?
	The subset of [TableManagerConfig] whose defaults can be overridden at the
	class level via [TableManager.SetDefaults]. Every field is optional; only the
	fields you provide are changed.
]=]
export type ConfigDefaults = {
	ListenerFireMode: ListenerRegistryModule.FireMode?,
	SignalFireMode: Types.SignalFireMode?,
	FlushMode: Types.FlushMode?,
	DuplicateReferenceMode: DuplicateReferenceMode?,
}

--[=[
	@tag Static
	@readonly
	@prop TableManager.DefaultListenerFireMode ListenerFireMode
	@within TableManager
	The [ListenerFireMode] used when `TableManagerConfig.ListenerFireMode` is
	omitted: it controls how listener callbacks (`OnChange`, `OnValueChange`,
	`Observe`, `OnKey*`, `OnArray*`, `For*`) are scheduled when they fire.
	Defaults to `"bindable"`.

	Read at construction time only -- changing it affects only TableManagers
	created afterwards. Read-only -- use [TableManager.SetDefaults] to change it.
]=]
Static.DefaultListenerFireMode = "bindable" :: ListenerRegistryModule.FireMode

--[=[
	@tag Static
	@readonly
	@prop TableManager.DefaultSignalFireMode SignalFireMode
	@within TableManager
	The [SignalFireMode] used when `TableManagerConfig.SignalFireMode` is omitted:
	it controls how the public per-change Signals (`ValueChanged`, `Changed`,
	`ArrayInserted`, etc.) are scheduled when they fire. Defaults to `"bindable"`.

	Read at construction time only -- changing it affects only TableManagers
	created afterwards. Read-only -- use [TableManager.SetDefaults] to change it.
]=]
Static.DefaultSignalFireMode = "bindable" :: Types.SignalFireMode

--[=[
	@tag Static
	@readonly
	@prop TableManager.DefaultFlushMode FlushMode
	@within TableManager
	The [FlushMode] used when `TableManagerConfig.FlushMode` is omitted: it
	controls whether pending changes are flushed immediately or coalesced to the
	end of the frame. Defaults to `"immediate"`.

	Read at construction time only -- changing it affects only TableManagers
	created afterwards. Read-only -- use [TableManager.SetDefaults] to change it.
]=]
Static.DefaultFlushMode = "immediate" :: Types.FlushMode

--[=[
	@tag Static
	@readonly
	@prop TableManager.DefaultDuplicateReferenceMode DuplicateReferenceMode
	@within TableManager
	The [DuplicateReferenceMode] used when
	`TableManagerConfig.DuplicateReferenceMode` is omitted: it controls whether
	writing the same table to more than one path shares its identity (`"allow"`)
	or stores an independent copy (`"copy"`). Defaults to `"allow"`.

	Read at construction time only -- changing it affects only TableManagers
	created afterwards. Read-only -- use [TableManager.SetDefaults] to change it.
]=]
Static.DefaultDuplicateReferenceMode = "allow" :: DuplicateReferenceMode

--[=[
	@tag Static
	@within TableManager
	@function SetDefaults
	@param defaults ConfigDefaults

	Overrides the class-level construction defaults for the fields you provide,
	mirroring the corresponding [TableManagerConfig] keys. Only the fields present
	in `defaults` change; omitted fields keep their current value. Each value is
	validated and an unrecognized mode string errors without changing any default.

	Because the defaults are read at construction time, this affects only
	TableManagers created afterwards -- never existing instances.

	```lua
	TableManager.SetDefaults({
		FlushMode = "coalesced",
		SignalFireMode = "deferred",
	})
	```
]=]
function Static.SetDefaults(defaults: ConfigDefaults)
	assert(type(defaults) == "table", `SetDefaults expects a table, got {typeof(defaults)}`)
	if defaults.ListenerFireMode ~= nil then
		Static.DefaultListenerFireMode = normalizeModeString(defaults.ListenerFireMode, VALID_FIRE_MODES, "ListenerFireMode") :: ListenerRegistryModule.FireMode
	end
	if defaults.SignalFireMode ~= nil then
		Static.DefaultSignalFireMode = normalizeModeString(defaults.SignalFireMode, VALID_FIRE_MODES, "SignalFireMode") :: Types.SignalFireMode
	end
	if defaults.FlushMode ~= nil then
		Static.DefaultFlushMode = normalizeModeString(defaults.FlushMode, VALID_FLUSH_MODES, "FlushMode") :: Types.FlushMode
	end
	if defaults.DuplicateReferenceMode ~= nil then
		Static.DefaultDuplicateReferenceMode = normalizeModeString(defaults.DuplicateReferenceMode, VALID_DUPLICATE_REFERENCE_MODES, "DuplicateReferenceMode") :: DuplicateReferenceMode
	end
end

-- Write-core helpers live in Mutator.luau; local aliases keep call sites unchanged.
const resolvePathFromPathOrProxy = MutatorModule.resolvePathFromPathOrProxy
const resolveArrayForWrite = MutatorModule.resolveArrayForWrite
const getParentOriginalAtPath = MutatorModule.getParentOriginalAtPath
const applyWrite = MutatorModule.applyWrite
const applyRootSet = MutatorModule.applyRootSet
const pruneDetachedValue = MutatorModule.pruneDetachedValue
const shiftArrayKeys = MutatorModule.shiftArrayKeys
const reparentWithRollback = MutatorModule.reparentWithRollback
const restoreReparent = MutatorModule.restoreReparent
const deepCloneValue = MutatorModule.deepCloneValue
const trackArrayMutation = MutatorModule.trackArrayMutation
const applyRMW = MutatorModule.applyRMW

-- Emit/notify core lives in Emitter.luau; local aliases keep call sites unchanged.
const emitInserted = EmitterModule.emitInserted
const emitRemoved = EmitterModule.emitRemoved
const emitSet = EmitterModule.emitSet

-- Shared For/Map reconcile drivers live in ForMap.luau; local aliases keep call sites unchanged.
const makeKeyedReconciler = ForMapModule.makeKeyedReconciler
const makeValueReconciler = ForMapModule.makeValueReconciler

-----------------------------------------------------------------------------------
--// Constructor //--
-----------------------------------------------------------------------------------

const function validateInitialSchema<T>(self: TM_Internal<T>)
	if self._schema then
		const ok, err = SchemaNavigatorModule.Validate(self._schema, {}, self.Raw)
		if not ok then
			const message = err or "Schema validation failed at <root>"
			if self._onValidationFailed then
				self._onValidationFailed({}, self.Raw, message)
			end
			error(message, 2)
		end
	end
end

const function normalizeSignalFireMode(mode: Types.SignalFireMode?): Types.SignalFireMode
	return if mode == nil then Static.DefaultSignalFireMode else (mode :: any):lower() :: Types.SignalFireMode
end

const function initProxyManager<T>(self: TM_Internal<T>, resolvedConfig: TableManagerConfig): ProxyManager<T>?
	const enableProxies = resolvedConfig.EnableProxies ~= false
	if not enableProxies and resolvedConfig.DuplicateReferenceMode ~= nil then
		warn("DuplicateReferenceMode has no effect when Config.EnableProxies = false")
	end
	return if enableProxies then ProxyManagerModule.new(self.Raw) else nil
end

const function wireProxyWriteHandler<T>(self: TM_Internal<T>): Proxy<T, "">?
	const proxyManager = self._proxyManager
	if not proxyManager then return end
	proxyManager:SetWriteHandler(function(path: PathArray, value: any)
		applyWrite(self, path, value)
	end)
	return proxyManager:CreateProxy(self.Raw, nil, nil)
end

--[=[
	@within TableManager
	@tag Static
	@function new

	Creates a new TableManager instance.

	@param initialData table -- The initial table data to manage. Must be a table.
	@param config TableManagerConfig? -- Optional configuration for the TableManager.
	@return TableManager -- The newly created TableManager instance.
]=]
function Static.new<T>(initialData: T, config: TableManagerConfig?): TableManager<T>
	debug.profilebegin("TM.new")
	const self: TM_Internal<T> = (setmetatable({}, TableManager_MT) :: any) :: TM_Internal<T>
	const resolvedConfig: TableManagerConfig = config or {} :: { [string]: any? }
	const duplicateReferenceMode: DuplicateReferenceMode = resolvedConfig.DuplicateReferenceMode or Static.DefaultDuplicateReferenceMode
	
	assert(type(initialData) == "table", "Initial data must be a table")
	-- Store original data
	self.Raw = initialData
	self._schema = resolvedConfig.Schema
	self._onValidationFailed = resolvedConfig.OnValidationFailed
	self._duplicateReferenceMode = duplicateReferenceMode
	
	-- Validate initial data against the root schema at construction time.
	validateInitialSchema(self)
	
	-- Batch state (reset at start of each Suspend/Resume cycle)
	self._batchDepth = 0
	self._batch = nil
	

	self._janitor = Janitor.new()
	
	self._opaqueRegistries = OpaqueRegistryModule.NewRegistries(resolvedConfig.FrozenTablesAreOpaque)
	self._ignoreTrie = IgnoreTrieModule.new()
	for _, ignoredPath in resolvedConfig.IgnoredPaths or {} do
		IgnoreTrieModule.SetPathIgnored(self._ignoreTrie, ignoredPath, true)
	end
	
	-- Initialize subsystems
	self._proxyManager = initProxyManager(self, resolvedConfig)
	self._listenerRegistry = ListenerRegistryModule.new {
		DebugMode = false,
		FireMode = resolvedConfig.ListenerFireMode or Static.DefaultListenerFireMode,
	}
	self._signalFireMode = normalizeSignalFireMode(resolvedConfig.SignalFireMode)
	self._flushMode = resolvedConfig.FlushMode or Static.DefaultFlushMode
	self._pendingFlushRoot = nil
	self._coalescedFlushScheduled = false
	self._appliedListeners = {}
	self.Proxy = wireProxyWriteHandler(self)
	
	-- Initialize signals (fire once per change)
	self.ValueChanged = Signal.new() :: any
	self.KeyAdded = Signal.new() :: any
	self.KeyRemoved = Signal.new() :: any
	self.KeyChanged = Signal.new() :: any
	self.ArrayInserted = Signal.new() :: any
	self.ArrayRemoved = Signal.new() :: any
	self.ArraySet = Signal.new() :: any
	
	-- Ancestor-walk spine primer: skips no-listener levels AND fires the rest by
	-- node index instead of re-walking from the root. Primed at fire time
	-- (re-entrancy-safe) and unprimed via the returned thunk. See
	-- `ListenerRegistry.PrimeAncestorSpine`. `endSpine` is built once and reused so
	-- the per-write resolver allocates nothing.
	const registry = self._listenerRegistry
	const endSpine = function()
		registry:EndAncestorSpine()
	end
	self._changeDetector = ChangeDetectorModule.new(
		EmitterModule.makeChangeDetectorCallbacks(self :: any) :: any,
		nil,
		self._opaqueRegistries,
		self._ignoreTrie,
		function(basePath: PathArray)
			return registry:PrimeAncestorSpine(basePath), endSpine
		end
	)

	PropagationModule.RegisterSubtree(self, self.Raw)

	debug.profileend()
	return self :: any
end

--------------------------------------------------------------------------------
--// Setter/Accessor Methods //--
--------------------------------------------------------------------------------

--[[
	Expands a wildcard path against the live raw data. Segments before
	`wildcardIndex` are literal and keep exact-path semantics (a non-table value
	along the prefix errors, same as `Set`/`Get`); segments from `wildcardIndex`
	on are expanded with match-what-exists semantics (branches that cannot
	resolve are skipped). Returns a complete snapshot of matched concrete paths,
	safe to iterate while mutating the tree.
]]
const function resolveWildcardExpansion<T>(
	self: TM_Internal<T>,
	parsedPath: PathArray,
	wildcardIndex: number,
	includeMissingFinal: boolean
): { PathHelpers.WildcardExpansion }
	local node: any = self.Raw
	for i = 1, wildcardIndex - 1 do
		const segment = parsedPath[i]
		node = node[segment]
		if type(node) ~= "table" then
			error(`Path segment {segment} is not a table`)
		end
	end
	return PathHelpers.ExpandWildcards(node, parsedPath, wildcardIndex, includeMissingFinal)
end

--[[
	Fan-out core for wildcard `Update`/`Increment`: one read-modify-write per
	matched concrete path. The value is re-read immediately before each write
	(not taken from the expansion snapshot) so a `transform` that touches other
	matched paths never operates on stale data. `transform` also receives the
	keys matched by each `"*"` (left-to-right, one per wildcard) and the fully
	concrete path. Multiple writes are batched so listeners see one coherent
	flush.
]]
const function applyWildcardRMW<T>(
	self: TM_Internal<T>,
	entries: { PathHelpers.WildcardExpansion },
	transform: (oldValue: any, wildcardMatches: { any }, path: { any }) -> any
)
	if #entries == 0 then
		return
	end
	if #entries == 1 then
		const entry = entries[1]
		self:Set(entry.Path, transform(self:Get(entry.Path, true), entry.WildcardMatches :: { any }, entry.Path))
		return
	end
	self:Batch(function()
		for _, entry in entries do
			self:Set(entry.Path, transform(self:Get(entry.Path, true), entry.WildcardMatches :: { any }, entry.Path))
		end
	end)
end

--[=[
	@within TableManager
	@method Get

	Reads the value at `path`. The path may be a dot-string (`"player.health"`)
	or a path array (`{ "player", "health" }`); an empty path returns the root
	table.

	By default this errors if an intermediate segment is not a table (e.g. reading
	`"a.b"` when `a` is a number). Pass `suppressNilPartialPaths = true` to return
	`nil` in that case instead.

	@param path Path
	@param suppressNilPartialPaths boolean? -- Return `nil` instead of erroring when a segment along the path is not a table.
	@return any -- The value at `path`.

	```lua
	manager:Get("player.health")        -- dot-string path
	manager:Get({ "player", "health" }) -- array path (equivalent)
	```
]=]
function TableManager.Get<T, S>(self: TM_Internal<T>, path: Path<S>, suppressNilPartialPaths: boolean?): ValueAtPath<T, S>?
	debug.profilebegin("TM.Get")
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Raw :: T & table
	for _, key in parsedPath do
		if type(current) ~= "table" then
			debug.profileend()
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {key} is not a table`)
			end
		end
		current = current[key]
	end
	debug.profileend()
	return current
end

--[=[
	@within TableManager
	@method GetMatching

	Reads every value matched by a path containing wildcard (`"*"`) segments,
	returning one record per concrete match:

	- `Path` -- the fully concrete path array (every `"*"` replaced by the matched key).
	- `Value` -- the value at that path.
	- `WildcardMatches` -- the keys matched by each `"*"`, left-to-right (the same
	  convention as listener `metadata.WildcardMatches`).

	Each `"*"` matches every key present at that level; multiple wildcards compose
	as the product of their branch factors. Branches where the remaining path
	cannot resolve are skipped, and only existing values are reported -- zero
	matches returns an empty array. Entry order follows table iteration order and
	is not deterministic for dictionary keys.

	A path with no wildcards returns zero-or-one records, resolved exactly like
	[TableManager:Get] (including the error on a non-table intermediate segment;
	literal segments before the first `"*"` error the same way).

	@param path Path
	@return { { Path: { any }, Value: any, WildcardMatches: { any }? } } -- One record per matched concrete path.

	```lua
	local manager = TableManager.new({
		Players = {
			p123 = { Health = 100 },
			p456 = { Health = 70 },
		},
	})

	local matches = manager:GetMatching("Players.*.Health")
	-- matches (order not guaranteed):
	-- {
	--   { Path = { "Players", "p123", "Health" }, Value = 100, WildcardMatches = { "p123" } },
	--   { Path = { "Players", "p456", "Health" }, Value = 70,  WildcardMatches = { "p456" } },
	-- }

	for _, match in matches do
		print(match.WildcardMatches[1], "has", match.Value, "health")
	end

	-- Multiple wildcards -> one WildcardMatches entry per "*", left-to-right:
	for _, match in manager:GetMatching("Players.*.Stats.*") do
		local playerId, statName = match.WildcardMatches[1], match.WildcardMatches[2]
	end
	```
]=]
function TableManager.GetMatching<T, S>(self: TM_Internal<T>, path: Path<S>): { PathHelpers.WildcardExpansion }
	const parsedPath = PathHelpers.ParsePath(path)
	const wildcardIndex = PathHelpers.FindFirstWildcard(parsedPath)
	if wildcardIndex == nil then
		const value = self:Get(parsedPath :: any)
		if value == nil then
			return {}
		end
		return { { Path = table.clone(parsedPath), Value = value, WildcardMatches = nil } }
	end
	return resolveWildcardExpansion(self, parsedPath, wildcardIndex, false)
end

--[=[
	@within TableManager
	@method GetProxy

	Returns a live [Proxy] for the table at `path`, or the raw value when `path`
	resolves to a non-table. Reads through the proxy see live data, and writes
	through it route back into the manager exactly as [TableManager:Set] would.

	:::caution
	Errors if this manager was created with `Config.EnableProxies = false` -- there
	is no proxy graph to hand out. See the Proxies & Direct Table Access guide.
	:::

	@param path Path
	@param suppressNilPartialPaths boolean? -- Return `nil` instead of erroring when a segment along the path is not a table.
	@return Proxy | any -- A proxy for the table at `path`, or the raw value if it is not a table.
]=]
function TableManager.GetProxy<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	suppressNilPartialPaths: boolean?
): (Proxy<T, S> | ValueAtPath<T, S>)?
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		error("GetProxy requires proxies (Config.EnableProxies = false for this TableManager)")
	end
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy :: {[any]: any}
	local previousKey: any = nil
	for _, key in parsedPath do
		if not proxyManager:IsProxy(current) then
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {tostring(previousKey)} is not a table`)
			end
		end
		current = current[key]
		previousKey = key
	end
	return current
end

--[=[
	@within TableManager
	@method GetLastEmitted

	Reads the value at `path` as listeners **last saw it** -- the value carried by
	the most recent change event fired for `path`, rather than the current live
	value. Under the default immediate flush mode with no pending changes this is
	identical to [TableManager:Get]; the two diverge only when the live data has
	moved ahead of what has been emitted -- inside a `Batch`/`Suspend` window, or
	under `FlushMode = "coalesced"` / a deferred fire mode, before the pending
	flush runs.

	If `path` has never been observed (no listener, Signal, link, or `OnApplied`
	subscriber ever covered it) there is no recorded "last emitted" value, so this
	falls back to a live [TableManager:Get] -- the same value a first listener
	would receive.

	:::caution Last-emitted `nil` inside a pending window
	The recorded baseline cannot distinguish "never observed" from "observed, and
	the last value emitted was itself `nil`" (e.g. after an emitted deletion) -- an
	absent key and a `nil`-valued key are indistinguishable in the baseline store.
	Both fall back to the live `Get`. That fallback is exact except in one narrow
	window: if the last emit for `path` was `nil` **and** the live value has since
	moved ahead of it inside a pending flush (a `Batch`/`Suspend` window, or
	`FlushMode = "coalesced"` / a deferred fire mode), this returns the pending live
	value rather than the emitted `nil`. Once that flush drains, it converges again.
	:::

	:::caution Table results are snapshots
	When the value at `path` is a table, the returned table is the internal
	baseline mirror of the last-emitted state: it follows the same stability rules
	as a listener's table `oldValue` (a stable snapshot only for the duration of
	the synchronous call -- copy it if you need to retain it). Scalar results are
	always safe to keep.
	:::

	@param path Path
	@param suppressNilPartialPaths boolean? -- Return `nil` instead of erroring when a segment along the path is not a table (only consulted on the live fallback).
	@return any -- The value last emitted for `path` (or the live value when `path` was never observed).

	```lua
	local manager = TableManager.new({ Score = 0 }, { FlushMode = "coalesced" })
	manager:OnValueChange("Score", function() end) -- observe so a baseline is kept

	manager:Set("Score", 10)
	manager:Get("Score")            -- 10 (live)
	manager:GetLastEmitted("Score") -- 0  (listeners have not been told yet)

	manager:Flush("Score")
	manager:GetLastEmitted("Score") -- 10 (now emitted)
	```
]=]
function TableManager.GetLastEmitted<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	suppressNilPartialPaths: boolean?
): ValueAtPath<T, S>?
	const parsedPath = PathHelpers.ParsePath(path)
	const baseline = BaselineModule.Get(self, parsedPath)
	if baseline ~= nil then
		return baseline
	end
	-- No materialized baseline (path never observed, or its last-emitted value is
	-- itself nil): fall back to the current live value -- what a first listener
	-- would see.
	return self:Get(parsedPath :: any, suppressNilPartialPaths)
end

--[=[
	@within TableManager
	@method Set

	Writes `value` at `path`, firing the events for whatever changed.

	```lua
	manager:Set("player.health", 80)          -- dot-string path
	manager:Set({ "player", "health" }, 80)   -- array path (equivalent)
	manager:Set("player.buff", nil)           -- removing a key
	```

	An empty path (`Set({}, newTable)` / `Set("", newTable)`) replaces the entire
	root table: its identity is swapped to `newTable`, stale proxies of the old
	tree are pruned, and root/child change listeners fire for the diff. The new
	root must be a table (the root cannot become a scalar or `nil`), and the root
	cannot be replaced while a batch is open.

	The path may contain wildcard (`"*"`) segments -- the same grammar the
	listener methods accept. Each `"*"` matches every key present at that level
	at call time (multiple wildcards compose as the product of their branch
	factors), and the write is applied once per matched concrete path, batched
	into one coherent flush when more than one path matches:

	```lua
	manager:Set("Players.*.Health", 100)   -- every player's Health (created where missing)
	manager:Set("Players.*.Stats.*", 0)    -- every stat of every player
	manager:Set("Players.*", nil)          -- mass delete: removes every player
	```

	Wildcard branches where the remaining path cannot resolve are skipped, and
	zero matches is a no-op. Writing `nil` only targets existing values; a
	non-nil write also creates a missing literal final key on each matched
	parent. `buildTablesDynamically` cannot be combined with a wildcard path.
	Note that a table value fanned to multiple paths is subject to
	[TableManagerConfig.DuplicateReferenceMode]: under `"allow"` (the default)
	every matched path shares the SAME table identity; use `"copy"` for
	independent clones.

	@param path Path
	@param value any -- The value to write. May be wrapped with [TableManager.Opaque] or similar.
	@param buildTablesDynamically boolean? -- When `true`, missing intermediate tables along `path` are created rather than erroring. Not allowed with wildcard paths.
]=]
function TableManager.Set<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	value: ValueAtPath<T, S> | Types.OpaqueWrapper<ValueAtPath<T, S>>,
	buildTablesDynamically: boolean?
)
	debug.profilebegin("TM.Set")
	local parsedPath = PathHelpers.ParsePath(path)
	local unwrappedValue = ProxyManagerModule.Unwrap(value)
	unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)

	-- Empty path replaces the entire root table (identity swap + full diff).
	if #parsedPath == 0 then
		applyRootSet(self, unwrappedValue)
		debug.profileend()
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
			debug.profileend()
			error(`Cannot build tables dynamically through a wildcard ("*") path segment`)
		end
		const entries = resolveWildcardExpansion(self, parsedPath, wildcardIndex, unwrappedValue ~= nil)
		if #entries == 1 then
			applyWrite(self, entries[1].Path, unwrappedValue)
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
					applyWrite(self, entry.Path, valueToWrite)
				end
			end)
		end
		debug.profileend()
		return
	end

	-- Only build intermediate tables when setting non-nil values; removing (nil) doesn't need them
	const shouldBuild = buildTablesDynamically and unwrappedValue ~= nil

	-- Fast path: a non-nil write with no dynamic-build request has no behavior
	-- left in the loop below beyond what `applyWrite`'s own parent-chain walk
	-- already performs (including reporting the identical "Path segment X is
	-- not a table" error) — so skip straight to the single walk instead of
	-- walking the parent chain twice.
	if unwrappedValue ~= nil and not buildTablesDynamically then
		applyWrite(self, parsedPath, unwrappedValue)
		debug.profileend()
		return
	end

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
				debug.profileend()
				return
			end

			-- Build intermediate tables for the remainder of the path, then apply the write.
			local nested: any = unwrappedValue
			for j = #parsedPath, i + 1, -1 do
				nested = { [parsedPath[j]] = nested }
			end
			const subPath = table.move(parsedPath, 1, i, 1, table.create(i))
			applyWrite(self, subPath, nested)
			debug.profileend()
			return
		end
		parent = nextValue
	end

	applyWrite(self, parsedPath, unwrappedValue)
	debug.profileend()
end

--[=[
	@within TableManager
	@method Update

	Reads the value at `path`, passes it through `updater`, and writes the result
	back. Equivalent to a [TableManager:Get] followed by [TableManager:Set], so it
	fires the same change events as a plain `Set`.

	The path may contain wildcard (`"*"`) segments: `updater` then runs once per
	matched concrete path, the writes are batched into one coherent flush, and
	the method returns `nil`. On a wildcard path each invocation receives, after
	the current value, the keys matched by each `"*"` (left-to-right, one per
	wildcard) and the fully concrete path -- so an `updater` can tell which match
	it is handling:

	```lua
	manager:Update("Players.*.Stats.*", function(value, matches, path)
		-- matches[1] = playerId, matches[2] = statName
		-- path       = { "Players", playerId, "Stats", statName }
		return value + 1
	end)
	```

	`matches`/`path` are `nil` for a non-wildcard `Update`. Only existing values
	are visited -- use [TableManager:Set] to create keys through a wildcard. See
	[TableManager:GetMatching] for the matching rules.

	@param path Path
	@param updater (oldValue: any, wildcardMatches: { any }?, path: { any }?) -> any -- Receives the current value (and, on wildcard paths, the matched keys and concrete path); returns the new value.
	@return any -- The new value that was written (`nil` for wildcard paths).

	```lua
	manager:Update("coins", function(current)
		return current * 2
	end)
	```
]=]
function TableManager.Update<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	updater: (oldValue: ValueAtPath<T, S>, wildcardMatches: { any }?, path: { any }?) -> ValueAtPath<T, S>
): ValueAtPath<T, S>
	const parsedPath = PathHelpers.ParsePath(path)
	const wildcardIndex = PathHelpers.FindFirstWildcard(parsedPath)
	if wildcardIndex ~= nil then
		const entries = resolveWildcardExpansion(self, parsedPath, wildcardIndex, false)
		applyWildcardRMW(self, entries, updater :: any)
		return nil :: any
	end
	-- Single-walk read-modify-write: resolves the parent chain once for both
	-- the read and the write (see `Mutator.applyRMW`).
	return applyRMW(self, parsedPath, updater :: any)
end

--[=[
	@within TableManager
	@method Increment

	Adds `delta` to the number at `path` and writes the result back. Shorthand for
	an [TableManager:Update] that returns `oldValue + delta`; errors if the current
	value is not addable.

	The path may contain wildcard (`"*"`) segments: `delta` is then added to every
	matched existing value (batched into one coherent flush) and the method
	returns `nil`. See [TableManager:Update] and [TableManager:GetMatching].

	@param path Path
	@param delta any -- The amount to add (any value supporting `+` with the current value).
	@return any -- The new value that was written (`nil` for wildcard paths).

	```lua
	manager:Increment("coins", 50)  -- coins += 50
	manager:Increment("Players.*.Health", 5) -- everyone heals 5
	```
]=]
function TableManager.Increment<T, S>(self: TM_Internal<T>, path: Path<S>, delta: any): any
	const parsedPath = PathHelpers.ParsePath(path)
	const wildcardIndex = PathHelpers.FindFirstWildcard(parsedPath)
	if wildcardIndex ~= nil then
		const entries = resolveWildcardExpansion(self, parsedPath, wildcardIndex, false)
		applyWildcardRMW(self, entries, function(oldValue)
			return oldValue + delta
		end)
		return nil
	end
	-- Single-walk read-modify-write (see `Mutator.applyRMW`).
	return applyRMW(self, parsedPath, function(oldValue)
		return oldValue + delta
	end)
end

--[=[
	@within TableManager
	@method ArrayInsert

	Inserts a value into the array at `pathOrProxy`. Two call shapes:

	- `ArrayInsert(path, value)` -- appends `value` to the end.
	- `ArrayInsert(path, index, value)` -- inserts `value` at `index`, shifting
	  the existing elements at and after `index` one slot to the right.

	Fires `ArrayInserted` (and ancestor change events) for the affected index.
	`pathOrProxy` may be a path or a [Proxy] of the array.

	*Aliased as `Insert`.*

	@param pathOrProxy Path | Proxy
	@param ... any -- Either `value`, or `index, value`.

	```lua
	manager:ArrayInsert("items", "sword")   -- append
	manager:ArrayInsert("items", 1, "shield") -- insert at index 1
	```
]=]
function TableManager.ArrayInsert<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, ...: any): ()
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	-- Determine if a position was provided or default to appending.
	local pos: number
	local newValue: any
	if select("#", ...) >= 2 then
		local secondArg
		pos, secondArg = ...
		newValue = secondArg
	else
		pos = #array + 1
		newValue = ...
	end

	local unwrappedValue = ProxyManagerModule.Unwrap(newValue)
	unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)

	if not MutatorModule.validateArrayInsert(self, parsedPath, unwrappedValue) then return end

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Insert the value (handles shifting when inserting into the middle).
	table.insert(array, pos, unwrappedValue)
	-- Update Key metadata for all proxies that were shifted right by this insert.
	shiftArrayKeys(self._proxyManager, array, pos, 1)
	-- Implicit sharing: an inserted table already observed elsewhere becomes a
	-- shared region (writes propagate between observers).
	if not self._suppressLinkFanOut then
		PropagationModule.RegisterSubtree(self :: any, unwrappedValue)
	end

	if not inBatch then
		-- Coverage gate, mirroring the dict write path (`applyWrite`) and the
		-- append fast path (`onArrayAppended`): when nothing observes this
		-- array, skip the whole emit chain (synthetic metadata, dual listener
		-- fire, ancestor walk, baseline sync) — an `OnApplied` subscriber still
		-- needs the op, shipped directly.
		if CoverageModule.IsTrackable(self, parsedPath) then
			-- Fire element-level and array-level listeners, ancestor callbacks, and signal.
			emitInserted(self, parsedPath, pos, unwrappedValue, nil, true)
		elseif self._appliedListeners[1] ~= nil then
			EmitterModule.emitReplicationOp(self, "ArrayInsert", parsedPath, unwrappedValue, pos, nil)
		end
	end
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	@within TableManager
	@method ArrayRemove

	Removes the element at `index` from the array at `pathOrProxy`, shifting the
	following elements one slot to the left. Fires `ArrayRemoved` (and ancestor
	change events) at the remove path.

	*Aliased as `Remove`.*

	@param pathOrProxy Path | Proxy
	@param index number -- 1-based index of the element to remove.
	@return any -- The removed element.
]=]
function TableManager.ArrayRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Remove the element (handles shifting automatically).
	const oldValue = table.remove(array, index)
	-- Shift proxies after the removed slot left by 1. Pass index+1 as fromIndex
	-- so the removed item's own proxy (if held) keeps its original key rather than
	-- being shifted to key=0.
	shiftArrayKeys(self._proxyManager, array, index + 1, -1)
	pruneDetachedValue(self, oldValue, nil)

	if inBatch then
		return oldValue
	end

	-- Coverage gate (see ArrayInsert): unobserved removes skip the emit chain
	-- but still ship the op to any OnApplied subscriber.
	if CoverageModule.IsTrackable(self, parsedPath) then
		-- Fire listeners EXACTLY at remove path (we handle ancestors separately)
		emitRemoved(self, parsedPath, index, oldValue, nil, true)
	elseif self._appliedListeners[1] ~= nil then
		EmitterModule.emitReplicationOp(self, "ArrayRemove", parsedPath, nil, index, nil)
	end
	return oldValue
end
TableManager.Remove = TableManager.ArrayRemove

--[=[
	@within TableManager
	@method ArrayRemoveFirstValue

	Finds the first element equal to `valueToFind` and removes it via
	[TableManager:ArrayRemove].

	*Aliased as `RemoveFirstValue`.*

	@param pathOrProxy Path
	@param valueToFind any -- The value to search for (compared by equality).
	@return number? -- The index it was removed from, or `nil` if not found.
]=]
function TableManager.ArrayRemoveFirstValue<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S>, valueToFind: any): number?
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArrayRemove(parsedPath, index)
	return index
end
TableManager.RemoveFirstValue = TableManager.ArrayRemoveFirstValue

--[=[
	@within TableManager
	@method ArraySwapRemove

	Removes the element at `index` in O(1) by moving the last element into its
	slot, instead of shifting every following element. **Order is not preserved.**

	Because the last element backfills the hole, this emits two events rather than
	one: an `ArraySet` at `index` (the backfill) followed by an `ArrayRemoved` at
	the old last index (the shrink). When `index` is already the last element, only
	the `ArrayRemoved` fires.

	*Aliased as `SwapRemove`.*

	@param pathOrProxy Path | Proxy
	@param index number -- 1-based index of the element to remove.
	@return any -- The removed element, or `nil` if `index` is out of range.
]=]
function TableManager.ArraySwapRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const lastIndex = #array
	if index < 1 or index > lastIndex then
		return nil
	end

	const oldValue = array[index]
	const movedValue = array[lastIndex]

	const inBatch = trackArrayMutation(self, parsedPath)

	if index ~= lastIndex then
		array[index] = movedValue
	end
	array[lastIndex] = nil
	pruneDetachedValue(self, oldValue, nil)

	if inBatch then return oldValue end

	-- Coverage gate (see ArrayInsert): both emits below share one resolution,
	-- and an unobserved swap-remove still ships its two ops to any OnApplied
	-- subscriber in the same order the emit chain would have.
	if not CoverageModule.IsTrackable(self, parsedPath) then
		if self._appliedListeners[1] ~= nil then
			if index ~= lastIndex then
				EmitterModule.emitReplicationOp(self, "ArraySet", parsedPath, movedValue, index, nil)
			end
			EmitterModule.emitReplicationOp(self, "ArrayRemove", parsedPath, nil, lastIndex, nil)
		end
		return oldValue
	end

	-- moveId is typed as `string` (ArrayDiff.MoveMetadata) for downstream
	-- consumers that may key off it; kept as an interpolated string rather than
	-- widening that public type for this single call site.
	const moveInfo = if index ~= lastIndex
		then { moveId = `swapremove_{index}_{lastIndex}`, fromIndex = lastIndex, toIndex = index }
		else nil

	-- 1. Emit ArraySet for the backfill: array[index] = movedValue (no-op if index == lastIndex)
	if index ~= lastIndex then
		emitSet(self, parsedPath, index, movedValue, oldValue, moveInfo, true)
	end

	-- 2. Emit ArrayRemoved for the shrink: array[lastIndex] = nil (the actual removal)
	emitRemoved(self, parsedPath, lastIndex, movedValue, moveInfo, true)

	return oldValue
end
TableManager.SwapRemove = TableManager.ArraySwapRemove

--[=[
	@within TableManager
	@method ArraySwapRemoveFirstValue

	Finds the first element equal to `valueToFind` and removes it via
	[TableManager:ArraySwapRemove] (O(1), order not preserved).

	*Aliased as `SwapRemoveFirstValue`.*

	@param pathOrProxy Path | Proxy
	@param valueToFind any -- The value to search for (compared by equality).
	@return number? -- The index it was removed from, or `nil` if not found.
]=]
function TableManager.ArraySwapRemoveFirstValue<T, S>(
	self: TM_Internal<T>,
	pathOrProxy: Path<S> | Proxy<T, S>,
	valueToFind: any
): number?
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArraySwapRemove(parsedPath, index)
	return index
end
TableManager.SwapRemoveFirstValue = TableManager.ArraySwapRemoveFirstValue

--[=[
	@within TableManager
	@method UpdateKey

	Like [TableManager:Update], but for the child `key` under `path` -- it updates
	the value at `path` extended by `key`. Handy for a single dictionary entry or
	array index without building the combined path yourself.

	*Aliased as `ArrayUpdate`.*

	@param path Path
	@param key any -- The child key/index under `path` to update.
	@param updater (oldValue: any) -> any -- Receives the current value; returns the new value.
	@return any -- The new value that was written.

	```lua
	manager:UpdateKey("inventory", "gold", function(n) return n + 10 end)
	```
]=]
function TableManager.UpdateKey<T, S>(self: TM_Internal<T>, path: Path<S>, key: any, updater: (oldValue: ElementAtPath<T, S>) -> ElementAtPath<T, S>): ElementAtPath<T, S>
	-- Append clones rather than mutating the parsed path: a dot-string parse
	-- is a shared frozen cache entry, and a caller-supplied array must not
	-- gain `key` as a side effect.
	const parsedPath = PathHelpers.Append(PathHelpers.ParsePath(path), key)
	-- Single-walk read-modify-write (see `Mutator.applyRMW`).
	return applyRMW(self, parsedPath, updater :: any)
end
TableManager.ArrayUpdate = TableManager.UpdateKey

--[=[
	@within TableManager
	@method IncrementKey

	Like [TableManager:Increment], but for the child `key` under `path` -- it adds
	`delta` to the value at `path` extended by `key`.

	*Aliased as `ArrayIncrement`.*

	@param path Path
	@param key any -- The child key/index under `path` to increment.
	@param delta any -- The amount to add.
	@return any -- The new value that was written.
]=]
function TableManager.IncrementKey<T, S>(self: TM_Internal<T>, path: Path<S>, key: any, delta: ElementAtPath<T, S>): ElementAtPath<T, S>
	-- Append clones rather than mutating the parsed path (see `UpdateKey`).
	const parsedPath = PathHelpers.Append(PathHelpers.ParsePath(path), key)
	-- Single-walk read-modify-write (see `Mutator.applyRMW`).
	return applyRMW(self, parsedPath, function(oldValue)
		return oldValue + delta
	end)
end
TableManager.ArrayIncrement = TableManager.IncrementKey

--[=[
	@within TableManager
	@method Batch
	@param fn () -> ()

	Holds off firing signals for the duration of the callback, then fires needed signals at the end.
	Useful for batch operations where you want to suppress intermediate signals and only fire final results.

	Nested calls are no-ops: the outermost Batch window covers everything.

	:::caution yielding
	Yielding within a batch window will leave the TableManager in a suspended state, which
	can cause unexpected behavior.
	:::
]=]
function TableManager.Batch(self: TM_Internal, fn: () -> ())
	if self._batchDepth > 0 then
		-- Already inside a batch window; run the callback in-place
		fn()
		return
	end
	self:Suspend()
	const ok, err = (pcall :: any)(fn)
	self:Resume()
	if not ok then
		error(err, 2)
	end
end

--[=[
	@within TableManager
	@method Suspend

	Suspends all signal and listener firing.

	It is recommended to use `:Batch` for better ergonomics and safety,
	but `Suspend`/`Resume` can be used for more manual control if needed.

	Pair with `Resume()`. Nested calls are no-ops (the outermost window wins).
]=]
function TableManager.Suspend(self: TM_Internal)
	BatchFlushModule.Suspend(self)
end

--[=[
	@within TableManager
	@method Resume

	Resumes after `Suspend()` and flushes all pending changes.

	Flush is a single array-aware pass: per dirty branch, `CheckForChangesBetween`
	diffs the pre-batch value against the current value, collecting array-like
	nodes out of the dict diff; those are then re-diffed via LCS
	(`ArrayDiff.emitDiff`) into shift-faithful `Array*` events. See `BatchFlush`.
]=]
function TableManager.Resume(self: TM_Internal)
	BatchFlushModule.Resume(self)
end

--[=[
	@private
	Internal, unconditional diff+fire+reconcile for `path`: diffs the
	persistent shadow's last-flushed value against the current live value,
	fires the resulting events via `CheckForChangesBetween`, then reconciles
	the shadow to live. Callers (the immediate write path, `Flush`,
	`_NotifyApplied`, `BatchFlush.Resume`) are responsible for the coverage
	gate and batch-state check; this always runs.

	`forceFullDepth` bypasses the depth bound for this flush only -- used by
	`Flush` when the only reason to flush is an `OnApplied` subscriber (no
	local listener covers `path`, so there's no observed depth to bound to and
	the op stream needs to discover the whole changed subtree). It never
	affects the general write path's depth bound.

	`precomputedMaxDepth` is the depth bound the caller already resolved for
	this same write (`Coverage.ResolveWriteObservation`, forwarded through
	`CoalescedFlush.Request` on the immediate path only), with `math.huge`
	standing in for "unbounded" so it stays distinguishable from "no hint".
	Omitted by every deferred/explicit caller, which must re-resolve here.
]=]
function TableManager._doFlush<T>(self: TM_Internal<T>, path: PathArray, forceFullDepth: boolean?, precomputedMaxDepth: number?)
	const old = BaselineModule.Get(self, path)
	const new_ = self:Get(path :: any, true)
	const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, path, old)
	-- Transparent depth bound: don't diff below the deepest listener that observes
	-- `path` (nil = unbounded when a signal/link/wildcard/ProvideDiff forces it).
	local maxDepth: number?
	if forceFullDepth then
		maxDepth = nil
	elseif precomputedMaxDepth ~= nil then
		maxDepth = if precomputedMaxDepth == math.huge then nil else precomputedMaxDepth
	else
		maxDepth = CoverageModule.ResolveDiffMaxDepth(self, path)
	end
	self._changeDetector:CheckForChangesBetween(old, new_, path, self.Raw, nil, oldSnapshot, maxDepth)
	BaselineModule.Reconcile(self, path)
end

--[=[
	@within TableManager
	@method Flush
	@param path Path? -- The subtree to flush; the whole tree when omitted.

	Diffs the persistent shadow baseline against the live value at `path`
	(the whole tree when omitted), fires any resulting events, then
	reconciles the shadow to the current live value. A no-op when nothing
	observes `path` (no registered listener covers it, no global Signal is
	connected, and no link group is active).

	Outside a batch this runs immediately. Inside a `Suspend`/`Batch` window
	it just marks the branch dirty for `Resume`'s flush instead of firing, so
	an explicit `Flush` can never break batch atomicity.

	This is also the supported way to surface a mutation made by code that
	bypassed `Set`/`Proxy` and wrote directly into the underlying table.
]=]
function TableManager.Flush<T, S>(self: TM_Internal<T>, path: Path<S>?)
	const parsedPath: PathArray = if path ~= nil then PathHelpers.ParsePath(path) else {}
	const isTrackable = CoverageModule.IsTrackable(self, parsedPath)
	if not isTrackable and self._appliedListeners[1] == nil then
		return
	end
	if self._batchDepth > 0 then
		const batch = self._batch
		if batch then
			BatchUtilsModule.MarkBatchBranchDirty(batch, parsedPath)
		end
		return
	end
	CoalescedFlushModule.FlushPending(self)
	-- Not locally trackable: nothing observes a bound, and the op stream needs
	-- to discover the whole changed subtree -- so this flush alone forces full
	-- depth (see `_doFlush`'s `forceFullDepth`; never the general write path).
	self:_doFlush(parsedPath, not isTrackable)
end

--[=[
	@within TableManager
	@method MoveTo
	@param currentPath Path | Proxy
	@param newPath Path | Proxy

	Move an element from one location to another within the same table.
	This unsets the value at the current path and sets it at the new path, firing appropriate notifications.
	This is specifically useful for moving tables around without breaking proxy references.
]=]
function TableManager.MoveTo<T, S1, S2>(
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

	const rollback = reparentWithRollback(self._proxyManager, sourceValue, targetParentOriginal, targetKey)

	const ok, moveErr = pcall(function()
		self:Batch(function()
			self:Set(targetPath, sourceValue)
			self:Set(sourcePath, nil :: any)
		end)
	end)

	if not ok then
		restoreReparent(self._proxyManager, rollback)
		error(moveErr, 2)
	end
end

--[=[
	@within TableManager
	@method CopyTo
	@param currentPath Path | Proxy
	@param newPath Path

	DeepCopy a value from one location to another within the same table.
	This sets the value at the new path to be the same as the value at the current path, firing appropriate notifications.
	This is specifically useful for copying tables around without breaking proxy references.
]=]
function TableManager.CopyTo<T, S1, S2>(self: TM_Internal<T>, currentPath: Path<S1> | Proxy<T, S1>, newPath: Path<S2>)
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

--[=[
	@within TableManager
	@method Swap

	Swaps the values at paths `a` and `b` within this manager. The swap is applied
	as a single batched pair of writes, and proxy references are preserved across
	the move. If either write fails the reparenting is rolled back so neither path
	is left in a partial state.

	Either argument may be a path or a [Proxy]. Errors if a path is the root or if
	one path is an ancestor/descendant of the other (an overlapping swap is not
	well-defined).

	@param a Path | Proxy
	@param b Path | Proxy

	```lua
	manager:Swap("slots.1", "slots.2")
	```
]=]
function TableManager.Swap<T, S1, S2>(self: TM_Internal<T>, a: Path<S1> | Proxy<T, S1>, b: Path<S2> | Proxy<T, S2>)
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

	const rollbackA = reparentWithRollback(self._proxyManager, valueA, parentOriginalB, keyB)
	const rollbackB = reparentWithRollback(self._proxyManager, valueB, parentOriginalA, keyA)

	const ok, swapErr = pcall(function()
		self:Batch(function()
			self:Set(pathA, valueB)
			self:Set(pathB, valueA)
		end)
	end)

	if not ok then
		restoreReparent(self._proxyManager, rollbackA)
		restoreReparent(self._proxyManager, rollbackB)
		error(swapErr, 2)
	end
end

--------------------------------------------------------------------------------
--// Listener Registration //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@method OnValueChange
	@param path Path
	@param callback (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection

	Fires ONLY when this exact path is directly reassigned (not when a
	descendant of it changes). Shorthand for `OnChange` with
	`ListenDepth = 0, ListenDepthStyle = "=="`.
]=]
function TableManager.OnValueChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	const mergedOptions: ListenerOptions = if options then table.clone(options :: any) else {}
	mergedOptions.ListenDepth = 0
	mergedOptions.ListenDepthStyle = "=="
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, mergedOptions)
end

--[=[
	@within TableManager
	@method OnChange
	@param path Path
	@param callback (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection

	Fires when this path is directly reassigned OR any descendant of it
	changes.
]=]
function TableManager.OnChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method Observe
	@param path Path
	@param callback (newValue: any, oldValue: any?, metadata: ChangeMetadata?) -> ()
	@param options ListenerOptions?
	@return Connection

	Immediately invokes `callback` with the current value at `path`
	(`oldValue` and `metadata` both `nil`), then behaves like
	`OnValueChange` for subsequent changes.
]=]
function TableManager.Observe<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata?) -> (),
	options: ListenerOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	const currentValue = self:Get(parsedPath, true)

	const function fireInitial()
		callback(currentValue, nil, nil)
	end

	if self._listenerRegistry._fireMode ~= "immediate" then
		task.defer(fireInitial)
	else
		task.spawn(fireInitial)
	end

	return self._listenerRegistry:RegisterListener("ValueChanged", parsedPath, callback, options)
end

--[=[
	@within TableManager
	@method OnKeyAdd

	Fires when a new key appears in the table at `path` (a key that did not exist
	before is assigned a non-nil value).

	@param path Path
	@param callback (key: any, newValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection

	```lua
	manager:OnKeyAdd("inventory", function(key, newValue)
		print(`gained {key} = {newValue}`)
	end)
	```
]=]
function TableManager.OnKeyAdd<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (key: any, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyAdded", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method OnKeyRemove

	Fires when a key is removed from the table at `path` (an existing key is set to
	`nil`).

	@param path Path
	@param callback (key: any, oldValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection

	```lua
	manager:OnKeyRemove("inventory", function(key, oldValue)
		print(`lost {key} (was {oldValue})`)
	end)
	```
]=]
function TableManager.OnKeyRemove<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (key: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyRemoved", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method OnKeyChange

	Fires when an existing key in the table at `path` is reassigned to a different
	value (not added or removed -- see [TableManager:OnKeyAdd] /
	[TableManager:OnKeyRemove] for those).

	@param path Path
	@param callback (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection
]=]
function TableManager.OnKeyChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyChanged", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method OnArrayInsert

	Fires when an element is inserted into the array at `path`, reporting the index
	it landed at. Driven by array-aware diffing, so it reflects true insertions with
	replay-faithful indices rather than a blanket "the array changed".

	@param path Path
	@param callback (index: number, newValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection
]=]
function TableManager.OnArrayInsert<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayInserted", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method OnArrayRemove

	Fires when an element is removed from the array at `path`, reporting the index
	it was removed from and its old value.

	@param path Path
	@param callback (index: number, oldValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection
]=]
function TableManager.OnArrayRemove<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayRemoved", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	@within TableManager
	@method OnArraySet

	Fires when an existing array slot at `path` is overwritten in place (its index
	kept, its value replaced), reporting the index, new value, and old value.

	@param path Path
	@param callback (index: number, newValue: any, oldValue: any, metadata: ChangeMetadata) -> ()
	@param options ListenerOptions?
	@return Connection
]=]
function TableManager.OnArraySet<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (
		index: number,
		newValue: any,
		oldValue: any,
		metadata: ChangeMetadata
	) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArraySet", PathHelpers.ParsePath(path), callback, options)
end

--------------------------------------------------------------------------------
--// Linking //--
--------------------------------------------------------------------------------

--[=[
	@private
	Re-fires listeners/signals for an op that has ALREADY been applied to the
	shared raw (by another manager observing the same table identity), without
	mutating or snapshot-diffing. `op.Path` is in this manager's own coordinates.
	Used only by cross-manager fan-out (see `Propagation`).
]=]
function TableManager._NotifyApplied<T>(self: TM_Internal<T>, op: AppliedOp)
	self._suppressLinkFanOut = true
	const ok, err = pcall(function()
		if op.Kind == "Set" then
			pruneDetachedValue(self, op.OldValue, op.NewValue)

			if CoverageModule.IsLocallyObserved(self, op.Path) then
				const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, op.Path, op.OldValue)
				if op.Diff ~= nil and op.OriginHasNoOpacity and self._opaqueRegistries.Count == 0 then
					self._changeDetector:DispatchDiffNode(op.Diff, op.Path, self.Raw, oldSnapshot)
				else
					self._changeDetector:CheckForChangesBetween(
						op.OldValue,
						op.NewValue,
						op.Path,
						self.Raw,
						nil,
						oldSnapshot
					)
				end
			elseif self._appliedListeners[1] ~= nil then
				-- Not locally observed, so nothing above diffed this op -- but
				-- THIS manager may itself have OnApplied subscribers (e.g. it is
				-- also being replicated), so ship the op directly.
				EmitterModule.emitReplicationOp(self, "Set", op.Path, op.NewValue, nil, op.Diff)
			end
			-- This bypasses applyWrite entirely (the write already landed via the
			-- ORIGIN manager), so the baseline needs its own sync here —
			-- applyWrite's seed/_doFlush never run for this path. The trackable /
			-- opaque-ancestor gate (Materialize can't safely persist through an
			-- opaque ancestor) lives in `Baseline.Materialize`; the dispatch above
			-- already fired correctly using op.OldValue/op.NewValue directly.
			BaselineModule.Materialize(self, op.Path)
		elseif op.Kind == "ArrayInsert" then
			const index = op.Index :: number
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index, 1)
			emitInserted(self, op.Path, index, op.NewValue)
		elseif op.Kind == "ArrayRemove" then
			const index = op.Index :: number
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index + 1, -1)
			pruneDetachedValue(self, op.OldValue, nil)
			emitRemoved(self, op.Path, index, op.OldValue)
		elseif op.Kind == "ArraySet" then
			emitSet(self, op.Path, op.Index :: number, op.NewValue, op.OldValue)
		end
	end)
	self._suppressLinkFanOut = false

	if not ok then
		error(err, 0)
	end
end

--[=[
	@within TableManager
	@method Extend
	@private
	@param target Proxy | Path
	@return TableManager

	Returns a plain `TableManager` rooted at the shared table found at `target`,
	linked (via `Link`) to this manager so writes on either side fan out to the
	other. `target` may be:
	- a proxy obtained from this manager (preferred);
	- a raw table value that is already part of this manager's tree; or
	- a path (string or array) into this manager's tree.

	The new TM is bound to the targeted table, not its path in the extending TM.
]=]
function TableManager.Extend<T, S>(
	self: TM_Internal<T>,
	target: Proxy<T, S> | Path<S>
): TableManager<ValueAtPath<T, S>>
	local anchorPath: PathArray<S>
	if self._proxyManager and self._proxyManager:IsProxy(target) then
		-- Preferred form: a proxy already names its live path.
		const path = self._proxyManager:GetPath(target)
		if path == nil then
			error("Extend target proxy is not part of this manager's tree")
		end
		anchorPath = path
	else
		-- Raw value already in the tree: locate it by identity (it may not have
		-- a proxy yet if it was never accessed via Get/GetProxy). Falls back to
		-- treating `target` as a path (string or array) if not found.
		const foundPath = if type(target) == "table" then PropagationModule.FindPathOf(self.Raw, target) else nil
		if foundPath ~= nil then
			anchorPath = foundPath
		else
			anchorPath = PathHelpers.ParsePath(target)
		end
	end

	const object = self:Get(anchorPath)
	if type(object) ~= "table" then
		error("Extend target must resolve to a table")
	end

	-- The new manager is rooted at the SAME live `object`, so implicit sharing
	-- registers both as observers of that identity (and its subtree) at
	-- construction — writes on either side propagate to the other automatically,
	-- with no explicit link. If `self` later replaces `object`, it stops resolving
	-- to that identity and propagation between them lapses (the extended manager
	-- keeps `object` as its root).
	const extended = Static.new(object)

	return extended
end

--[=[
	@within TableManager
	@method GetLinkedManagers
	@return { TableManager }

	Returns the other managers currently sharing (co-observing) at least one
	live table identity with this one — de-duplicated, excluding self.
]=]
function TableManager.GetLinkedManagers<T>(self: TM_Internal<T>): { TableManager<any> }
	return PropagationModule.GetCoObservers(self)
end

--[=[
	@within TableManager
	@method IsLinkedWith
	@param other TableManager
	@return boolean

	Returns true if this manager currently shares a live table identity with `other`.
]=]
function TableManager.IsLinkedWith<T>(self: TM_Internal<T>, other: TableManager<any>): boolean
	return PropagationModule.IsLinkedWith(self, other)
end

--------------------------------------------------------------------------------
--// For / Map //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@unreleased
	@method ForKeys
	@param path Path
	@param handler (itemJanitor: Janitor, key: any, metadata: ChangeMetadata?) -> ()
	@param options ForOptions?
	@return Connection

	Reconciles the items found at `path` by KEY: `handler` runs once per key
	(passed a per-item Janitor, the key, and change metadata — `nil` on the
	initial fire), and is NOT re-run when the value at an existing key
	changes. The Janitor is destroyed when that key is removed or the
	connection disconnects.
]=]
function TableManager.ForKeys<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (itemJanitor: Janitor, key: KeyAtPath<T, S>, metadata: ChangeMetadata?) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeKeyedReconciler(self, parsedPath, false, function(itemJanitor, key, _value, metadata)
		handler(itemJanitor, key, metadata)
	end, nil, nil, options, nil)
end

--[=[
	@within TableManager
	@unreleased
	@method ForValues
	@param path Path
	@param handler (itemJanitor: Janitor, value: any, metadata: ChangeMetadata?) -> ()
	@param options ForOptions?
	@return Connection

	Reconciles the items found at `path` by VALUE (as a multiset — duplicate
	values are tracked as independent items): `handler` runs once per value
	occurrence and is NOT re-run when that value moves between keys/indices
	(e.g. an `ArraySwapRemove`). The Janitor is destroyed when that value
	occurrence is no longer present or the connection disconnects.
]=]
function TableManager.ForValues<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (itemJanitor: Janitor, value: ElementAtPath<T, S>, metadata: ChangeMetadata?) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeValueReconciler(self, parsedPath, handler, options)
end

--[=[
	@within TableManager
	@unreleased
	@method ForPairs
	@param path Path
	@param handler (itemJanitor: Janitor, key: any, value: any, metadata: ChangeMetadata?) -> ()
	@param options ForOptions?
	@return Connection

	Reconciles the items found at `path` by KEY AND VALUE: `handler` re-runs
	(tearing down the previous item's Janitor first) whenever EITHER the key
	or the value changes — a value change at an existing key is treated as
	that item leaving and a new one appearing.
]=]
function TableManager.ForPairs<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (
		itemJanitor: Janitor,
		key: KeyAtPath<T, S>,
		value: ElementAtPath<T, S>,
		metadata: ChangeMetadata?
	) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeKeyedReconciler(self, parsedPath, true, handler, nil, nil, options, nil)
end

--[=[
	@within TableManager
	@method MapKeys
	@private
	@unreleased
	@param path Path
	@param transform (entryJanitor: Janitor, key: any, value: any) -> any
	@return TableManager

	Returns a live `TableManager` keyed by `transform(entryJanitor, key, value)`,
	with values passed through unchanged. `transform` re-runs only when the
	source key is added/removed; a value change at an existing key refreshes
	the output value WITHOUT re-running `transform`. The output manager owns
	the source subscription: destroying it disconnects from the source and
	tears down every entry's Janitor. Destroying the SOURCE does not
	cascade-destroy the returned manager (independent lifecycles).
]=]
function TableManager.MapKeys<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> any
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = Static.new({}) :: any
	const onAdd, onRemove, onRefresh = ForMapModule.makeKeyRemapHandlers(derived, function(itemJanitor, key, value)
		return transform(itemJanitor, key, value), value
	end)
	const connection =
		makeKeyedReconciler(self, parsedPath, false, onAdd, onRemove, onRefresh, nil, ForMapModule.batchedInitialFire(derived))
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--[=[
	@within TableManager
	@method MapValues
	@private
	@unreleased
	@param path Path
	@param transform (entryJanitor: Janitor, value: any, key: any) -> any
	@return TableManager

	Returns a live `TableManager` keyed by the SOURCE key, with each entry
	recomputed via `transform(entryJanitor, value, key)` whenever its value
	changes. Same ownership/lifecycle rules as `MapKeys`.
]=]
function TableManager.MapValues<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, value: ElementAtPath<T, S>, key: KeyAtPath<T, S>) -> any
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = Static.new({}) :: any

	const connection = makeKeyedReconciler(
		self,
		parsedPath,
		true,
		function(itemJanitor, key, value)
			derived:Set(key, transform(itemJanitor, value, key))
		end,
		function(_item, key)
			derived:Set(key, nil)
		end,
		nil,
		nil,
		ForMapModule.batchedInitialFire(derived)
	)
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--[=[
	@within TableManager
	@method MapPairs
	@private
	@unreleased
	@param path Path
	@param transform (entryJanitor: Janitor, key: any, value: any) -> (any, any)
	@return TableManager

	Returns a live `TableManager` keyed by `transform(entryJanitor, key, value)`'s
	first return value (the second is the output value); the entry is
	recomputed whenever the source key or value changes. On an output-key
	collision between two source entries, the last write wins. Same
	ownership/lifecycle rules as `MapKeys`.
]=]
function TableManager.MapPairs<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> (any, any)
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = Static.new({}) :: any
	const onAdd, onRemove = ForMapModule.makeKeyRemapHandlers(derived, transform)
	const connection =
		makeKeyedReconciler(self, parsedPath, true, onAdd, onRemove, nil, nil, ForMapModule.batchedInitialFire(derived))
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--------------------------------------------------------------------------------
--// Other Utility Methods //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@method SetPathIgnored
	@unreleased
	@param path Path
	@param ignored boolean

	Marks `path` (and every descendant of it) as ignored or not. An ignored
	write still happens — `Get`/`Raw` reflect it immediately — but skips all
	diff/snapshot/event work, so it never fires listeners/signals and is never
	cloned for change detection. See `TableManagerConfig.IgnoredPaths` for the
	config-time equivalent (seeded once at construction).
]=]
function TableManager.SetPathIgnored<T, S>(self: TM_Internal<T>, path: Path<S>, ignored: boolean)
	IgnoreTrieModule.SetPathIgnored(self._ignoreTrie, path, ignored)
end

--[=[
	@within TableManager
	@method PromiseValue
	@unreleased
	@param path Path
	@param predicate ((value: any?) -> boolean)?
	@return Promise

	Returns a promise that resolves when the value at `path` satisfies `predicate`.
	If no predicate is provided, resolves when the value at `path` first changes.
]=]
function TableManager.PromiseValue<T, S>(self: TM_Internal<T>, path: Path<S>, predicate: ((value: ValueAtPath<T, S>?) -> boolean)?): Promise<ValueAtPath<T, S>>
	const parsedPath = PathHelpers.ParsePath(path)
	if predicate and predicate(self:Get(parsedPath)) then
		return Promise.resolve(self:Get(parsedPath))
	end

	const prom = Promise.new(function(resolve, reject, onCancel)
		local connection: Connection
		connection = self:OnValueChange(parsedPath, function(newValue)
			if predicate == nil or predicate(newValue) then
				connection:Disconnect()
				resolve(newValue)
			end
		end)

		onCancel(function()
			connection:Disconnect()
		end)
	end)

	self._janitor:AddPromise(prom)
	return prom
end

const addCallbackToList = function(list: { (any) -> () }, callback: (any) -> ()): () -> ()
	table.insert(list, callback)
	return function()
		local i = table.find(list, callback)
		if i then
			table.remove(list, i)
		end
	end
end

--[=[
	@within TableManager
	@private
	Only intended for power users.

	Subscribes to the pre-diff replication op stream: one `AppliedOp` per
	finalized change (a minimal per-leaf delta when a diff already ran for
	some other reason, otherwise the raw new value), with `BatchBegin`/
	`BatchEnd` markers framing a coalesced `Suspend`/`Resume` window.
]=]
function TableManager.OnApplied<T>(self: TM_Internal<T>, callback: (op: AppliedOp) -> ()): () -> ()
	self._appliedListeners = self._appliedListeners or {}
	return addCallbackToList(self._appliedListeners, callback)
end

--[=[
	@within TableManager
	@method OnDestroy
	@param callback () -> ()
	@return () -> () -- Call to unsubscribe.

	Runs a callback when the TableManager is destroyed.
	Useful for cleaning up resources that are tied to the lifetime of the TableManager.
]=]
function TableManager.OnDestroy<T>(self: TM_Internal<T>, callback: () -> ()): () -> ()
	self._destroyListeners = self._destroyListeners or {}
	return addCallbackToList(self._destroyListeners, callback)
end

--[=[
	@within TableManager
	@method Destroy

	Destroy the TableManager and clean up all resources.
]=]
function TableManager.Destroy<T>(self: TM_Internal<T>)
	-- Flag as destroyed up front so any propagation/flush that re-enters during
	-- teardown treats this manager as gone. `Propagation.isTMDestroyed` and
	-- `CoalescedFlush` both gate on `_Destroyed`, and after the `setmetatable(self, nil)`
	-- below the method table is gone -- an observer walk (e.g. a survivor's
	-- `GetLinkedManagers`) that still finds this manager in the weak registry
	-- would otherwise call `:Get` on a methodless table and error.
	self._Destroyed = true

	for _, callback in self._destroyListeners or {} do
		callback()
	end
	-- Tear down anything this manager owns (e.g. a `Map*` derived manager's
	-- subscription to its source) BEFORE dismantling our own subsystems below,
	-- since that teardown writes through `self:Set` to clear output entries.
	self._janitor:Destroy()

	-- Observer entries are weak-keyed by manager, so this manager drops out of
	-- the propagation registry automatically once it is unreferenced; dispatch
	-- also skips `_Destroyed` managers immediately (see `Propagation`).

	const batch = self._batch
	if batch then
		self._batch = nil
		self._batchDepth = 0
	end

	self._listenerRegistry:Destroy()
	const proxyManager = self._proxyManager
	if proxyManager then
		proxyManager:Destroy()
	end

	-- Disconnect all signals
	self.ValueChanged:Destroy()
	self.KeyAdded:Destroy()
	self.KeyRemoved:Destroy()
	self.KeyChanged:Destroy()
	self.ArrayInserted:Destroy()
	self.ArrayRemoved:Destroy()
	self.ArraySet:Destroy()

	setmetatable(self, nil)

	-- Setup No-op Destroy to avoid double-destroying errors
	const tm = self :: any
	tm.Destroy = function() end
	tm.IsDestroyed = function() return true end
end

--[=[
	@within TableManager
	@tag Static
	@function IsDestroyed
	@param manager TableManager
	@return boolean

	Returns `true` once [TableManager:Destroy] has run on `manager`, `false`
	otherwise. Pairs with [TableManager:OnDestroy] for teardown-time checks.

	:::caution Call this as `TableManager.IsDestroyed(manager)`, not `manager:IsDestroyed()`
	`Destroy` strips the instance's metatable, so a colon call (`manager:IsDestroyed()`)
	errors ("attempt to call a nil value") once the manager is already destroyed
	-- there is no longer a method table to resolve `IsDestroyed` through. Calling
	it as a static function on `TableManager` looks it up directly and works in
	both states, which is the whole point of a "was this destroyed?" check.
	:::

	```lua
	TableManager.IsDestroyed(manager) -- safe before AND after manager:Destroy()
	```
]=]
function Static.IsDestroyed(manager: any): boolean
	return getmetatable(manager) == nil
end
-- Also exposed on the instance table so the documented colon alias
-- `manager:IsDestroyed()` keeps resolving (before Destroy strips the metatable).
TableManager.IsDestroyed = Static.IsDestroyed

-- Opacity wrapper constructors (see OpaqueRegistry): mark a value (or a
-- container's direct children) opaque to the diff engine — no clone/freeze/
-- walk of its internals, only identity compares. `Global*` variants register
-- in a registry shared by every TableManager rather than just this one.

--[=[
	@within TableManager
	@tag Static
	@function Opaque
	@param value T
	@return OpaqueWrapper<T>
	Wraps `value` so that, when written, this manager treats it as opaque: it is
	never cloned, frozen, or walked by the diff engine -- only identity-compared.
	The wrapper is unwrapped at write time, so the stored value is the bare inner
	value. Useful for large immutable blobs or foreign objects you don't want the
	diff engine to traverse. See the Opaque Values guide.
]=]
Static.Opaque = OpaqueRegistryModule.Opaque

--[=[
	@within TableManager
	@tag Static
	@function GlobalOpaque
	@param value T
	@return OpaqueWrapper<T>
	Like [TableManager.Opaque], but registers `value` as opaque in a registry
	shared by every TableManager rather than just this one.
]=]
Static.GlobalOpaque = OpaqueRegistryModule.GlobalOpaque

--[=[
	@within TableManager
	@tag Static
	@function OpaqueChildren
	@param value T
	@return OpaqueWrapper<T>
	Wraps a container so that its **direct children** are treated as opaque (each
	child is identity-compared, never cloned/frozen/walked), while the container
	itself is still diffed normally.
]=]
Static.OpaqueChildren = OpaqueRegistryModule.OpaqueChildren

--[=[
	@within TableManager
	@tag Static
	@function GlobalOpaqueChildren
	@param value T
	@return OpaqueWrapper<T>
	Like [TableManager.OpaqueChildren], but registers the children as opaque in a
	registry shared by every TableManager rather than just this one.
]=]
Static.GlobalOpaqueChildren = OpaqueRegistryModule.GlobalOpaqueChildren

export type Static = typeof(Static)

return Static
