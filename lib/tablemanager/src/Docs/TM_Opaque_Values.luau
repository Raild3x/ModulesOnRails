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

	```lua
	local manager = TableManager.new({
		Enemies = TableManager.OpaqueChildren({}), -- each enemy table is a leaf
	})

	manager:Set("BigBlob", TableManager.Opaque(hugeImmutableTable))
	```

	A change to an opaque value's internals fires nothing; replacing the reference
	fires a single change event at its own slot. Marking is by value reference, so it
	survives array shifts, `MoveTo`, and `Swap`.

	:::note Opacity is per-viewer
	The same live table can be opaque to one manager and transparent to another —
	e.g. an Inventory manager treats a `Sword` table as an opaque leaf while a
	dedicated Sword manager observes it transparently. Opacity is also the boundary
	for implicit cross-manager sharing: an opaque value never propagates.
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

	## When to use opacity

	Reach for opacity when a value is large and immutable (skip the clone/walk cost
	on every diff), when it's a foreign object the diff engine shouldn't traverse, or
	when you deliberately want to hide a shared table's internals from one manager
	while another observes them.

	---
	### See also

	- **[TM Proxies & Direct Table Access](/api/TM%20Proxies%20&%20Direct%20Table%20Access)** — how reads/writes flow, and duplicate references.
	- **[TM Flushing](/api/TM%20Flushing)** — the diff cycle opacity opts out of.
	- **[TM Schema Validation](/api/TM%20Schema%20Validation)** — the other construction-time data control.
]=]
