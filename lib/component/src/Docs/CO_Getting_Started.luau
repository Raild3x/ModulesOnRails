--[=[
	@class CO Getting Started

	[Component](/api/Component) binds a reusable, class-based behavior to every
	Roblox instance carrying a CollectionService tag, and gives each one a
	yield-tolerant lifecycle and a guaranteed cleanup path. Tag an instance and its
	component *constructs*; untag it (or destroy it, or move it out of the world)
	and the component *tears down* — automatically. This guide walks the minimal
	end-to-end setup. For the deeper topics, see the guides linked at the bottom.

	### 1. Require the module

	```lua
	local Component = require(Packages.Component)
	```

	### 2. Define a component class

	`Component.new` takes one config table. The only required field is `Tag` — the
	CollectionService tag whose instances this class binds to. Add the lifecycle
	methods (`Construct` / `Start` / `Stop`) to the returned class; each runs on a
	fresh **component instance** with `self.Instance` pointing at the tagged Roblox
	instance.

	```lua
	local Lava = Component.new({
		Tag = "Lava",
		Ancestors = { workspace }, -- only bind instances under here (default: {workspace, Players})
	})

	function Lava:Construct()
		-- Set up state. Runs first, before the instance is "live". Do not touch
		-- other components here — they may not have started yet.
		self.Touched = 0
	end

	function Lava:Start()
		-- The instance is live. Connect events, start loops, read other components.
		print(self.Instance:GetFullName(), "is now hot")
	end

	function Lava:Stop(reason)
		-- Teardown. `reason` says why (see the Lifecycle guide). Anything you
		-- registered with self:AddTask is already being cleaned up for you.
		print("cooling down:", reason)
	end
	```

	:::tip Typed classes
	`Construct` / `Start` / `Stop` may be defined post-hoc as above. Custom methods
	and fields, though, go through the config's `Methods` / `Fields` so the new type
	solver can check them — the class type has no `[string]: any` escape hatch by
	design. See [Component.new](/api/Component#new) for the typed `Methods` /
	`Fields` / `InitFields` pattern.
	:::

	### 3. Bind an instance

	Nothing else to call — binding is by tag. Add the `Lava` tag to any instance
	under a valid ancestor (in Studio's Tag Editor, or from code) and `Construct`
	then `Start` run for it:

	```lua
	local CollectionService = game:GetService("CollectionService")
	CollectionService:AddTag(somePart, "Lava")
	```

	Every tagged instance gets its own independent component instance. Remove the
	tag and that instance's component tears down.

	### 4. Reach a component from its instance

	Given the Roblox instance, `FromInstance` returns its started component instance
	(or `nil` if it has none). This is how systems talk to each other — collision
	handlers, other components, UI:

	```lua
	somePart.Touched:Connect(function(hit)
		local lava = Lava:FromInstance(somePart)
		if lava then
			lava.Touched += 1
		end
	end)
	```

	Enumerate every live instance of a class with `GetAll`:

	```lua
	for _, lava in Lava:GetAll() do
		print(lava.Instance)
	end
	```

	### 5. Clean up with AddTask

	Never disconnect by hand. Register anything cleanup-worthy — connections,
	Instances, Janitors, Promises — on the component's **core Janitor** via
	`self:AddTask`, and it is torn down for you on *every* removal path.

	```lua
	function Lava:Start()
		self:AddTask(self.Instance.Touched:Connect(function(hit)
			-- ...
		end))

		-- Second arg names the cleanup method for non-connection tasks:
		self:AddTask(Instance.new("Fire", self.Instance), "Destroy")
	end
	```

	This is the framework's core guarantee: if `Construct` ran, `Stop` runs and the
	Janitor is destroyed — no matter how the instance goes away.

	---
	### See also

	- **[CO Lifecycle & Cleanup](/api/CO%20Lifecycle%20&%20Cleanup)** — the full phase sequence, yielding, the phase barrier, and every teardown path.
	- **[CO Extensions](/api/CO%20Extensions)** — share behavior across classes with lifecycle hooks and merged methods.
	- **[CO Queries](/api/CO%20Queries)** — find and react to instances across the whole world with `Component.query`.
]=]
