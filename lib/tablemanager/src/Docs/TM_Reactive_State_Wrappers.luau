--[=[
	@class TM Reactive State Wrappers

	[TableManager](/api/TableManager) is pure Luau and intentionally ships **no**
	binding to any UI or state-management framework. When you want managed data to
	drive a reactive system — a [Fusion](https://elttob.uk/Fusion/) `Value`, a
	[Vide](https://centau.github.io/vide/) `source`, a React hook — you write a
	small adapter over the listener API and keep it in your own application code.

	This guide shows patterns for a reusable one-way bind for common reactive libraries.
	These are **example functions you write**, not methods the package provides.

	## Choosing when the state re-sets

	You may want to pass through `options` to the listener so the wrapper re-sets only 
	on certain changes.

	- **default (no options)** — re-set whenever the path **or any descendant**
	  changes. Right when the external value mirrors a whole table/subtree and the
	  UI must react to edits *inside* it (bind `"Player"`, re-set when
	  `Player.Health` changes). The re-set hands the framework the same table
	  reference, so lean on the framework's own equality/immutability rules.
	- **`{ ListenDepth = 0, ListenDepthStyle = "==" }`** — the `OnValueChange`
	  behavior: re-set only when the bound path itself is reassigned wholesale.
	  Right for leaf values, or when only a subtree's identity matters.
	- **`{ ListenDepth = n }`** — the middle ground: re-set only for changes down to
	  `n` levels below the path. Mirror a subtree but ignore deep-leaf churn.

	:::caution Build on `OnChange`, not `OnValueChange`
	`OnValueChange` **overwrites** `ListenDepth` / `ListenDepthStyle` internally, so
	passing depth options to it does nothing. Subscribe with `OnChange` so `options`
	takes effect. See the depth rules in
	**[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)**.
	:::

	## ToFusionState

	Mirror a manager path into a Fusion `Value` owned by a `scope`. The binding
	registers its own teardown with the scope, so `scope:doCleanup()` drops it.
	I recommend returning as a `State` (the `Value`'s type) rather than the `Value`
	itself, so callers arent tempted to call `set` on it directly.

	```lua
	local Fusion = require(Packages.Fusion)
	local Value = Fusion.Value
	local peek = Fusion.peek

	local function ToFusionState(scope, manager, path, options)
		local state = Value(scope, manager:Get(path))
		local connection = manager:OnChange(path, function(newValue)
			state:set(newValue)
		end, options)
		table.insert(scope, function()
			connection:Disconnect()
		end)
		return state
	end

	-- Usage:
	local health = ToFusionState(scope, manager, "Player.Health")
	print(peek(health)) -- 100
	manager:Set("Player.Health", 80) -- `health` updates to 80
	```

	Allowing wrappers to take the same optional `options`, so end-users can 
	tune *when* they re-set:

	```lua
	scope.ToFusionState = ToFusionState
	
	-- Re-set on any change under "Player" (health, mana, nested gear...):
	local player = scope:ToFusionState(manager, "Player")

	-- Re-set only when "Player" is swapped wholesale (OnValueChange behavior):
	local player = scope:ToFusionState(manager, "Player",
		{ ListenDepth = 0, ListenDepthStyle = "==" })

	-- Re-set for "Player" and its direct children, ignore deeper churn:
	local player = scope:ToFusionState(manager, "Player", { ListenDepth = 1 })
	```

	## ToVideSource

	The Vide equivalent, using a `source` and `vide.cleanup` for teardown.

	```lua
	local vide = require(Packages.Vide)
	local source = vide.source
	local cleanup = vide.cleanup

	-- Call this within a reactive scope (root / mount / effect / component) so
	-- cleanup() has a scope to attach to. Outside one, disconnect the returned
	-- Connection yourself.
	local function ToVideSource(manager, path, options)
		local src = source(manager:Get(path))
		local connection = manager:OnChange(path, function(newValue)
			src(newValue)
		end, options)
		cleanup(function()
			connection:Disconnect()
		end)
		return src
	end

	-- Usage:
	local health = ToVideSource(manager, "Player.Health")
	print(health()) -- 100
	manager:Set("Player.Health", 80)
	print(health()) -- 80
	```

	## Cleanup

	Both wrappers self-register teardown with their scope, so in the common case you
	do nothing — `scope:doCleanup()` (Fusion) or the reactive scope's destruction
	(Vide) disconnects the binding. Destroying the manager
	([`manager:Destroy()`](/api/TableManager#Destroy)) also disconnects everything.

	## Two-way binding

	These wrappers are one-way (data → view), which is the common UI case. To push
	edits *back* into the manager, drive `manager:Set` from the framework's own
	observer — and guard the feedback loop so a manager-originated update doesn't
	bounce back as a redundant write:

	```lua
	Fusion.Observer(state):onChange(function()
		local next = Fusion.peek(state)
		if next ~= manager:Get(path) then -- only write real changes
			manager:Set(path, next)
		end
	end)
	```

	---
	### See also

	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — the listeners these wrappers build on, and the full `ListenDepth` rules.
	- **[TM For & Map Reactive Views](/api/TM%20For%20&%20Map%20Reactive%20Views)** — built-in reactive views for collections, with automatic per-item cleanup.
	- **[TM Getting Started](/api/TM%20Getting%20Started)** — creating a manager and reading its data.
]=]
