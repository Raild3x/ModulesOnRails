--[=[
	@class TM Getting Started

	[TableManager](/api/TableManager) wraps a nested Luau table and lets you
	observe and mutate it by path: reads and writes go through the manager, and
	listeners fire for exactly the changes they care about — a single field, a
	whole subtree, an array, or the entire structure.

	This guide walks through the minimal end-to-end setup. For deeper topics see
	the other guides linked at the bottom of the page.

	### 1. Require the module and create a manager

	`TableManager.new(initialData, config?)` takes your initial table and an
	optional [config](/api/TableManager#TableManagerConfig). The data is managed
	in place — `manager.Raw` is the very table you passed in.

	```lua
	local TableManager = require(Packages.TableManager)

	local manager = TableManager.new({
		Player = { Name = "Alice", Health = 100 },
		Inventory = { "Sword", "Shield" },
	})
	```

	:::tip Type Inference
	`TableManager.new` is generic and infers the type of your initial data.
	This allows for autocompletion and type checking for certain methods and properties.
	Due to a bug within Luau, some of this functionality is currently disabled until the bug is fixed.
	:::

	### 2. Reading data

	Use `Get` with a dot-string or an array path. An empty path returns the root
	(the same table as `manager.Raw`).

	```lua
	manager:Get("Player.Health")          -- 100
	manager:Get({ "Player", "Name" })     -- "Alice"
	manager:Get("Inventory")              -- { "Sword", "Shield" }
	```

	### 3. Writing data

	`Set` writes a value at a path; `Update` and `Increment` are convenience
	wrappers over it. Array contents have their own methods — `ArrayInsert`,
	`ArrayRemove`, and friends (see the For & Map and Listeners guides).

	```lua
	manager:Set("Player.Health", 80)
	manager:Update("Player.Health", function(hp) return hp - 10 end)
	manager:Increment("Player.Health", 5)

	manager:ArrayInsert("Inventory", "Potion")   -- append
	manager:ArrayInsert("Inventory", 1, "Bow")   -- insert at index 1
	```

	:::tip Prefer paths over reaching into `Raw`
	Writing through `Set`/`ArrayInsert`/etc. is what fires listeners. Mutating
	`manager.Raw` directly bypasses change detection — see the Proxies & Direct
	Table Access guide for when that is and isn't safe.
	:::

	### 4. Your first listener

	`Observe` fires immediately with the current value and again on every change —
	ideal for binding UI to data. On the initial fire, `metadata` is `nil`.

	```lua
	manager:Observe("Player.Health", function(health, oldHealth, metadata)
		if metadata == nil then
			print("initial health:", health)
		else
			print("health:", oldHealth, "->", health)
		end
	end)

	manager:Set("Player.Health", 50) -- fires: "health: 100 -> 50"
	```

	Every listener returns a `Connection` — hold onto it and call `:Disconnect()`
	when you no longer need it. The full listener surface (path listeners, key and
	array listeners, wildcards, and the global Signals) is covered in the Listeners
	& Fire Modes guide.

	---
	### The config table at a glance

	`TableManager.new`'s second argument is a
	[TableManagerConfig](/api/TableManager#TableManagerConfig):

	| Field | Purpose | Default |
	| --- | --- | --- |
	| `Schema` | Validates the initial data's shape with a [`T`](/api/TableManager#T) check. See the Schema Validation guide. | `nil` (no validation) |
	| `OnValidationFailed` | Observes schema failures before the constructor errors. | `nil` |
	| `ListenerFireMode` | How listener callbacks are scheduled. See the Listeners & Fire Modes guide. | `"bindable"` |
	| `SignalFireMode` | How the per-change Signals are scheduled. See the Listeners & Fire Modes guide. | `"bindable"` |
	| `FlushMode` | Whether writes diff/fire immediately or coalesce to frame-end. See the Flushing guide. | `"immediate"` |
	| `DuplicateReferenceMode` | Whether a table written to a second path shares identity or is cloned. See the Proxies guide. | `"allow"` |
	| `EnableProxies` | Whether `Proxy`/`GetProxy` are available on this manager. | `true` |
	| `IgnoredPaths` | Paths (and descendants) that skip all diff/event work. | `{}` |
	| `FrozenTablesAreOpaque` | Whether shallowly frozen tables are also treated as opaque. See the Opaque Values guide. | `false` |

	The mode defaults can be changed process-wide with
	[`TableManager.SetDefaults`](/api/TableManager#SetDefaults) so you don't have
	to repeat them in every `new` call.

	### 5. Cleanup

	Call `Destroy` when a manager is no longer needed. It disconnects every
	listener and signal, tears down owned `For*`/`Map*` subscriptions, and releases
	proxies. It is idempotent.

	```lua
	local conn = manager:OnValueChange("Player.Health", onHealthChanged)

	manager:OnDestroy(function()
		print("manager torn down")
	end)

	conn:Disconnect()
	manager:Destroy()
	print(TableManager.IsDestroyed(manager)) -- true
	```

	:::tip
	Call `TableManager.IsDestroyed(manager)` rather than `manager:IsDestroyed()`.
	`Destroy` strips the instance's metatable, so the colon form errors once a
	manager is already destroyed -- the static form works in both states.
	:::

	---
	### See also

	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — path/key/array listeners, wildcards, and scheduling.
	- **[TM Flushing](/api/TM%20Flushing)** — the diff-and-fire cycle behind every event.
	- **[TM Batching](/api/TM%20Batching)** — grouping many writes so events fire once.
	- **[TM Proxies & Direct Table Access](/api/TM%20Proxies%20&%20Direct%20Table%20Access)** — the proxy view and its rules.
	- **[TM Schema Validation](/api/TM%20Schema%20Validation)** — validating data shape at construction.
	- **[TM Opaque Values](/api/TM%20Opaque%20Values)** — telling the diff engine to skip certain values.
	- **[TM For & Map Reactive Views](/api/TM%20For%20&%20Map%20Reactive%20Views)** — per-item reconcilers and derived managers.
]=]
