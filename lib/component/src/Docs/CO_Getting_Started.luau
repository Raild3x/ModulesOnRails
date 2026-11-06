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

	function Lava:OnConstruct()
		-- Set up state. Runs first, before the instance is "live". Do not touch
		-- other components here — they may not have started yet.
		self.Touched = 0
	end

	function Lava:OnStart()
		-- The instance is live. Connect events, start loops, read other components.
		print(self.Instance:GetFullName(), "is now hot")
	end

	function Lava:OnStop(reason)
		-- Teardown. `reason` says why (see the Lifecycle guide). Anything you
		-- registered with self:AddTask is already being cleaned up for you.
		print("cooling down:", reason)
	end
	```

	The legacy spellings (`Construct` / `Start` / `Stop`, `HeartbeatUpdate` /
	`SteppedUpdate` / `RenderSteppedUpdate`) still work through v1.x; the `On*`
	form wins when both are defined and is the documented spelling going forward.

	:::tip Typed classes
	Lifecycle methods may be defined post-hoc as above. Custom methods and
	fields, though, go through the config's `Methods` / `Fields` so the new type
	solver can check them — the class type has no `[string]: any` escape hatch by
	design. See [Component.new](/api/Component#new) for the typed `Methods` /
	`Fields` / `InitFields` pattern.
	:::

	### 2b. Or bind by selector instead of a tag

	A class can attach by a **selector-dialect match** instead of a raw tag:
	ClassName (IsA semantics), `#Name`, `.Tag`, `[Property = value]`,
	`[$Attribute op value]` terms and `:not(...)` compose into one string, and
	instances construct/tear down as they start/stop matching — no tagging
	required. `Ancestors` scopes the match (each entry is a watched root).

	```lua
	local Lava = Component.new({
		Selector = [[BasePart.Lava[Anchored = true][$Heat >= 1]]],
		Ancestors = { workspace.Map },
	})
	```

	A component stopped because its instance stopped matching (while still in
	the world) gets the `"SelectorUnmatched"` stop reason. Exactly one of
	`Tag` / `Selector` must be given. See the Queries guide for the full
	dialect grammar. `Class:SetEnabled(false)` pauses a whole class (stop
	reason `"Disabled"`), and `SetEnabled(true)` reconstructs current matches —
	including instances that appeared while disabled.

	### 2c. Member event hooks

	Any other `On`-prefixed method is a **member hook**, live from the moment
	an instance finishes constructing until it tears down, and cleaned up
	automatically. Hooks may be declared at any time (even after instances
	exist — they connect immediately), but each name is declare-once: a second
	definition, or assigning a non-function, is an error, same as native
	Collection callbacks. See the Lifecycle guide for the full contract.

	```lua
	function Lava:OnTouched(otherPart) -- instance.Touched, auto-managed
		self:Burn(otherPart)
	end

	function Lava.OnAttributeChanged.Heat(self) -- dot form + explicit self!
		self.Damage = self.Instance:GetAttribute("Heat") * 10
	end

	function Lava.OnPropertyChanged.Anchored(self)
		print("anchoring changed")
	end
	```

	:::caution
	Use the DOT form with an explicit `self` for the namespace hooks — the
	colon form (`function Lava.OnAttributeChanged:Heat()`) would bind `self`
	to the namespace table, not the component.
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
