--[=[
	@class CO Lifecycle & Cleanup

	Every [Component](/api/Component) instance moves through a fixed sequence of
	**phases**, and always leaves through the same teardown path. This guide covers
	that sequence, what "yield-tolerant" actually means (the phase barrier), and the
	cleanup guarantee that lets you stop writing disconnect code.

	### 1. The phases

	A component instance is always in one of these, reported by
	`self:GetLifecycleStatus()`:

	```
	None → Constructing → Constructed → Starting → Started
	                                                  ↓
	              Stopped ← Stopping ← (teardown, any removal)
	```

	The methods and hooks run in this order:

	1. **ShouldConstruct** — extensions may veto (sync). See [CO Extensions](/api/CO%20Extensions).
	2. **Constructing** — extension hooks.
	3. **Construct()** — your class's initialization.
	4. **Constructed** — extension hooks. The instance is now tracked and findable via `FromInstance`.
	5. **Starting** — extension hooks.
	6. **Start()** — your class's startup.
	7. **Started** — extension hooks, then the `Started` signal fires.

	:::tip Where to put what
	`Construct` sets up state and must not assume other components exist yet.
	`Start` is where the instance is fully live — connect events, read other
	components, begin loops. Reading a sibling component in `Construct` is the most
	common lifecycle mistake.
	:::

	### 2. Yielding and the phase barrier

	Lifecycle methods and hooks **may yield or return a Promise**. Within one phase,
	each active extension's hook is gated on dependency order: a hook does not start
	until the hooks it depends on have *finished*. Hooks with no dependency edge
	between them run **concurrently**, so an unrelated sibling never blocks you. The
	phase completes — and the next begins — only once every hook has finished and
	every returned Promise has resolved. This coordination point is the **phase
	barrier**.

	```lua
	local Preloaded = {
		Constructing = function(component)
			-- The Constructed phase waits for this Promise before anyone starts.
			return preloadAssets(component.Instance)
		end,
	}
	```

	Only the construct phases run **inline** and hold up the construction chain. The
	start phases run after a `task.defer` boundary, and teardown is deferred as a
	whole — so neither ever runs on the thread that triggered it, and teardown never
	blocks its caller. Hooks that neither yield nor return a Promise cost no Promise
	at all; the async machinery only materializes for hooks that actually suspend.

	### 3. Teardown always runs, in order

	Removal — untag, ancestry exit, instance destroyed, class destroyed, or a
	cancelled/superseded construction — funnels through one path once construction
	has begun:

	```
	untrack → Stopping hooks → Stop(reason) → Stopped hooks → core Janitor destroy
	```

	Stop hooks gate in **reverse** dependency order (a dependency stops only after
	everything depending on it has). `Stop` receives a **reason**:

	| Reason | Cause |
	| --- | --- |
	| `Untagged` | the CollectionService tag was removed |
	| `SelectorUnmatched` | a selector-attached instance stopped matching while still parented |
	| `LeftAncestry` | the instance left the valid ancestor list |
	| `InstanceDestroyed` | the bound instance was destroyed |
	| `ClassDestroyed` | the component class was destroyed |
	| `ConstructionCancelled` | torn down before it finished constructing |
	| `Superseded` | a newer construction attempt replaced this one |
	| `Disabled` | the class was disabled via `SetEnabled(false)` |

	### 3b. Naming: `On*` is primary; member hooks

	`OnConstruct` / `OnStart` / `OnStop` (and `OnHeartbeat` /
	`OnPreSimulation` / `OnPreRender` for the update loops) are the primary
	spellings; the legacy names remain as aliases through v1.x, with the `On*`
	form winning when both are defined.

	Every OTHER `On`-prefixed class member is a **member hook**, connected on
	the bound instance and cleaned up automatically — never write matching
	disconnect logic for them:

	- `function MyClass:OnTouched(part)` — wraps `instance.Touched` (any
	  instance event; a member the instance's class lacks is silently skipped);
	- `function MyClass.OnAttributeChanged.X(self)` — wraps
	  `GetAttributeChangedSignal("X")`;
	- `function MyClass.OnPropertyChanged.X(self)` — wraps
	  `GetPropertyChangedSignal("X")` (unknown properties silently skipped).

	Hooks follow the same rules as native Collection callbacks:

	- **Live from successful construction to teardown.** A change during
	  `OnConstruct` never dispatches; a change during the start window (after
	  construction, `OnStart` possibly still running) DOES — state made in
	  `OnConstruct` is safe inside a hook, state made in `OnStart` may not
	  exist yet.
	- **Declare any time, effective immediately.** A hook defined while
	  instances are already live connects to all of them in the same cycle
	  (events from before the definition are never replayed).
	- **Declare-once.** Defining the same hook name twice errors, and
	  assigning `nil` or a non-function errors — there is no unhook.
	- Hooks are callbacks, not methods: a hook declared post-hoc is not
	  readable back off the class (hooks declared via the config `Methods`
	  table remain callable members).

	Use the DOT form with explicit `self` for the namespace hooks — the colon
	form would bind `self` to the namespace table.

	### 4. The cleanup guarantee

	Because teardown runs `Stop` and destroys the core Janitor on *every* path,
	anything you register with `self:AddTask` is guaranteed to be cleaned up. This
	is the whole point: you never write matching disconnect logic.

	```lua
	function Enemy:Start()
		-- connections clean up on teardown, no manual disconnect
		self:AddTask(RunService.Heartbeat:Connect(function(dt)
			self:think(dt)
		end))

		-- name a task to remove it early via self:RemoveTask("aggro")
		self:AddTask(startAggroLoop(self), true, "aggro")

		-- Promises are cancelled on teardown
		self:AddPromise(chaseNearestPlayer(self))
	end
	```

	:::info If the instance goes away mid-start
	If the instance leaves its ancestors, is untagged, or is superseded while a hook
	is still waiting at the barrier, the in-flight work is cancelled and the
	component tears down — you will still get `Stop` (with the matching reason) for
	anything that had begun constructing.
	:::

	---
	### See also

	- **[CO Getting Started](/api/CO%20Getting%20Started)** — the minimal class and `AddTask` basics.
	- **[CO Extensions](/api/CO%20Extensions)** — the hooks that run at each phase, and how their dependencies order.
]=]
