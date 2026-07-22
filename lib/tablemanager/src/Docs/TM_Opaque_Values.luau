--[=[
	@class TM Opaque Values

	By default a [TableManager](/api/TableManager) walks into every table to detect
	nested changes. Marking a value **opaque** tells the diff engine to treat it as
	an indivisible leaf: it is never cloned, frozen, or walked — only its identity is
	compared. Use it for large immutable blobs, foreign objects, or anything whose
	internals you never observe through this manager.

	## Marking values opaque

	Wrap a value at write time with one of the constructors:

	- [`TableManager.Opaque(value)`](/api/TableManager#Opaque) — this value is an
	  opaque leaf for this manager.
	- [`TableManager.OpaqueChildren(container)`](/api/TableManager#OpaqueChildren) —
	  the container is diffed normally, but its direct table children are opaque
	  leaves.
	- `GlobalOpaque` / `GlobalOpaqueChildren` — same, but registered in a registry
	  shared by every manager rather than just this one.

	The wrapper is unwrapped at write time, so what actually lands in the table is
	the bare inner value — the wrapper only carries the "treat this as opaque"
	instruction. Marking is by value **reference**, so it survives array shifts,
	`MoveTo`, and `Swap`. A change to an opaque value's internals fires nothing;
	replacing the reference fires a single change event at its own slot.

	### `Opaque` — one indivisible leaf

	Reach for `Opaque` when a single value should be compared by identity only.

	```lua
	local manager = TableManager.new({})

	-- A large immutable blob: skip the per-diff clone/walk of thousands of entries.
	manager:Set("WorldSnapshot", TableManager.Opaque(hugeReadOnlyTable))

	-- A foreign object the diff engine should never traverse.
	manager:Set("Model", TableManager.Opaque(workspace.Rig))          -- a Roblox Instance
	manager:Set("Profile", TableManager.Opaque(profileStore.Data))    -- ProfileStore-owned data

	-- Replacing the reference still fires ONE change at "WorldSnapshot";
	-- mutating the blob's internals fires nothing (identity is unchanged).
	manager:Set("WorldSnapshot", nextSnapshot)
	```

	### `OpaqueChildren` — a collection of leaves

	When a container holds many entries that are each individually indivisible,
	mark the *container* once so every current AND future direct child is opaque —
	you don't have to wrap each element on insert.

	```lua
	local manager = TableManager.new({
		Enemies = TableManager.OpaqueChildren({}),  -- each enemy table is a leaf
	})

	-- No per-element wrapping needed: later inserts are opaque automatically.
	manager:ArrayInsert("Enemies", { Id = 1, Hp = 100, Ai = {} })
	manager:ArrayInsert("Enemies", { Id = 2, Hp = 100, Ai = {} })

	-- The container itself is still diffed: add/remove of an enemy fires
	-- ArrayInserted/ArrayRemoved. Only each enemy's *internals* are hidden.
	manager:OnArrayInsert("Enemies", function(index, enemy)
		print("spawned enemy", enemy.Id)
	end)
	```

	### `GlobalOpaque` / `GlobalOpaqueChildren` — shared across every manager

	Use the global variants for reference data that is opaque everywhere, so you
	mark it once instead of per manager. Ideal for shared, immutable lookup tables.

	```lua
	local ItemDefs = require(ReplicatedStorage.ItemDefinitions)
	TableManager.GlobalOpaque(ItemDefs) -- mark once, at startup

	-- Every manager that stores ItemDefs now treats it as an opaque leaf:
	local a = TableManager.new({ Defs = ItemDefs })
	local b = TableManager.new({ Cache = { Defs = ItemDefs } })
	```

	### Per-viewer opacity

	Opacity is a property of *the viewer*, not the value: the same live table can be
	opaque to one manager and transparent to another. This lets one system hold a
	coarse view while another observes the detail.

	```lua
	local sword = { Name = "Sword", Enchant = { Level = 1 } }

	-- The inventory only cares that a sword is present/absent — treat it as a leaf.
	local inventory = TableManager.new({ Items = TableManager.OpaqueChildren({}) })
	inventory:ArrayInsert("Items", sword)

	-- A dedicated manager rooted at the SAME table observes its internals fully.
	local swordManager = TableManager.new(sword)
	swordManager:OnValueChange("Enchant.Level", function(lvl)
		print("enchant now", lvl)
	end)

	swordManager:Set("Enchant.Level", 2) -- swordManager fires; inventory stays silent
	```

	:::note Opacity is the sharing boundary
	Opacity is also the boundary for implicit cross-manager sharing: an opaque value
	never propagates. In the example above, mutating the sword through
	`swordManager` does not fan out to `inventory`, precisely because `inventory`
	holds it opaquely.
	:::

	## Frozen tables

	A **deeply** frozen table (every table-typed descendant also frozen) is always
	treated as opaque — that case is provably immutable, so there's nothing to diff.
	Set `FrozenTablesAreOpaque = true` to extend the same trust to **shallowly**
	frozen tables, treating the freeze as an opt-in immutability assertion the way
	`Opaque` is.

	```lua
	local manager = TableManager.new(data, { FrozenTablesAreOpaque = true })
	```

	## How to best leverage opacity

	Opacity is a performance-and-scoping tool. It pays off most when:

	- **The value is large and immutable.** Skipping the per-diff clone/walk of a
	  big blob turns an O(n) cost into an O(1) identity compare. Use `Opaque` (or a
	  deeply frozen table).
	- **The value is foreign.** Roblox `Instance`s, `ProfileStore` data, userdata, or
	  any object with custom `__eq`/`__index` should not be traversed by the diff
	  engine — `Opaque` keeps it out.
	- **You have a collection of self-contained items.** Mark the container with
	  `OpaqueChildren` once so every element is a leaf; you still get add/remove
	  events for the collection, just not spurious "a field deep inside item 37
	  changed" churn.
	- **You want to scope observation.** Give a coarse view an opaque handle and a
	  detailed view a transparent one (the per-viewer pattern above), which also
	  stops the two from implicitly sharing.
	- **The data is shared and read-only.** Mark it once with `GlobalOpaque` instead
	  of per manager.

	When **not** to use it: a value you actually want to observe through this
	manager. Making it opaque hides exactly the changes you'd otherwise get events
	for — reach for [Ignored Paths](/api/TableManager#TableManagerConfig) instead if
	the goal is "don't fire for writes here", or just leave it transparent.

	See the [Performance](/api/TM%20Performance) guide for how opacity fits with the
	other diff-cost optimizations.

	---
	### See also

	- **[TM Proxies & Direct Table Access](/api/TM%20Proxies%20&%20Direct%20Table%20Access)** — how reads/writes flow, and duplicate references.
	- **[TM Flushing](/api/TM%20Flushing)** — the diff cycle opacity opts out of.
	- **[TM Performance](/api/TM%20Performance)** — opacity alongside the other internal optimizations.
	- **[TM Schema Validation](/api/TM%20Schema%20Validation)** — the other construction-time data control.
]=]
