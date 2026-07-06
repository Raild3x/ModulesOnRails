--[=[
	@class TM Listeners & Fire Modes

	[TableManager](/api/TableManager) exposes changes through two surfaces that
	fire for the same underlying edits: **path listeners** registered at a specific
	path, and **global Signals** that fire for any path. This guide covers both, how
	their scheduling is controlled, and (for advanced cases) the metadata they carry.

	---
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

	---
	## Listener options

	Every path listener accepts an optional `ListenerOptions` table:

	- `ListenDepth` — `nil` (default) fires for the path or any depth below; `0`
	  fires only AT the path; `n` fires up to `n` levels below.
	- `ListenDepthStyle` — `"<="` (default, at-or-within depth) or `"=="` (exactly
	  that depth).
	- `Once` — auto-disconnect after the first fire. On a wildcard path this is
	  once **total** across all matching keys, not once per key.

	### Controlling reach with ListenDepth

	"Depth" is how many levels *below* the registered path a change happened. A
	change AT the path is depth `0`; a change to one of its direct children is
	depth `1`; a grandchild is depth `2`, and so on. `ListenDepth` caps how far
	down the tree a change can be and still notify the listener.

	```lua
	local manager = TableManager.new({
		Game = { World = { Weather = { Rain = 0 } } },
	})
	```

	Registering at `"Game.World"`, the same edit reaches the listener differently
	depending on `ListenDepth`:

	| `ListenDepth` | `World` replaced (depth 0) | `Weather` replaced (depth 1) | `Rain` changed (depth 2) |
	| --- | --- | --- | --- |
	| `nil` (default) | fires | fires | fires |
	| `0` | fires | — | — |
	| `1` | fires | fires | — |

	```lua
	-- Only care about the World subtree's immediate shape, not deep leaf edits:
	manager:OnChange("Game.World", function()
		print("World or one of its direct children changed")
	end, { ListenDepth = 1 })

	manager:Set("Game.World.Weather", {}) -- fires (depth 1)
	manager:Set("Game.World.Weather.Rain", 5) -- does NOT fire (depth 2)
	```

	`ListenDepthStyle` decides whether the number is a ceiling or an exact match.
	`"<="` (default) fires at-or-within the depth; `"=="` fires ONLY for changes
	at exactly that depth — e.g. `ListenDepth = 1, ListenDepthStyle = "=="` fires
	for a direct child but not for the path itself or a grandchild.

	This is also what separates the two value listeners: `OnChange` is an
	unbounded `ListenDepth = nil`, while `OnValueChange` is exactly
	`ListenDepth = 0, ListenDepthStyle = "=="` — fire only when the path itself is
	reassigned.

	:::info Depth is measured from `OriginPath`
	The level compared against `ListenDepth` is
	`#metadata.OriginPath - #registeredPath` (clamped at ≥ 0) — the distance from
	your listener's path down to where the assignment actually happened.
	:::

	### Wildcards

	A `"*"` segment matches any key at that position, so one listener covers a
	dynamic collection without re-registering on `KeyAdded`. The matched keys
	arrive on `metadata.WildcardMatches` (left-to-right, one entry per `"*"`).

	```lua
	manager:OnValueChange("Players.*.Health", function(new, old, metadata)
		print(`{metadata.WildcardMatches[1]} health: {old} -> {new}`)
	end)
	```

	The same grammar works for writes and bulk reads. See the dedicated
	**[TM Wildcards](/api/TM%20Wildcards)** guide for the full rules (multiple
	wildcards, `Set`/`Update`/`Increment` fan-out, `GetMatching`, and the
	`Once`-fires-once-total caveat).

	---
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

	---
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

	---
	### See also

	- **[TM Getting Started](/api/TM%20Getting%20Started)** — creating a manager and your first listener.
	- **[TM Wildcards](/api/TM%20Wildcards)** — `"*"` paths for listeners, writes, and bulk reads.
	- **[TM Flushing](/api/TM%20Flushing)** — the diff cycle that decides when these callbacks run.
	- **[TM Batching](/api/TM%20Batching)** — grouping writes so events fire once.
	- **[TM For & Map Reactive Views](/api/TM%20For%20&%20Map%20Reactive%20Views)** — per-item reconcilers built on these listeners.
]=]
