--!strict
--[=[
	@ignore
	@class ForMap

	Shared identity-based reconcile drivers behind `ForKeys`/`ForValues`/`ForPairs`
	and `MapKeys`/`MapValues`/`MapPairs` (see TMTypes.luau for the public semantics
	table; TableManager.luau's For/Map methods are thin call-throughs into here).
]=]

--// Imports //--
const PathHelpers = require("./PathHelpers")
const JanitorModule = require("../Janitor")
const ChangeDetectorModule = require("./Diffing/ChangeDetector")
const ListenerRegistryModule = require("./Listening/ListenerRegistry")
const TMTypes = require("./TMTypes")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type Janitor = JanitorModule.Janitor
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type Connection = ListenerRegistryModule.Connection
type ForOptions = TMTypes.ForOptions
type TM_Internal<T> = TMTypes.TM_Internal<T>

const ForMap = {}

type ForItem = {
	Value: any,
	Janitor: Janitor,
}

type ValueItem = {
	Janitor: Janitor,
}

-- Wires the `OnChange` listener that drives `reconcile` and the initial fire
-- (deferred per `options.Defer`/the registry's fire-deferred mode, mirroring
-- `Observe`). Unlike `Observe`, the listener is registered BEFORE the initial
-- fire is scheduled: if the initial reconcile yields (a handler awaits
-- something), a change arriving mid-reconcile must still be observed instead
-- of silently lost. `reconcile` is idempotent against the live table, so a
-- redundant extra pass triggered by this ordering is harmless.
function ForMap.wireReconcileConnection(
	self: TM_Internal<any>,
	parsedPath: PathArray,
	reconcile: (metadata: ChangeMetadata?) -> (),
	teardownAll: () -> (),
	options: ForOptions?,
	wrapInitialFire: ((fire: () -> ()) -> ())?
): Connection
	const listenerConnection = self:OnChange(parsedPath, function(_newValue, _oldValue, metadata)
		reconcile(metadata)
	end, { ListenDepth = 1 })

	if options == nil or options.FireForExisting ~= false then
		const function fireInitial()
			if wrapInitialFire then
				wrapInitialFire(function()
					reconcile(nil)
				end)
			else
				reconcile(nil)
			end
		end

		self._fireScheduler:RunInitial(fireInitial, options and options.Defer)
	end

	const connection = {} :: Connection
	connection.Connected = true
	connection.Disconnect = function(conn: Connection)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		listenerConnection:Disconnect()
		teardownAll()
	end

	return connection
end

--[=[
	Shared driver for `ForKeys`/`ForPairs`/`MapKeys`/`MapValues`/`MapPairs`:
	items are tracked BY KEY. When `recreateOnValueChange` is true
	(`ForPairs`/`MapValues`/`MapPairs`), a value change at an existing key
	tears down the old item and runs `onAdd` again for the new one. When false
	(`ForKeys`/`MapKeys`), a value change at an existing key calls `onRefresh`
	instead and the item (and its Janitor) stays alive.
]=]
function ForMap.makeKeyedReconciler(
	self: TM_Internal<any>,
	parsedPath: PathArray,
	recreateOnValueChange: boolean,
	onAdd: (itemJanitor: Janitor, key: any, value: any, metadata: ChangeMetadata?) -> (),
	onRemove: ((item: ForItem, key: any) -> ())?,
	onRefresh: ((item: ForItem, key: any, newValue: any, metadata: ChangeMetadata?) -> ())?,
	options: ForOptions?,
	wrapInitialFire: ((fire: () -> ()) -> ())?
): Connection
	const items: { [any]: ForItem } = {}

	const function destroyItem(key: any, item: ForItem)
		items[key] = nil
		if onRemove then
			onRemove(item, key)
		end
		item.Janitor:Destroy()
	end

	const function reconcile(metadata: ChangeMetadata?)
		const current = self:Get(parsedPath, true)

		-- Removal pass first (safe to nil existing table keys mid `pairs`/`for...in`).
		for key, item in items do
			if type(current) ~= "table" or (current :: any)[key] == nil then
				destroyItem(key, item)
			end
		end

		if type(current) ~= "table" then
			return
		end

		for key, value in current :: any do
			const item = items[key]
			if item == nil then
				const itemJanitor = JanitorModule.new()
				items[key] = { Value = value, Janitor = itemJanitor }
				onAdd(itemJanitor, key, value, metadata)
			elseif item.Value ~= value then
				if recreateOnValueChange then
					destroyItem(key, item)
					const itemJanitor = JanitorModule.new()
					items[key] = { Value = value, Janitor = itemJanitor }
					onAdd(itemJanitor, key, value, metadata)
				else
					item.Value = value
					if onRefresh then
						-- luau is being dumb and thinks onRefresh is still nil for some reason
						(onRefresh :: any)(item, key, value, metadata)
					end
				end
			end
		end
	end

	const function teardownAll()
		for key, item in items do
			destroyItem(key, item)
		end
	end

	return ForMap.wireReconcileConnection(self, parsedPath, reconcile, teardownAll, options, wrapInitialFire)
end

--[=[
	Shared driver for `ForValues`: items are tracked BY VALUE as a multiset, so
	duplicate values are tracked as independent items and a value moving
	between keys/indices does not re-run `onAdd`.
]=]
function ForMap.makeValueReconciler(
	self: TM_Internal<any>,
	parsedPath: PathArray,
	onAdd: (itemJanitor: Janitor, value: any, metadata: ChangeMetadata?) -> (),
	options: ForOptions?
): Connection
	const items: { [any]: { ValueItem } } = {}

	const function reconcile(metadata: ChangeMetadata?)
		const current = self:Get(parsedPath, true)
		const counts: { [any]: number } = {}

		if type(current) == "table" then
			for _, value in current :: any do
				counts[value] = (counts[value] or 0) + 1
			end
		end

		for value, count in counts do
			local list = items[value]
			if list == nil then
				list = {}
				items[value] = list
			end
			while #list < count do
				const itemJanitor = JanitorModule.new()
				table.insert(list, { Janitor = itemJanitor })
				onAdd(itemJanitor, value, metadata)
			end
			while #list > count do
				const item = table.remove(list) :: ValueItem
				item.Janitor:Destroy()
			end
		end

		for value, list in items do
			if counts[value] == nil then
				for _, item in list do
					item.Janitor:Destroy()
				end
				items[value] = nil
			end
		end
	end

	const function teardownAll()
		for _, list in items do
			for _, item in list do
				item.Janitor:Destroy()
			end
		end
		table.clear(items)
	end

	return ForMap.wireReconcileConnection(self, parsedPath, reconcile, teardownAll, options, nil)
end

--[=[
	Wires `connection`'s lifecycle to `derived` (disconnect-on-destroy). Every
	`Map*` method's derived manager needs this exact line — shared here so
	`MapKeys`/`MapValues`/`MapPairs` don't each repeat it.
]=]
function ForMap.attachDerivedLifecycle(derived: TM_Internal<any>, connection: Connection)
	derived._janitor:Add(connection, "Disconnect")
end

--[=[
	Batches a `Map*` method's initial reconcile pass into one flush — the
	shared `wrapInitialFire` shape every `makeKeyedReconciler` call below
	passes through.
]=]
function ForMap.batchedInitialFire(derived: TM_Internal<any>): (fire: () -> ()) -> ()
	return function(fire: () -> ())
		derived:Batch(fire)
	end
end

--[=[
	Shared "remap source key -> derived output key" `onAdd`/`onRemove`/
	`onRefresh` trio used by `MapKeys`/`MapPairs`: `computeOutKey` returns
	`(outKey, outValue)`; `onRemove`/`onRefresh` look up the recorded `outKey`
	(the source key may already be gone by `onRemove` time) to clear or update
	that derived slot. `MapPairs` (which recreates on value change) never
	invokes the returned `onRefresh` — only `MapKeys` wires it up.
]=]
function ForMap.makeKeyRemapHandlers(
	derived: TM_Internal<any>,
	computeOutKey: (itemJanitor: Janitor, key: any, value: any) -> (any, any)
): (
	(itemJanitor: Janitor, key: any, value: any) -> (),
	(item: any, key: any) -> (),
	(item: any, key: any, newValue: any) -> ()
)
	const outKeys: { [any]: any } = {}

	const function onAdd(itemJanitor: Janitor, key: any, value: any)
		const outKey, outValue = computeOutKey(itemJanitor, key, value)
		outKeys[key] = outKey
		derived:Set(outKey, outValue)
	end

	const function onRemove(_item: any, key: any)
		const outKey = outKeys[key]
		outKeys[key] = nil
		if outKey ~= nil then
			derived:Set(outKey, nil)
		end
	end

	const function onRefresh(_item: any, key: any, newValue: any)
		const outKey = outKeys[key]
		if outKey ~= nil then
			derived:Set(outKey, newValue)
		end
	end

	return onAdd, onRemove, onRefresh
end

return ForMap
