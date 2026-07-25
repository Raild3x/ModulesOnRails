--[=[
	@class CO Extensions

	An **extension** is a table that hooks into the [Component](/api/Component)
	lifecycle. Where a component class *is* one behavior, an extension is a slice of
	behavior you attach to *many* classes — logging, replication, pooling, a debug
	overlay — without editing any of them. Extensions contribute per-phase hooks,
	class methods, a construction veto, and their own dependencies.

	### 1. Attach an extension

	Pass extensions in the config's `Extensions` array. Every instance of the class
	then runs the extension's hooks around its own lifecycle.

	```lua
	local LogExtension = {
		Starting = function(component)
			print("starting", component.Instance:GetFullName())
		end,
		Stopped = function(component)
			print("stopped", component.Instance)
		end,
	}

	local Enemy = Component.new({
		Tag = "Enemy",
		Extensions = { LogExtension },
	})
	```

	### 2. The six hooks

	An extension may define any of these. Each receives the component instance.
	They mirror the component's own lifecycle methods but run *around* them, and one
	extension's hooks fire for every class that lists it.

	| Hook | Runs | Relative to the component's own method |
	| --- | --- | --- |
	| `Constructing` | before construction | before `Construct` |
	| `Constructed` | after construction | after `Construct` — the instance is now tracked |
	| `Starting` | before startup | before `Start` |
	| `Started` | after startup | after `Start` |
	| `Stopping` | before teardown | before `Stop` |
	| `Stopped` | after teardown | after `Stop`, before the Janitor destroy |

	`Constructing` / `Constructed` may **yield or return a Promise**; the construct
	chain waits for them. `Starting` / `Started` / `Stopping` / `Stopped` are plain
	callbacks. See [CO Lifecycle & Cleanup](/api/CO%20Lifecycle%20&%20Cleanup) for
	exactly when each phase runs and how yielding is coordinated.

	### 3. Veto construction with ShouldConstruct

	`ShouldConstruct` runs before anything else and returns `false` to skip this
	instance entirely — no component is built. Every extension's `ShouldConstruct`
	must pass; a single `false` vetoes.

	```lua
	local ServerOnly = {
		ShouldConstruct = function(component)
			return game:GetService("RunService"):IsServer()
		end,
	}
	```

	`ShouldExtend` is the finer, per-instance toggle: it decides whether *this
	extension* applies to *this* instance (evaluated once), while the component
	still constructs.

	### 4. Contribute methods

	An extension's `Methods` are merged onto the component **class**, so instances
	call them like any other method. A name collision with a class member or another
	extension's method is an error — methods never silently shadow.

	```lua
	local Healthful = {
		Methods = {
			Heal = function(component, amount)
				component.Health = math.min(component.MaxHealth, component.Health + amount)
			end,
		},
	}

	local Enemy = Component.new({ Tag = "Enemy", Extensions = { Healthful } })
	-- later, on a component instance:
	enemy:Heal(10)
	```

	### 5. Depend on other extensions

	An extension may list its own dependencies in a nested `Extensions` array. They
	are resolved in **topological order** — a dependency's hook for a phase finishes
	before the dependent's hook for that phase starts — and shared dependencies are
	included once.

	```lua
	local Replicated = {
		Extensions = { NetworkIdentity }, -- Replicated's hooks run after NetworkIdentity's
		Started = function(component)
			replicate(component.NetworkId) -- set up by NetworkIdentity.Started
		end,
	}
	```

	:::info Order guarantees, not a scheduler
	Only edges you declare are ordered. Two extensions with no dependency between
	them run **concurrently** within a phase — don't rely on array position for
	ordering; add a dependency edge if one truly needs the other first.
	:::

	---
	### See also

	- **[CO Lifecycle & Cleanup](/api/CO%20Lifecycle%20&%20Cleanup)** — when each hook phase runs, and how the phase barrier coordinates yielding hooks.
	- **[CO Getting Started](/api/CO%20Getting%20Started)** — defining the component classes extensions attach to.
]=]
