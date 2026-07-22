--[=[
	@class TM Proxies & Direct Table Access

	A **proxy** is a live, write-through view of a table inside a
	[TableManager](/api/TableManager). Reading through it returns nested proxies;
	writing through it routes back into the manager exactly as `Set` would, firing
	all the normal events. This guide covers what proxies can and can't do, and how
	to safely work with the raw data underneath.

	## Getting a proxy

	`manager.Proxy` is the root proxy; `manager:GetProxy(path)` returns the proxy
	for a nested table (or the raw value if the path isn't a table).

	```lua
	local manager = TableManager.new({ Player = { Health = 100 } })

	manager.Proxy.Player.Health = 80        -- fires ValueChanged, like Set
	print(manager.Proxy.Player.Health)      -- 80
	```

	## What works

	Proxies are userdata backed by metamethods, so most table syntax works
	transparently:

	- `#proxy` — length, via `__len`.
	- `for k, v in proxy do` — generic iteration, via `__iter`.
	- `proxy.key` / `proxy.key = value` — indexing and assignment.
	- `proxy1 == proxy2` — two proxies wrapping the same underlying table are equal.
	- `tostring(proxy)` — readable identification.

	```lua
	local manager = TableManager.new({ Items = { "a", "b", "c" } })

	print(#manager.Proxy.Items)             -- 3
	for i, item in manager.Proxy.Items do   -- generic for, NOT ipairs
		print(i, item)
	end
	```

	## What doesn't work

	Because a proxy is userdata, not a table, some operations that expect a real
	table fail:

	- **`pairs`/`ipairs`** — use generic `for k, v in proxy do` instead.
	- **`table.*` functions** (`table.insert`, `table.remove`, …) — use the
	  manager's array methods (`ArrayInsert`, `ArrayRemove`, …), which also fire
	  events.
	- **`proxy == originalTable`** — a proxy and its raw table have different
	  identities; `__eq` only applies proxy-to-proxy. Compare against the raw value
	  from `Get` instead (see below).
	- **`rawget`/`rawset`** — these bypass the metamethods.
	- **Proxies as table keys** — a proxy and its original are distinct keys. Pick
	  one and use it consistently as a key.

	```lua
	-- Bad:
	table.insert(manager.Proxy.Items, "d")     -- no-op; Items is a proxy
	if manager.Proxy == manager.Raw then end   -- always false

	-- Good:
	manager:ArrayInsert("Items", "d")          -- fires ArrayInserted
	if manager:Get("Items") == someRawTable then end -- Get returns the raw value
	```

	## Multi-location references and DuplicateReferenceMode

	Writing the same table to a second path is a supported feature. Which of two
	behaviors you get is set by
	[`DuplicateReferenceMode`](/api/TableManager#DuplicateReferenceMode):

	- `"allow"` (default) — both paths **share identity**; a write through one is
	  visible at the other, and each location fires its own events. A shared table
	  has a single proxy reporting one "primary anchor" (whichever path created it
	  first).
	- `"copy"` — the second write stores an **independent deep clone**, so the two
	  paths diverge.

	```lua
	local a = TableManager.new(data, { DuplicateReferenceMode = "copy" })
	```

	## Opting out of proxies

	Pass `EnableProxies = false` to skip building the proxy graph entirely. Then
	`manager.Proxy` is `nil` and `GetProxy` errors — read with `Get` and write with
	`Set`/the array methods.

	```lua
	local manager = TableManager.new(data, { EnableProxies = false })
	manager:Set("Player.Health", 80) -- proxies unavailable; Set still works
	```

	## Bypassing the manager

	If external code mutates `manager.Raw` (or a table you hold a reference to)
	directly, the manager doesn't see it and no events fire. The supported recovery
	is `Flush(path)`, which diffs that branch and fires whatever changed — see the
	Flushing guide. Prefer writing through the API so this never comes up.

	---
	### See also

	- **[TM Flushing](/api/TM%20Flushing)** — `Flush` for surfacing bypassed writes.
	- **[TM Opaque Values](/api/TM%20Opaque%20Values)** — marking tables so the diff engine leaves them alone.
	- **[TM Getting Started](/api/TM%20Getting%20Started)** — reading and writing basics.
]=]
