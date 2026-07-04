--[=[
	@class TM Listeners & Fire Modes

	[TableManager](/api/TableManager) exposes changes through two surfaces that
	fire for the same underlying edits: **path listeners** registered at a specific
	path, and **global Signals** that fire for any path. This guide covers both, how
	their scheduling is controlled, and (for advanced cases) the metadata they carry.

	## Path listeners

	Path listeners are registered at a path and return a `Connection` you can
	`:Disconnect()`. `path` may be a dot-string, an array, or a proxy.

	### Value listeners

	- `OnValueChange(path, cb)` → `cb(newValue, oldValue, metadata)` — fires ONLY
	  when `path` itself is directly reassigned.
	- `OnChange(path, cb)` → `cb(newValue, oldValue, metadata)` — fires when `path`
	  is directly reassigned OR any descendant of it changes.
	- `Observe(path, cb)` — immediately calls `cb(currentValue, nil, nil)`, then
	  behaves like `OnValueChange`.

	```lua
	local manager = TableManager.new({ Player = { Health = 100, Mana = 50 } })

	manager:OnValueChange("Player", function()
		print("the Player table was replaced wholesale")
	end)

	manager:OnChange("Player", function()
		print("Player, or something under it, changed")
	end)

	manager:Set("Player.Health", 80)
	-- only OnChange fires: Health changed, but Player itself was not reassigned
	```

	### Key listeners (dictionaries)

	- `OnKeyAdd(path, cb)` → `cb(key, newValue, metadata)` — a new key appears.
	- `OnKeyRemove(path, cb)` → `cb(key, oldValue, metadata)` — a key is set to `nil`.
	- `OnKeyChange(path, cb)` → `cb(key, newValue, oldValue, metadata)` — an
	  existing key is reassigned.

	```lua
	local manager = TableManager.new({ Settings = { Volume = 50 } })

	manager:OnKeyAdd("Settings", function(key, newValue)
		print(`new setting {key} = {newValue}`)
	end)

	manager:Set("Settings.Brightness", 80) -- "new setting Brightness = 80"
	```

	### Array listeners

	For array paths, `path` is the array's path (not the element path). Array
	events come from array-aware diffing, so indices are replay-faithful.

	- `OnArrayInsert(path, cb)` → `cb(index, newValue, metadata)`
	- `OnArrayRemove(path, cb)` → `cb(index, oldValue, metadata)`
	- `OnArraySet(path, cb)` → `cb(index, newValue, oldValue, metadata)` — an
	  existing slot overwritten in place (no shift).

	```lua
	local manager = TableManager.new({ Queue = { "a", "b", "c" } })

	manager:OnArrayRemove("Queue", function(index, oldValue)
		print(`removed {oldValue} from index {index}`)
	end)

	manager:ArrayRemove("Queue", 1) -- "removed a from index 1"
	```

	## Global Signals

	Every manager also exposes Signals that fire for **any** path, carrying the
	path as their first argument:

	`ValueChanged(path, newValue, oldValue)`, `KeyAdded(path, key, newValue)`,
	`KeyRemoved(path, key, oldValue)`, `KeyChanged(path, key, newValue, oldValue)`,
	`ArrayInserted(path, index, newValue)`, `ArrayRemoved(path, index, oldValue)`,
	`ArraySet(path, index, newValue, oldValue)`.

	```lua
	manager.ValueChanged:Connect(function(path, newValue, oldValue)
		print(`{table.concat(path, ".")}: {oldValue} -> {newValue}`)
	end)
	```

	## Listener options

	Every path listener accepts an optional `ListenerOptions` table:

	- `ListenDepth` — `nil` (default) fires for the path or any depth below; `0`
	  fires only AT the path; `n` fires up to `n` levels below.
	- `ListenDepthStyle` — `"<="` (default, at-or-within depth) or `"=="` (exactly
	  that depth).
	- `Once` — auto-disconnect after the first fire. On a wildcard path this is
	  once **total** across all matching keys, not once per key.

	### Wildcards

	A `"*"` segment matches any single key at that position — useful for dynamic
	collections without re-registering on `KeyAdded`. Matched keys are exposed via
	`metadata.WildcardMatches` (left-to-right, one entry per `"*"`).

	```lua
	manager:OnValueChange("Players.*.Health", function(new, old, metadata)
		print(`{metadata.WildcardMatches[1]} health: {old} -> {new}`)
	end)
	```

	## Fire modes

	Two independent settings control *how* callbacks are scheduled when they fire.
	Both accept `"immediate"`, `"deferred"`, `"bindable"`, or `"coalesced"`:

	- **[ListenerFireMode](/api/TableManager#ListenerFireMode)** — path listeners.
	- **[SignalFireMode](/api/TableManager#SignalFireMode)** — the global Signals.

	`"immediate"` runs the callback synchronously; `"deferred"` runs it via
	`task.defer`; `"bindable"` mirrors the engine's actual `SignalBehavior`
	(resolved once at construction); `"coalesced"` is like `"deferred"` but
	collapses repeated fires within the tick into one carrying the latest values.

	Ordering is preserved regardless of mode: a Signal fires before registry
	listeners at each emission point, ancestor delivery walks parent→root, and a
	write made from inside a listener has its events delivered after the current
	dispatch completes.

	### Changing the defaults

	Set the modes per-manager in the config, or change the process-wide defaults
	with [`TableManager.SetDefaults`](/api/TableManager#SetDefaults):

	```lua
	-- Per manager:
	local manager = TableManager.new(data, { SignalFireMode = "coalesced" })

	-- Process-wide default for every manager created afterwards:
	TableManager.SetDefaults({ ListenerFireMode = "deferred" })
	```

	:::caution Defaults are read at construction time
	`SetDefaults` only affects TableManagers created **after** the call — existing
	instances keep the mode they were built with.
	:::

	## Listener metadata (power users)

	:::info Optional
	Every listener callback's last argument is a `ChangeMetadata` table, but most
	code never needs to inspect it beyond a `nil` check (e.g. `Observe`'s initial
	fire, or wildcard matches — see above). This section is for the cases where
	you need finer control.
	:::

	- `Diff` — a `DiffNode` for a **direct** change at the listener's path; `nil`
	  for an ancestor notification. This nil-vs-present split is how a listener
	  tells its own change from a descendant's.
	- `OriginPath` — where the assignment actually happened (same for direct and
	  ancestor notifications).
	- `WildcardMatches` — the matched wildcard keys; `nil` when the path had no wildcards.
	- `Move` / `ArrayOp` — set on array-op events to carry shift semantics.

	```lua
	manager:OnValueChange("Game.World", function(_, _, metadata)
		if metadata.Diff then
			print("directly replaced at Game.World")
		else
			print("descendant changed, originating at", table.concat(metadata.OriginPath, "."))
		end
	end)
	```

	---
	### See also

	- **[TM Getting Started](/api/TM%20Getting%20Started)** — creating a manager and your first listener.
	- **[TM Flushing](/api/TM%20Flushing)** — the diff cycle that decides when these callbacks run.
	- **[TM Batching](/api/TM%20Batching)** — grouping writes so events fire once.
	- **[TM For & Map Reactive Views](/api/TM%20For%20&%20Map%20Reactive%20Views)** — per-item reconcilers built on these listeners.
]=]
