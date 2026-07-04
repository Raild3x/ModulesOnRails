--[=[
	@class TM For & Map Reactive Views

	The `For*` and `Map*` methods turn a collection inside a
	[TableManager](/api/TableManager) into a reactive view: a per-item reconciler
	that runs setup as items appear and teardown as they leave, or a derived
	manager whose contents are computed from a source. This guide covers both.

	## The reconciler model

	Each `For*` method calls your handler once per item and hands it a per-item
	[Janitor](/api/Janitor). Everything you add to that Janitor is cleaned up
	automatically when the item leaves the collection (removed, replaced, or the
	subscription disconnects). You never manually track which items came and went.

	All `For*` methods return a `Connection`; disconnect it (or destroy the
	manager) to tear down every item's Janitor at once.

	## ForKeys / ForValues / ForPairs

	The three differ in what counts as "the same item", i.e. when the handler
	re-runs versus stays put:

	- **`ForKeys(path, handler, options?)`** — reconciles by KEY. The handler runs
	  once per key and is NOT re-run when the value at an existing key changes. The
	  Janitor is destroyed when the key is removed.
	- **`ForValues(path, handler, options?)`** — reconciles by VALUE (as a
	  multiset). The handler runs once per value occurrence and is NOT re-run when
	  that value moves between keys/indices (e.g. an `ArraySwapRemove`).
	- **`ForPairs(path, handler, options?)`** — reconciles by KEY AND VALUE. The
	  handler re-runs (tearing down the previous Janitor first) whenever either the
	  key or the value changes.

	```lua
	local manager = TableManager.new({
		Enemies = { goblin = { hp = 10 }, orc = { hp = 20 } },
	})

	manager:ForKeys("Enemies", function(itemJanitor, key)
		local model = spawnEnemyModel(key)
		itemJanitor:Add(model) -- destroyed automatically when `key` is removed
	end)
	```

	### ForOptions

	Both `For*` and their handlers accept a [ForOptions](/api/TableManager#ForOptions):

	- `FireForExisting` — defaults to `true`: run the handler for items already
	  present when you subscribe. Set `false` to react only to future items.
	- `Defer` — defer the initial fire (a non-immediate `ListenerFireMode` defers
	  it anyway).

	The handler's last argument is the same `ChangeMetadata` as a listener — `nil`
	on the initial fire.

	## MapKeys / MapValues / MapPairs

	Where `For*` runs side effects, `Map*` produces a **new, live TableManager**
	derived from the source:

	- **`MapKeys(path, transform)`** — output keyed by `transform(janitor, key,
	  value)`, values passed through unchanged. `transform` re-runs only when a
	  source key is added/removed.
	- **`MapValues(path, transform)`** — output keyed by the source key, each entry
	  recomputed via `transform(janitor, value, key)` when its value changes.
	- **`MapPairs(path, transform)`** — `transform(janitor, key, value)` returns
	  `(outputKey, outputValue)`; the entry recomputes when the source key or value
	  changes. On an output-key collision, the last write wins.

	```lua
	-- A view of enemy display names keyed by id:
	local names = manager:MapValues("Enemies", function(_janitor, enemy, id)
		return `{id} ({enemy.hp} HP)`
	end)

	names:Observe("goblin", function(label)
		print(label)
	end)
	```

	The returned manager **owns** the source subscription: destroying it
	disconnects from the source and tears down every entry's Janitor. Destroying
	the SOURCE does not cascade-destroy the derived manager — their lifecycles are
	independent.

	:::info Unreleased
	The `Map*` methods are marked `@unreleased`. The API described here may change
	before they are stabilized.
	:::

	---
	### See also

	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — the listeners these reconcilers are built on.
	- **[TM Getting Started](/api/TM%20Getting%20Started)** — creating and reading a manager.
	- **[TM Flushing](/api/TM%20Flushing)** — how initial fires interact with deferred scheduling.
]=]
