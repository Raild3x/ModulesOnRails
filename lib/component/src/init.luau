-- Component
-- Stephen Leitnick, Logan Hunt
-- November 26, 2021

--[=[
	@class Component
	
	## Overview
	
	This is a fork of the original Component module by Stephen Leitnick. This fork expands upon the functionality of
	extensions and provides several new useful methods, along with robust handling of edge cases during component
	lifecycle management.

	Bind components to Roblox instances using the Component class and CollectionService tags.

	To avoid confusion of terms:
	- `Component` refers to this module.
	- `Component Class` (e.g. `MyComponent` through this documentation) refers to a class created via `Component.new`
	- `Component Instance` refers to an instance of a component class.
	- `Roblox Instance` refers to the Roblox instance to which the component instance is bound.

	Methods and properties are tagged with the above terms to help clarify the level at which they are used.
]=]

--[[
	## Lifecycle

	The component lifecycle follows this order:
	1. **ShouldConstruct** - Extensions can veto construction by returning `false`
	2. **Constructing** - Extension hook before `Construct()`
	3. **Construct()** - Component initialization (may yield)
	4. **Constructed** - Extension hook after `Construct()`
	5. **Starting** - Extension hook before `Start()`
	6. **Start()** - Component startup (may yield)
	7. **Started** - Extension hook after `Start()`
	8. **Update loops** - HeartbeatUpdate, SteppedUpdate, RenderSteppedUpdate connected
	9. **Stopping** - Extension hook before `Stop()`
	10. **Stop()** - Component cleanup
	11. **Stopped** - Extension hook after `Stop()`

	## Edge Cases and Robustness

	### Yielding During Construction
	
	If `Construct()` or any extension function yields (e.g., waiting for data, HTTP requests, etc.),
	the system tracks the construction state and validates it after each yield point. If the instance
	becomes invalid (moves outside valid ancestors, loses its tag, or a newer construction attempt
	starts), construction is cancelled and any partial state is cleaned up.

	**Example scenario:**
	```lua
	function MyComponent:Construct()
		self.Data = HttpService:GetAsync("...") -- Yields!
		-- If instance is reparented during this yield, construction is cancelled
		self.ProcessedData = processData(self.Data)
	end
	```

	### Yielding During Start
	
	Similar to construction, if `Start()` or extension Starting/Started functions yield, the system
	checks after each yield point whether the component should still be running. If `Stop()` is called
	during startup (e.g., the instance is removed), the start thread is cancelled if possible.

	### Reparenting During Lifecycle
	
	If an instance is reparented outside of valid ancestors during construction:
	- Construction is immediately cancelled
	- Any partial component state is cleaned up via `Stop()`
	- The construction thread is cancelled if suspended

	If an instance is reparented outside of valid ancestors after construction but during start:
	- The start thread is cancelled if possible
	- `Stop()` is called to clean up the component

	### Rapid Reparenting (Ping-Pong)
	
	If an instance rapidly moves in and out of valid ancestors:
	- Each construction attempt gets a unique ID (`constructId`)
	- Only the most recent construction attempt is allowed to complete
	- Stale construction attempts are cancelled and cleaned up
	- The `KEY_LOCK_CONSTRUCT` table tracks the current valid construction ID

	**Example scenario:**
	```lua
	-- Instance starts in workspace (valid ancestor)
	local part = Instance.new("Part", workspace)
	CollectionService:AddTag(part, "MyComponent")
	-- Construction starts...
	part.Parent = ReplicatedStorage -- Moves out - construction cancelled
	part.Parent = workspace -- Moves back in - NEW construction starts
	-- Only the second construction attempt will complete
	```

	### Errors During Construction
	
	If an error occurs during `Construct()` or any extension function:
	- The error is caught and logged with a warning
	- `Stop()` is called on the partial component to clean up any state
	- The component is not added to tracking tables
	- Other components are not affected

	### Errors During Start/Stop
	
	Extension functions (`Starting`, `Started`, `Stopping`, `Stopped`) and lifecycle methods
	are called in order. If one errors, the error propagates but cleanup still occurs for
	connections and state that was set up.

	### Thread Cancellation
	
	When stopping a component that's still in its Start phase:
	- If the start thread is suspended (yielding), it's cancelled via `task.cancel()`
	- If the start thread is the current thread (Stop called from within Start), it's not cancelled
	  but the thread will return early due to state checks
	- If the start thread is in "normal" status (in call stack but not current), cancellation is deferred

	### Memory Management
	
	The component system tracks instances in several tables:
	- `KEY_INST_TO_COMPONENTS`: Maps Roblox instances to their component instances
	- `KEY_COMPONENTS`: Array of all active component instances
	- `KEY_LOCK_CONSTRUCT`: Maps instances to their current construction attempt ID

	All tables are properly cleaned up when:
	- A component is stopped (instance removed from tables)
	- The component class is destroyed (all tables cleared, all components stopped)
	- An instance loses its tag (component stopped and removed from tracking)

	### Ancestor Changes
	
	When `UpdateAncestors()` is called:
	- The `AncestorsChanged` signal fires
	- All watched instances are re-evaluated
	- Instances now outside valid ancestors have their components stopped
	- Instances now inside valid ancestors have components constructed

	### Tag Removal
	
	When a tag is removed from an instance:
	- The instance is immediately removed from the watching list
	- Any active component is stopped
	- Any in-progress construction is cancelled

	### Component Class Destruction
	
	When `Destroy()` is called on a component class:
	- All active components are stopped
	- All tracking tables are cleared
	- All CollectionService connections are disconnected
	- The class is removed from the unsetup components list if present

	## Extension System

	Extensions can hook into the component lifecycle at various points. Extensions are processed
	in order, with nested extensions (via the `Extensions` array) processed recursively.

	### Extension Methods
	
	Extensions can add methods to component classes via the `Methods` table. These methods are
	added at the class level, not the instance level, so they're available regardless of
	`ShouldExtend` results.

	### ShouldExtend
	
	The `ShouldExtend` function is called per-instance to determine if an extension applies.
	This is evaluated during construction, so extensions can be conditionally applied based
	on instance attributes or other runtime conditions.

	### ShouldConstruct
	
	The `ShouldConstruct` function is called before any construction begins. ALL extensions
	with a `ShouldConstruct` function must return `true` for construction to proceed.
	If any returns `false`, no component is created and no cleanup is needed.
]]

type AncestorList = { Instance }

--[=[
	@type ExtensionFn (component) -> ()
	@within Component
]=]
type ExtensionFn = (any) -> ()

--[=[
	@type ExtensionShouldFn (component) -> boolean
	@within Component
]=]
type ExtensionShouldFn = (any) -> boolean

--[=[
	@interface Extension
	@within Component
	.ShouldExtend ExtensionShouldFn?
	.ShouldConstruct ExtensionShouldFn?
	.Constructing ExtensionFn?
	.Constructed ExtensionFn?
	.Starting ExtensionFn?
	.Started ExtensionFn?
	.Stopping ExtensionFn?
	.Stopped ExtensionFn?
	.Extensions {Extension}?
	.Methods {[string]: (...any) -> ...any}?

	An extension allows the ability to extend the behavior of
	components. This is useful for adding injection systems or
	extending the behavior of components by wrapping around
	component lifecycle methods.

	The `ShouldConstruct` function can be used to indicate
	if the component should actually be created. This must
	return `true` or `false`. A component with multiple
	`ShouldConstruct` extension functions must have them _all_
	return `true` in order for the component to be constructed.
	The `ShouldConstruct` function runs _before_ all other
	extension functions and component lifecycle methods.

	The `ShouldExtend` function can be used to indicate if
	the extension itself should be used. This can be used in
	order to toggle an extension on/off depending on whatever
	logic is appropriate. If no `ShouldExtend` function is
	provided, the extension will always be used if provided
	as an extension to the component.

	As an example, an extension could be created to simply log
	when the various lifecycle stages run on the component:

	```lua
	local Logger = {}
	function Logger.Constructing(component) print("Constructing", component) end
	function Logger.Constructed(component) print("Constructed", component) end
	function Logger.Starting(component) print("Starting", component) end
	function Logger.Started(component) print("Started", component) end
	function Logger.Stopping(component) print("Stopping", component) end
	function Logger.Stopped(component) print("Stopped", component) end

	local MyComponent = Component.new({Tag = "MyComponent", Extensions = {Logger}})
	```

	Sometimes it is useful for an extension to control whether or
	not a component should be constructed. For instance, if a
	component on the client should only be instantiated for the
	local player, an extension might look like this, assuming the
	instance has an attribute linking it to the player's UserId:
	```lua
	local Players = game:GetService("Players")

	local OnlyLocalPlayer = {}
	function OnlyLocalPlayer.ShouldConstruct(component)
		local ownerId = component.Instance:GetAttribute("OwnerId")
		return ownerId == Players.LocalPlayer.UserId
	end

	local MyComponent = Component.new({Tag = "MyComponent", Extensions = {OnlyLocalPlayer}})
	```

	It can also be useful for an extension itself to turn on/off
	depending on various contexts. For example, let's take the
	Logger from the first example, and only use that extension
	if the bound instance has a Log attribute set to `true`:
	```lua
	function Logger.ShouldExtend(component)
		return component.Instance:GetAttribute("Log") == true
	end
	```

	In this forked version of component, extensions can also add methods
	to the component class and extend other extensions via giving an extension
	a `Methods` table. For example:
	
	```lua
	local ExtendedComponentMethods = {}
	function ExtendedComponentMethods.DoSomething(component)
		print("Hello World!")
	end

	local MyComponentExtension = {}
	MyComponentExtension.Methods = ExtendedComponentMethods
	```
	This will add a method called `DoSomething` to the component class.
	:::caution Be careful when using with ShouldExtend
	It is important to note that these methods are added to the `Component Class`
	and not the `Component Instance`. This means that these methods will be availible
	regardless of whether the extension passes its shouldExtend function or not. If
	your code is dependent on extension methods existing only when they pass their 
	shouldExtend function, you may want to avoid using this feature.
	:::

	If you want to utilize other extensions within your extension or guarantee that the
	given extension is loaded onto the component before your extension, you can use
	the `Extensions` table. For example:
	```lua
	local SomeOtherExtension = require(somewhere.SomeOtherExtension)

	local MyComponentExtension = {}
	MyComponentExtension.Extensions = {SomeOtherExtension}
	```
	This will guarantee that `SomeOtherExtension` is added to the component and
	loaded before `MyComponentExtension`.
	:::info
	The ShouldExtend function of `SomeOtherExtension` will still be called
	independently of the ShouldExtend function of `MyExtension`. Under the hood this
	just adds the extension to the components original extension array.
	:::
]=]
type Extension = {
	ShouldExtend: ExtensionShouldFn?,
	ShouldConstruct: ExtensionShouldFn?,
	Constructing: ExtensionFn?,
	Constructed: ExtensionFn?,
	Starting: ExtensionFn?,
	Started: ExtensionFn?,
	Stopping: ExtensionFn?,
	Stopped: ExtensionFn?,
	Extensions: { Extension },
	Methods: { [string]: (component: any, ...any) -> ...any }?,
}

--[=[
	@interface ComponentConfig
	@within Component
	.Tag string -- CollectionService tag to use
	.Ancestors {Instance}? -- Optional array of ancestors in which components will be started
	.Extensions {Extension}? -- Optional array of extension objects
	.DelaySetup boolean? -- Optional flag to delay the setup of the component until a later specified time. If true, `:_setup()` must be called manually.

	Component configuration passed to `Component.new`.

	- If no Ancestors option is included, it defaults to `{workspace, game.Players}`.
	- If no Extensions option is included, it defaults to a blank table `{}`.
]=]
type ComponentConfig = {
	Tag: string,
	Ancestors: AncestorList?,
	Extensions: { Extension }?,
	DelaySetup: boolean?,
}

--[=[
	@within Component
	@prop Started Signal
	@tag Event
	@tag Component Class

	Fired when a new instance of a component is started.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})

	MyComponent.Started:Connect(function(component) end)
	```
]=]

--[=[
	@within Component
	@prop Stopped Signal
	@tag Event
	@tag Component Class

	Fired when an instance of a component is stopped.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})

	MyComponent.Stopped:Connect(function(component) end)
	```
]=]

--[=[
	@within Component
	@prop Instance Instance
	@tag Component Instance
	
	A reference back to the _Roblox_ instance from within a _component_ instance. When
	a component instance is created, it is bound to a specific Roblox instance, which
	will always be present through the `Instance` property.

	```lua
	MyComponent.Started:Connect(function(component)
		local robloxInstance: Instance = component.Instance
		print("Component is bound to " .. robloxInstance:GetFullName())
	end)
	```
]=]

--// Services //--
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

--// Dependencies //--
local Packages = script.Parent
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local RailUtil = require(Packages.RailUtil)
local Symbol = require(Packages.Symbol)
local Signal = require(Packages.Signal)
local Trove = require(Packages.Trove)

type Janitor = Janitor.Janitor
type table = { [any]: any }
type Component = table
type ComponentClass = table

local IS_SERVER = RunService:IsServer()
local DEFAULT_ANCESTORS = { workspace, game:GetService("Players") }
local DEFAULT_TIMEOUT = 60
local UNSETUP_COMPONENTS = {}

--[[
	Symbol Keys Documentation:
	
	These symbols are used as keys in component tables to avoid conflicts with user-defined
	properties and to provide a clear separation between internal and public state.
	
	KEY_ANCESTORS: Array of valid ancestor instances for this component class
	KEY_INST_TO_COMPONENTS: Map of Roblox Instance -> Component Instance
	KEY_LOCK_CONSTRUCT: Map of Roblox Instance -> construction attempt ID (for cancellation)
	KEY_COMPONENTS: Array of all active component instances
	KEY_TROVE: Trove instance for managing connections and cleanup
	KEY_EXTENSIONS: Array of extension definitions for this component class
	KEY_ACTIVE_EXTENSIONS: Array of extensions active for a specific component instance
	KEY_STARTING: Thread reference when component is in Start phase (nil otherwise)
	KEY_STARTED: Boolean, true when component has fully started
	KEY_CLASS_ACTIVE_EXTENSIONS: Extensions determined at class level (ShouldExtend not called per-instance)
]]
local KEY_ANCESTORS = Symbol("Ancestors")
local KEY_INST_TO_COMPONENTS = Symbol("InstancesToComponents")
local KEY_LOCK_CONSTRUCT = Symbol("LockConstruct")
local KEY_COMPONENTS = Symbol("Components")
local KEY_TROVE = Symbol("Trove")
local KEY_EXTENSIONS = Symbol("Extensions")
local KEY_ACTIVE_EXTENSIONS = Symbol("ActiveExtensions")
local KEY_STARTING = Symbol("Starting")
local KEY_STARTED = Symbol("Started")
local KEY_CLASS_ACTIVE_EXTENSIONS = Symbol("ClassActiveExtensions")

local renderId = 0
local function NextRenderName(): string
	renderId += 1
	return "ComponentRender" .. tostring(renderId)
end

--[[
	InvokeExtensionFn - Calls a lifecycle hook on all active extensions.
	
	Parameters:
	- component: The component instance
	- fnName: Name of the extension function to call (e.g., "Constructing", "Starting")
	
	Note: This function may yield if any extension function yields.
	The caller is responsible for state validation after calling this.
]]
local function InvokeExtensionFn(component, fnName: string)
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension[fnName]
		if type(fn) == "function" then
			fn(component)
		end
	end
end

--[[
	ShouldConstruct - Checks if all extensions allow construction.
	
	Returns false if ANY extension's ShouldConstruct returns false.
	Returns true if all extensions allow construction (or have no ShouldConstruct).
	
	This is called BEFORE any component state is created, so returning false
	means no cleanup is needed.
]]
local function ShouldConstruct(component): boolean
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension.ShouldConstruct
		if type(fn) == "function" then
			local shouldConstruct = fn(component)
			if not shouldConstruct then
				return false
			end
		end
	end
	return true
end

--[[
	GetActiveExtensions - Determines which extensions apply to a component.
	
	Parameters:
	- component: The component instance or class
	- extensionList: Array of extensions to process
	- activeExtensions: Accumulator array (for recursion)
	- isClass: If true, don't call ShouldExtend (determining class-level extensions)
	
	Extension Processing:
	1. For each extension, checks if it should be applied
	2. If extension is already in activeExtensions, moves it to front (priority)
	3. If not present and should extend, adds to end
	4. Recursively processes extension.Extensions for nested extensions
	5. Final pass removes extensions whose ShouldExtend returned false
	
	The recursion handling ensures nested extensions are processed and that
	extension dependencies are properly ordered (dependencies come first).
]]
local function GetActiveExtensions(component, extensionList, activeExtensions, isClass)
	activeExtensions = activeExtensions or {}
	extensionList = extensionList or {}

	for _, extension in ipairs(extensionList) do
		local idx = table.find(activeExtensions, extension)
		local shouldExtend = false

		if not idx then
			local fn = extension.ShouldExtend

			if not fn then
				shouldExtend = true
			elseif not isClass and type(fn) == "function" then
				shouldExtend = fn(component)
			end
		end

		if idx or shouldExtend then
			if idx then
				table.remove(activeExtensions, idx)
				table.insert(activeExtensions, 1, extension)
			else
				table.insert(activeExtensions, extension)
			end
			GetActiveExtensions(component, extension.Extensions, activeExtensions, isClass)
		end
	end

	if not isClass then
		for i = #activeExtensions, 1, -1 do
			local extension = activeExtensions[i]
			local fn = extension.ShouldExtend
			if type(fn) == "function" and not fn(component) then
				table.remove(activeExtensions, i)
			end
		end
	end

	return activeExtensions
end

--[[
	BindExtensionMethod - Adds methods from an extension to a component.
	
	Methods are added directly to the component table, making them callable
	as component:MethodName(). This happens at the CLASS level, not instance
	level, so methods are available regardless of ShouldExtend results.
	
	Errors if a method value is not a function (catches configuration mistakes).
]]
local function BindExtensionMethod(component, extension)
	if extension.Methods then
		for key, value in extension.Methods do
			if type(value) == "function" then
				component[key] = value
			else
				error("Invalid extension method: " .. tostring(key))
			end
		end
	end
end

--[[
	BindExtensionMethods - Binds methods from all extensions in a list.
	Wrapper that calls BindExtensionMethod for each extension.
]]
local function BindExtensionMethods(component, extensionList)
	for _, extension in ipairs(extensionList) do
		BindExtensionMethod(component, extension)
	end
end

local Component = {}
Component.__index = Component

--[=[
	@within Component
	@prop DelaySetup boolean
	@tag Component

	Controls the global default for whether or not components should delay their setup. Overridden by the `DelaySetup` 
	property if set in the component configuration table passed to `Component.new`. This is useful for when you want
	to ensure some other systems that the components may utilize are set up before the components themselves.

	This value is initialized to the `DelaySetup` attribute of the script, which defaults to `false`.

	:::caution
	When set to `true`, the component class will not automatically call `:_setup()` when created and expects
	you to call it when desired. Failing to do so will result in the component never starting to listen
	for tagged instances and thus never starting any component instances.
	:::
]=]
Component.DelaySetup = script:GetAttribute("DelaySetup") or false

--[=[
	@tag Component
	@within Component
	@prop Tag string

	The tag used to identify the component class. This is used with CollectionService to bind component instances
	to Roblox instances.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	print(MyComponent.Tag) -- "MyComponent"
	```
]=]

--[=[
	@tag Component
	@param config ComponentConfig
	@return ComponentClass

	Create a new custom Component class.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	```

	A full example might look like this:

	```lua
	local MyComponent = Component.new({
		Tag = "MyComponent",
		Ancestors = {workspace},
		Extensions = {Logger}, -- See Logger example within the example for the Extension type
	})

	local AnotherComponent = require(somewhere.AnotherComponent)

	-- Optional if UpdateRenderStepped should use BindToRenderStep:
	MyComponent.RenderPriority = Enum.RenderPriority.Camera.Value

	function MyComponent:Construct()
		self.MyData = "Hello"
	end

	function MyComponent:Start()
		local another = self:GetComponent(AnotherComponent)
		another:DoSomething()
	end

	function MyComponent:Stop()
		self.MyData = "Goodbye"
	end

	function MyComponent:HeartbeatUpdate(dt)
	end

	function MyComponent:SteppedUpdate(dt)
	end
	
	function MyComponent:RenderSteppedUpdate(dt)
	end
	```
]=]
function Component.new(config: ComponentConfig)
	local customComponent = {}
	customComponent.__index = customComponent
	-- customComponent.__tostring = function()
	-- 	return "Component<" .. config.Tag .. ">"
	-- end
	customComponent[KEY_ANCESTORS] = config.Ancestors or DEFAULT_ANCESTORS
	customComponent[KEY_INST_TO_COMPONENTS] = {}
	customComponent[KEY_COMPONENTS] = {}
	customComponent[KEY_LOCK_CONSTRUCT] = {}
	customComponent[KEY_TROVE] = Trove.new()
	customComponent[KEY_EXTENSIONS] = config.Extensions or {}
	customComponent[KEY_STARTED] = false
	customComponent.Tag = config.Tag
	customComponent.AncestorsChanged = customComponent[KEY_TROVE]:Construct(Signal)
	customComponent.Started = customComponent[KEY_TROVE]:Construct(Signal)
	customComponent.Stopped = customComponent[KEY_TROVE]:Construct(Signal)
	setmetatable(customComponent, Component)

	table.insert(UNSETUP_COMPONENTS, customComponent)
	local delaySetup = if config.DelaySetup then config.DelaySetup else customComponent.DelaySetup
	if not delaySetup then
		Component._setup(customComponent)
	else
		task.delay(30, function()
			if table.find(UNSETUP_COMPONENTS, customComponent) then
				warn(customComponent, "Component:_setup() was not called within 30 seconds of instantiation.")
			end
		end)
	end
	return customComponent
end

--[=[
	@tag Component
	@return {ComponentClass}

	Gets a table array of all unsetup component classes. This allows you to call `:_setup()` on them later.

	```lua
	local unsetupComponents = Component.getUnsetupComponents()
	for _, componentClass in unsetupComponents do
		Component._setup(componentClass)
	end
	```
]=]
function Component.getUnsetupComponents(): { ComponentClass }
	return table.clone(UNSETUP_COMPONENTS) :: any
end

function Component:_isInAncestorList(instance: Instance): boolean
	for _, parent in ipairs(self[KEY_ANCESTORS] :: { Instance }) do
		if instance:IsDescendantOf(parent) then
			return true
		end
	end
	return false
end

--[=[
	@private
	@within Component
	@param instance Instance -- The Roblox instance to create a component for
	@param constructId number? -- Optional ID to track this construction attempt for cancellation
	@return Component? -- The constructed component, or nil if construction failed/was cancelled

	Creates a new component instance bound to the given Roblox instance.

	## Edge Case Handling

	### State Validation After Yields
	After each potential yield point (extension calls, Construct), the system validates:
	- The instance is still within valid ancestors
	- No newer construction attempt has superseded this one
	- Construction wasn't cancelled due to ancestry change

	### Ancestry Change During Construction
	If the instance moves outside valid ancestors during construction:
	- An ancestry change listener detects this immediately
	- The construction thread is cancelled if suspended
	- A warning is logged with the component tag and instance path
	- Any partial state is cleaned up via Stop()

	### Construction ID Tracking
	The `constructId` parameter allows the system to detect when a newer construction
	attempt should supersede the current one. This handles rapid reparenting scenarios
	where an instance might move in/out of valid ancestors multiple times.

	### Error Handling
	All construction logic is wrapped in pcall. If an error occurs:
	- The error is logged with context (tag, instance path, error message)
	- Stop() is called to clean up any partial state
	- nil is returned so the component isn't tracked

	### ShouldConstruct Failure
	If ShouldConstruct returns false, construction stops cleanly without calling Stop()
	since no component state was created yet.
]=]
function Component:_instantiate(instance: Instance, constructId: number?)
	local component = setmetatable({}, self)
	component.Instance = instance

	component[KEY_ACTIVE_EXTENSIONS] =
		GetActiveExtensions(component, self[KEY_EXTENSIONS], table.clone(self[KEY_CLASS_ACTIVE_EXTENSIONS] :: any))
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		if not table.find(self[KEY_CLASS_ACTIVE_EXTENSIONS], extension) then
			BindExtensionMethod(component, extension)
		end
	end

	-- Track if construction was cancelled due to ancestry change
	local constructionCancelled = false
	local constructionThread: thread? = nil

	-- Listen for ancestry changes during construction to cancel if instance becomes invalid
	local ancestryConnection: RBXScriptConnection?
	ancestryConnection = RailUtil.Signal
		.combine({
			instance.AncestryChanged,
			self.AncestorsChanged,
		})
		:Connect(function()
			if not self:_isInAncestorList(instance) then
				warn(
					string.format(
						"[Component] Construction cancelled for '%s' on '%s' due to ancestry change.",
						self.Tag,
						instance:GetFullName()
					)
				)
				constructionCancelled = true
				if ancestryConnection then
					ancestryConnection:Disconnect()
					ancestryConnection = nil
				end
				-- Cancel the construction thread if it's yielding
				if constructionThread and coroutine.status(constructionThread) == "suspended" then
					task.cancel(constructionThread)
				end
			end
		end)

	-- Helper to validate that the component is still in a valid state after potential yields
	local function validateState(): boolean
		if constructionCancelled then
			return false
		end
		-- Check if instance moved outside valid ancestors
		if not self:_isInAncestorList(instance) then
			return false
		end
		-- Check if a newer construct attempt has superseded this one
		if constructId and self[KEY_LOCK_CONSTRUCT][instance] ~= constructId then
			return false
		end
		return true
	end

	-- Cleanup helper for when construction fails or is cancelled
	local function cleanup()
		if ancestryConnection then
			ancestryConnection:Disconnect()
			ancestryConnection = nil
		end
	end

	-- Track if construction actually started (past ShouldConstruct)
	local constructionStarted = false

	local success, result = pcall(function()
		constructionThread = coroutine.running()

		if not ShouldConstruct(component) then
			return nil
		end

		if not validateState() then
			return nil
		end

		constructionStarted = true
		InvokeExtensionFn(component, "Constructing")

		if not validateState() then
			return nil
		end

		if type(component.Construct) == "function" then
			component:Construct()
		end

		if not validateState() then
			return nil
		end

		InvokeExtensionFn(component, "Constructed")

		if not validateState() then
			return nil
		end

		return component
	end)

	cleanup()

	-- Handle error during construction
	if not success then
		if not constructionCancelled then
			warn(
				string.format(
					"[Component] Error during construction of '%s' on '%s':\n%s",
					self.Tag,
					instance:GetFullName(),
					tostring(result)
				)
			)
		end
		component:Stop()
		return nil
	end

	-- Handle nil result (construction was cancelled midway)
	if result == nil and constructionStarted then
		-- Construction started but was cancelled mid-way, clean up partial state
		warn(
			string.format(
				"[Component] Construction cancelled for '%s' on '%s'. Running Stop now",
				self.Tag,
				instance:GetFullName()
			)
		)
		component:Stop()
	end

	return result
end

--[=[
	@tag Component Class
	@within Component
	@method _setup

	This is an internal method that is called to set up the component class.
	It is automatically called when the component class is created, unless the
	`DelaySetup` option is set to `true` in the component configuration.
	If `DelaySetup` is `true`, then this method must be called manually.

	## Internal Functions

	### StartComponent
	Starts a fully constructed component:
	- Sets KEY_STARTING to the current thread for cancellation tracking
	- Calls extension Starting hooks, Start(), and Started hooks
	- After each call, checks if KEY_STARTING was set to nil (component was stopped)
	- If stopped mid-start, returns early without setting up update loops
	- Connects HeartbeatUpdate, SteppedUpdate, and RenderSteppedUpdate if present
	- Sets KEY_STARTED to true and fires the Started signal

	### StopComponent
	Stops a running or starting component:
	- If KEY_STARTING is set (component is mid-start):
	  - Gets the start thread reference
	  - Sets KEY_STARTING to nil to signal cancellation
	  - If the start thread is suspended and not the current thread, cancels it
	  - If the start thread is in "normal" status, defers cancellation
	- Disconnects all update loop connections
	- Calls extension Stopping hooks, Stop(), and Stopped hooks
	- Fires the Stopped signal

	### SafeConstruct
	Wrapper around _instantiate that handles superseded construction:
	- Checks if the construction ID is still current before calling _instantiate
	- Checks again after _instantiate returns
	- If superseded, cleans up the component (if one was returned) and returns nil
	- Note: _instantiate already handles cleanup for cancelled/failed constructions

	### TryConstructComponent
	Attempts to construct a component for an instance:
	- Skips if a component already exists for the instance
	- Increments the construction ID to track this attempt
	- Defers construction to allow batching and avoid blocking
	- On success, tracks the component and defers starting it

	### TryDeconstructComponent
	Stops and removes a component for an instance:
	- Removes the component from tracking tables
	- Clears the construction lock (important for preventing stale locks)
	- Spawns StopComponent if the component was started or starting

	### StartWatchingInstance / InstanceTagged / InstanceUntagged
	Manages the per-instance ancestry watching:
	- StartWatchingInstance sets up a combined signal for AncestryChanged and AncestorsChanged
	- When ancestry changes, evaluates if component should be constructed or deconstructed
	- InstanceUntagged removes the watch and deconstructs the component
]=]
function Component:_setup()
	local idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	else
		warn(self, ":_setup was already called for this component.")
	end

	-- Tracks instances being watched for ancestry changes
	-- Key: Instance, Value: RBXScriptConnection for the ancestry listener
	-- Cleaned up when: instance is untagged or component class is destroyed
	local watchingInstances = {}

	self[KEY_CLASS_ACTIVE_EXTENSIONS] = GetActiveExtensions(self, self[KEY_EXTENSIONS], {}, true)
	BindExtensionMethods(self, self[KEY_CLASS_ACTIVE_EXTENSIONS]) -- Added by Raildex

	--[[
		StartComponent - Starts a fully constructed component instance.
		
		Edge Cases Handled:
		- Stop called during Starting extension: KEY_STARTING becomes nil, returns early
		- Stop called during Start(): KEY_STARTING becomes nil, returns early
		- Stop called during Started extension: KEY_STARTING becomes nil, returns early
		- Yielding in any hook: State is checked after each potential yield point
		
		Thread tracking via KEY_STARTING allows StopComponent to cancel the start
		thread if the component needs to be stopped while still starting.
	]]
	local function StartComponent(component)
		component[KEY_STARTING] = coroutine.running()

		InvokeExtensionFn(component, "Starting")

		-- Check if component was stopped during Starting extension
		if component[KEY_STARTING] == nil then
			return
		end

		component:Start()

		-- Check if component was stopped during Start method
		if component[KEY_STARTING] == nil then
			return
		end

		InvokeExtensionFn(component, "Started")

		-- Check if component was stopped during Started extension
		if component[KEY_STARTING] == nil then
			return
		end

		local hasHeartbeatUpdate = typeof(component.HeartbeatUpdate) == "function"
		local hasSteppedUpdate = typeof(component.SteppedUpdate) == "function"
		local hasRenderSteppedUpdate = typeof(component.RenderSteppedUpdate) == "function"

		if hasHeartbeatUpdate then
			component._heartbeatUpdate = RunService.Heartbeat:Connect(function(dt)
				component:HeartbeatUpdate(dt)
			end)
		end

		if hasSteppedUpdate then
			component._steppedUpdate = RunService.Stepped:Connect(function(_, dt)
				component:SteppedUpdate(dt)
			end)
		end

		if hasRenderSteppedUpdate and not IS_SERVER then
			if component.RenderPriority then
				component._renderName = NextRenderName()
				RunService:BindToRenderStep(component._renderName, component.RenderPriority, function(dt)
					component:RenderSteppedUpdate(dt)
				end)
			else
				component._renderSteppedUpdate = RunService.RenderStepped:Connect(function(dt)
					component:RenderSteppedUpdate(dt)
				end)
			end
		end

		component[KEY_STARTED] = true
		component[KEY_STARTING] = nil

		self.Started:Fire(component)
	end

	--[[
		StopComponent - Stops a component, handling both fully started and mid-start cases.
		
		Thread Cancellation Edge Cases:
		- If component is mid-start (KEY_STARTING set):
		  - Captures the start thread reference before clearing KEY_STARTING
		  - Clears KEY_STARTING first to signal cancellation to StartComponent
		  - Thread cancellation depends on state:
		    * "suspended": Cancel immediately (thread is yielding)
		    * "normal": Thread is in call stack, defer cancellation
		    * "running": This is the current thread, don't cancel (would error)
		  - Uses pcall around task.cancel as the thread may have already finished
		
		- If KEY_STARTING is nil:
		  - Component either fully started or never started
		  - Just clean up connections and call Stop()
		
		Connection Cleanup:
		- Disconnects HeartbeatUpdate, SteppedUpdate connections if they exist
		- Unbinds RenderStepped if using BindToRenderStep, or disconnects if using Connect
		
		Extension Hooks:
		- Stopping hook called before Stop()
		- Stopped hook called after Stop()
		- These are called even if the component was stopped mid-start
	]]
	local function StopComponent(component)
		if component[KEY_STARTING] then
			-- Stop the component during its start method invocation:
			local startThread = component[KEY_STARTING] :: thread
			local currentThread = coroutine.running()
			component[KEY_STARTING] = nil

			-- Only cancel if we're not currently running in that thread
			if startThread ~= currentThread then
				if coroutine.status(startThread) == "suspended" then
					pcall(task.cancel, startThread)
				elseif coroutine.status(startThread) == "normal" then
					-- Thread is in the call stack but not the current one, defer cancellation
					task.defer(function()
						if coroutine.status(startThread) == "suspended" then
							pcall(task.cancel, startThread)
						end
					end)
				end
			end
			-- If we are in the same thread, we don't cancel - just let it return naturally
			-- The KEY_STARTING = nil check in StartComponent will handle this case
		end

		if component._heartbeatUpdate then
			component._heartbeatUpdate:Disconnect()
		end

		if component._steppedUpdate then
			component._steppedUpdate:Disconnect()
		end

		if component._renderSteppedUpdate then
			component._renderSteppedUpdate:Disconnect()
		elseif component._renderName then
			RunService:UnbindFromRenderStep(component._renderName)
		end

		InvokeExtensionFn(component, "Stopping")
		component:Stop()
		InvokeExtensionFn(component, "Stopped")
		self.Stopped:Fire(component)
	end

	--[[
		SafeConstruct - Wrapper that handles superseded construction attempts.
		
		Returns nil if:
		- Construction ID doesn't match BEFORE calling _instantiate (stale attempt)
		- Construction ID doesn't match AFTER _instantiate returns (superseded during construction)
		- _instantiate itself returned nil (cancelled/failed/ShouldConstruct false)
		
		Cleanup Note:
		- _instantiate handles its own cleanup when returning nil (calls Stop() on partial components)
		- SafeConstruct only needs to call Stop() if _instantiate returned a valid component
		  but the ID was superseded during construction
	]]
	local function SafeConstruct(instance, id)
		if self[KEY_LOCK_CONSTRUCT][instance] ~= id then
			return nil
		end
		local component = self:_instantiate(instance, id)
		if self[KEY_LOCK_CONSTRUCT][instance] ~= id then
			-- Construction was superseded by a newer attempt
			-- Note: _instantiate already handles cleanup via component:Stop() when returning nil,
			-- so we only need to clean up if a valid component was returned but is now stale
			if component then
				-- Component was successfully constructed but is now stale, need to clean up
				component:Stop()
			end
			return nil
		end
		return component
	end

	--[[
		TryConstructComponent - Attempts to construct a component for a tagged instance.
		
		Construction ID System:
		- Each construction attempt gets a unique, incrementing ID
		- ID is stored in KEY_LOCK_CONSTRUCT[instance]
		- SafeConstruct and _instantiate check this ID to detect superseded attempts
		- This handles rapid reparenting where instance moves in/out of valid ancestors
		
		Deferred Execution:
		- Construction is deferred via task.defer to avoid blocking
		- Starting is also deferred after construction completes
		- This allows multiple instances to be batched and processed efficiently
		
		Double-Check Pattern:
		- Before starting, verifies the component is still the active one
		- Protects against race conditions where the component was replaced
	]]
	local function TryConstructComponent(instance)
		if self[KEY_INST_TO_COMPONENTS][instance] then
			return
		end
		local id = self[KEY_LOCK_CONSTRUCT][instance] or 0
		id += 1
		self[KEY_LOCK_CONSTRUCT][instance] = id
		task.defer(function()
			local component = SafeConstruct(instance, id)
			if not component then
				return
			end
			self[KEY_INST_TO_COMPONENTS][instance] = component
			table.insert(self[KEY_COMPONENTS] :: table, component)
			task.defer(function()
				if self[KEY_INST_TO_COMPONENTS][instance] == component then
					StartComponent(component)
				end
			end)
		end)
	end

	--[[
		TryDeconstructComponent - Removes and stops a component for an instance.
		
		Cleanup Order:
		1. Remove from KEY_INST_TO_COMPONENTS (prevents new lookups)
		2. Clear KEY_LOCK_CONSTRUCT (prevents stale construction locks)
		3. Remove from KEY_COMPONENTS array (uses swap-remove for O(1))
		4. Spawn StopComponent if component was started/starting
		
		Important: KEY_LOCK_CONSTRUCT is cleared even if no component exists.
		This handles the case where construction is in progress but not complete,
		preventing the stale lock from blocking future construction attempts.
		
		Note: Uses task.spawn for StopComponent to avoid blocking and allow
		the calling code to continue (important for batch operations).
	]]
	local function TryDeconstructComponent(instance)
		self[KEY_LOCK_CONSTRUCT][instance] = nil
		local component = self[KEY_INST_TO_COMPONENTS][instance]
		if not component then
			return
		end
		self[KEY_INST_TO_COMPONENTS][instance] = nil
		local components = self[KEY_COMPONENTS] :: table
		local index = table.find(components, component)
		if index then
			-- Swap-remove for O(1) removal from unordered array
			local n = #components
			components[index] = components[n]
			components[n] = nil
		end
		if component[KEY_STARTED] or component[KEY_STARTING] then
			task.spawn(StopComponent, component)
		end
	end

	--[[
		StartWatchingInstance - Sets up ancestry monitoring for a tagged instance.
		
		Combined Signal:
		- Listens to both instance.AncestryChanged and self.AncestorsChanged
		- This means components respond to BOTH instance movement AND ancestor list changes
		- Uses RailUtil.Signal.combine for efficient combined listening
		
		Ancestry Evaluation:
		- On any ancestry change, checks if instance is in valid ancestor list
		- If valid: TryConstructComponent (may already exist, that's handled)
		- If invalid: TryDeconstructComponent (cleans up if exists)
		
		Memory Management:
		- Connection stored in watchingInstances table
		- Connection added to component class Trove for automatic cleanup on Destroy
		- InstanceUntagged explicitly removes from watchingInstances and Trove
	]]
	local function StartWatchingInstance(instance)
		if watchingInstances[instance] then
			return
		end

		local ancestryChangedHandle = self[KEY_TROVE]:Connect(
			RailUtil.Signal.combine {
				instance.AncestryChanged,
				self.AncestorsChanged,
			},
			function(_, parent)
				if parent and self:_isInAncestorList(instance) then
					TryConstructComponent(instance)
				else
					TryDeconstructComponent(instance)
				end
			end
		)
		watchingInstances[instance] = ancestryChangedHandle
		if self:_isInAncestorList(instance) then
			TryConstructComponent(instance)
		end
	end

	--[[
		InstanceTagged - Called when CollectionService detects a new tagged instance.
		Simply starts watching the instance for ancestry changes.
	]]
	local function InstanceTagged(instance: Instance)
		StartWatchingInstance(instance)
	end

	--[[
		InstanceUntagged - Called when CollectionService detects tag removal.
		
		Cleanup:
		1. Removes ancestry watching connection from watchingInstances
		2. Removes connection from Trove (prevents double-disconnect on Destroy)
		3. Deconstructs any existing component
		
		This is the primary cleanup path for normal component removal.
	]]
	local function InstanceUntagged(instance: Instance)
		local watchHandle = watchingInstances[instance]
		if watchHandle then
			watchingInstances[instance] = nil
			self[KEY_TROVE]:Remove(watchHandle)
		end
		TryDeconstructComponent(instance)
	end

	-- Connect to CollectionService for tag add/remove events
	-- These connections are stored in the Trove for cleanup on Destroy
	self[KEY_TROVE]:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), InstanceTagged)
	self[KEY_TROVE]:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), InstanceUntagged)

	-- Process all instances that already have the tag
	-- Deferred to avoid blocking and allow batching
	local tagged = CollectionService:GetTagged(self.Tag)
	for _, instance in ipairs(tagged) do
		task.defer(InstanceTagged, instance)
	end
end

--[=[
	@tag Component Class
	@return {Component}
	Gets a table array of all existing component objects. For example,
	if there was a component class linked to the "MyComponent" tag,
	and three Roblox instances in your game had that same tag, then
	calling `GetAll` would return the three component instances.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})

	-- ...

	local components = MyComponent:GetAll()
	for _,component in ipairs(components) do
		component:DoSomethingHere()
	end
	```
]=]
function Component:GetAll()
	return self[KEY_COMPONENTS]
end

--[=[
	@tag Component Class
	@return Component?

	Gets an instance of a component class from the given Roblox
	instance. Returns `nil` if not found.

	```lua
	local MyComponent = require(somewhere.MyComponent)

	local myComponentInstance = MyComponent:FromInstance(workspace.SomeInstance)
	```
]=]
function Component:FromInstance(instance: Instance)
	return self[KEY_INST_TO_COMPONENTS][instance]
end

--[=[
	@tag Component Class
	@return Promise<ComponentInstance>

	Resolves a promise once the component instance is present on a given
	Roblox instance.

	An optional `timeout` can be provided to reject the promise if it
	takes more than `timeout` seconds to resolve. If no timeout is
	supplied, `timeout` defaults to 60 seconds.

	```lua
	local MyComponent = require(somewhere.MyComponent)

	MyComponent:WaitForInstance(workspace.SomeInstance):andThen(function(myComponentInstance)
		-- Do something with the component class
	end)
	```
]=]
function Component:WaitForInstance(instance: Instance, timeout: number?)
	local componentInstance = self:FromInstance(instance)
	if componentInstance and componentInstance[KEY_STARTED] then
		return Promise.resolve(componentInstance)
	end
	return Promise.fromEvent(self.Started, function(c)
		local match = c.Instance == instance
		if match then
			componentInstance = c
		end
		return match
	end)
		:andThen(function()
			return componentInstance
		end)
		:timeout(if type(timeout) == "number" then timeout else DEFAULT_TIMEOUT)
end

--[=[
	@tag Component Class

	Allows for you to update the valid ancestors of a component class. This is useful if you want to
	give a valid ancestor that may not exist when the component is first created.

	```lua
	local MyComponent = Component.new({
		Tag = "MyComponent",
		Ancestors = {workspace},
	})

	task.defer(function()
		local newAncestors = {workspace:WaitForChild("SomeFolder")}
		MyComponent:UpdateAncestors(newAncestors)
	end)
	```
]=]
function Component:UpdateAncestors(newAncestors: { Instance })
	local lastAncestors = self[KEY_ANCESTORS]
	self[KEY_ANCESTORS] = newAncestors
	self.AncestorsChanged:Fire(newAncestors, lastAncestors)
end

--[=[
	@tag Component Class

	Gets the current valid ancestors of a component class.
]=]
function Component:GetAncestors(): { Instance }
	return table.clone(self[KEY_ANCESTORS])
end

--[=[
	@tag Component Class
	`Construct` is called before the component is started, and should be used
	to construct the component instance.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})

	function MyComponent:Construct()
		self.SomeData = 32
		self.OtherStuff = "HelloWorld"
	end
	```
]=]
function Component:Construct() end

--[=[
	@tag Component Class
	`Start` is called when the component is started. At this point in time, it
	is safe to grab other components also bound to the same instance.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	local AnotherComponent = require(somewhere.AnotherComponent)

	function MyComponent:Start()
		-- e.g., grab another component:
		local another = self:GetComponent(AnotherComponent)
	end
	```
]=]
function Component:Start() end

--[=[
	@tag Component Class
	`Stop` is called when the component is stopped. This occurs either when the
	bound instance is removed from one of the whitelisted ancestors _or_ when
	the matching tag is removed from the instance. This also means that the
	instance _might_ be destroyed, and thus it is not safe to continue using
	the bound instance (e.g. `self.Instance`) any longer.

	This should be used to clean up the component.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})

	function MyComponent:Stop()
		self.SomeStuff:Destroy()
	end
	```
]=]
function Component:Stop() end

--[=[
	@tag Component Instance
	@param componentClass ComponentClass
	@return Component?

	Retrieves another component instance bound to the same
	Roblox instance.

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	local AnotherComponent = require(somewhere.AnotherComponent)

	function MyComponent:Start()
		local another = self:GetComponent(AnotherComponent)
	end
	```
]=]
function Component:GetComponent(componentClass)
	return componentClass[KEY_INST_TO_COMPONENTS][self.Instance]
end

--[=[
	@tag Component Instance
	@return Connection

	Ties a function to the lifecycle of the calling component and the equivalent component of the given
	`componentClass`. The function is run whenever a component of the given class is started. The given
	function passes the sibling component of the given class and a janitor to handle any connections
	you may make within it. The Janitor is cleaned up whenever either component is stopped.

	```lua
	local AnotherComponentClass = require(somewhere.AnotherComponent)

	local MyComponent = Component.new({Tag = "MyComponent"})

	function MyComponent:Start()
		self:WhileHasComponent(AnotherComponentClass, function(siblingComponent, jani)
			print(siblingComponent.SomeProperty)
			
			jani:Add(function()
				print("Sibling component stopped")
			end)
		end)
	end
	```
]=]
function Component:WhileHasComponent(componentClass: ComponentClass, fn: (component: Component, jani: Janitor) -> ())
	if not componentClass.Tag and componentClass[1] and componentClass[1].Tag then
		error(
			"Component:WhileHasComponent() called with an array of component classes. Did you mean to call WhileHasComponents() instead?"
		)
	end
	local bindJani = Janitor.new()

	local connProxy = {}
	connProxy.IsConnected = true
	connProxy.Disconnect = function()
		if connProxy.IsConnected then
			connProxy.IsConnected = false
			bindJani:Destroy()
		end
	end
	connProxy.Destroy = connProxy.Disconnect
	setmetatable(connProxy, {
		__call = function(t, ...)
			return t.Destroy(...)
		end,
	})

	bindJani:Add(connProxy)
	bindJani:AddPromise(Promise.fromEvent(self.Stopped, function(c)
		return c.Instance == self.Instance
	end):andThen(connProxy.Destroy))

	assert(
		typeof(componentClass) == "table" and componentClass.Tag,
		"Component:WhileHasComponent() expects a component class."
	)

	-- Track janitor for the component
	local activeJanitor = nil

	local function SetupIfPresent()
		local component = self:GetComponent(componentClass)
		if not component or activeJanitor then
			return
		end

		activeJanitor = bindJani:Add(Janitor.new(), "Destroy")
		activeJanitor:Add(task.spawn(fn, component, activeJanitor))

		-- If the component stops, destroy janitor
		activeJanitor:AddPromise(Promise.fromEvent(componentClass.Stopped, function(c)
			return c.Instance == self.Instance
		end):andThen(function()
			if activeJanitor then
				activeJanitor:Destroy()
				activeJanitor = nil
			end
		end))
	end

	-- Listen for component start events
	bindJani:Add(componentClass.Started:Connect(function(component)
		if component.Instance == self.Instance then
			SetupIfPresent()
		end
	end))

	-- Initial check in case component is already present
	SetupIfPresent()

	return connProxy
end

--[=[
	@tag Component Instance
	@return Connection

	Ties a function to the lifecycle of the calling component and the equivalent components of the given
	array of `componentClasses`. The function is run whenever all components of the given classes are started.
	The given function passes an array of sibling components of the given classes and a janitor to handle any 
	connections you may make within it. The Janitor is cleaned up whenever any of the components is stopped.

	```lua
	local AnotherComponentClass = require(somewhere.AnotherComponent)
	local ThirdComponentClass = require(somewhere.ThirdComponent)

	local MyComponent = Component.new({Tag = "MyComponent"})

	function MyComponent:Start()
		self:WhileHasComponents({AnotherComponentClass, ThirdComponentClass}, function(siblingComponents, jani)
			local anotherComponent = siblingComponents[1]
			local thirdComponent = siblingComponents[2]
			print(anotherComponent.SomeProperty, thirdComponent.AnotherProperty)
			
			jani:Add(function()
				print("One or more sibling components stopped")
			end)
		end)
	end
	```
]=]
function Component:WhileHasComponents(
	componentClasses: { ComponentClass },
	fn: (components: { Component }, jani: Janitor) -> ()
)
	local bindJani = Janitor.new()

	local connProxy = {}
	connProxy.IsConnected = true
	connProxy.Disconnect = function()
		if connProxy.IsConnected then
			connProxy.IsConnected = false
			bindJani:Destroy()
		end
	end
	connProxy.Destroy = connProxy.Disconnect
	setmetatable(connProxy, {
		__call = function(t, ...)
			return t.Destroy(...)
		end,
	})

	bindJani:Add(connProxy)
	bindJani:AddPromise(Promise.fromEvent(self.Stopped, function(c)
		return c.Instance == self.Instance
	end):andThen(connProxy.Destroy))

	assert(typeof(componentClasses) == "table", "Component:WhileHasComponents() expects a non-empty array of component classes.")  
	for _, class in ipairs(componentClasses) do  
		assert(typeof(class) == "table" and class.Tag, "Component:WhileHasComponents() expects all elements to be component classes.")  
	end  

	-- Helper to get all component instances for self.Instance
	local function getAllComponents()
		local components = {}
		for i, class in ipairs(componentClasses) do
			local inst = self:GetComponent(class)
			if not inst then
				return nil
			end
			components[i] = inst
		end
		return components
	end

	-- Track janitor for the set of components
	local activeJanitor = nil

	local function SetupIfAllPresent()
		local components = getAllComponents()
		if not components or activeJanitor then
			return
		end

		activeJanitor = bindJani:Add(Janitor.new(), "Destroy")
		activeJanitor:Add(task.spawn(fn, components, activeJanitor))
		local function cleanupJanitor()
			if activeJanitor then
				activeJanitor:Destroy()
				activeJanitor = nil
			end
		end

		-- If any component stops, destroy janitor
		for _, class in ipairs(componentClasses) do
			activeJanitor:AddPromise(Promise.fromEvent(class.Stopped, function(c)
				return c.Instance == self.Instance
			end):andThen(cleanupJanitor))
		end
	end

	-- Listen for all component start events
	for _, class in ipairs(componentClasses) do
		bindJani:Add(class.Started:Connect(function(component)
			if component.Instance == self.Instance then
				SetupIfAllPresent()
			end
		end))
	end

	-- Initial check in case all are already present
	SetupIfAllPresent()

	return connProxy
end

-- DEPRECATED: Use WhileHasComponent or WhileHasComponents instead. Kept for backwards compat
function Component:ForEachSibling(...)
	warn(
		"ForEachSibling is deprecated. Use WhileHasComponent for single components or WhileHasComponents for multiple components instead."
	)
	-- For backwards compatibility, try to detect if it's multiple components and route appropriately
	local componentClassOrClasses = ...
	if componentClassOrClasses and typeof(componentClassOrClasses) == "table" and not componentClassOrClasses.Tag then
		return self:WhileHasComponents(...)
	else
		return self:WhileHasComponent(...)
	end
end

--[=[
	@tag Component Class
	@function HeartbeatUpdate
	@param dt number
	@within Component

	If this method is present on a component, then it will be
	automatically connected to `RunService.Heartbeat`.

	:::note Method
	This is a method, not a function. This is a limitation
	of the documentation tool which should be fixed soon.
	:::
	
	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	
	function MyComponent:HeartbeatUpdate(dt)
	end
	```
]=]
--[=[
	@tag Component Class
	@function SteppedUpdate
	@param dt number
	@within Component

	If this method is present on a component, then it will be
	automatically connected to `RunService.Stepped`.

	:::note Method
	This is a method, not a function. This is a limitation
	of the documentation tool which should be fixed soon.
	:::
	
	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	
	function MyComponent:SteppedUpdate(dt)
	end
	```
]=]
--[=[
	@tag Component Class
	@function RenderSteppedUpdate
	@param dt number
	@within Component
	@client

	If this method is present on a component, then it will be
	automatically connected to `RunService.RenderStepped`. If
	the `[Component].RenderPriority` field is found, then the
	component will instead use `RunService:BindToRenderStep()`
	to bind the function.

	:::note Method
	This is a method, not a function. This is a limitation
	of the documentation tool which should be fixed soon.
	:::
	
	```lua
	-- Example that uses `RunService.RenderStepped` automatically:

	local MyComponent = Component.new({Tag = "MyComponent"})
	
	function MyComponent:RenderSteppedUpdate(dt)
	end
	```
	```lua
	-- Example that uses `RunService:BindToRenderStep` automatically:
	
	local MyComponent = Component.new({Tag = "MyComponent"})

	-- Defining a RenderPriority will force the component to use BindToRenderStep instead
	MyComponent.RenderPriority = Enum.RenderPriority.Camera.Value
	
	function MyComponent:RenderSteppedUpdate(dt)
	end
	```
]=]

--[=[
	@tag Component Class
	@within Component
	@private

	Destroys the component class, stopping all active components and cleaning up all resources.

	## Cleanup Process

	1. Removes from UNSETUP_COMPONENTS if present
	2. Stops all active components (those with KEY_STARTED or KEY_STARTING set)
	3. Clears all tracking tables:
	   - KEY_INST_TO_COMPONENTS (instance -> component mapping)
	   - KEY_COMPONENTS (array of all components)
	   - KEY_LOCK_CONSTRUCT (construction attempt IDs)
	4. Destroys the Trove, which:
	   - Disconnects CollectionService tag signals
	   - Disconnects all ancestry watching connections
	   - Cleans up Started, Stopped, and AncestorsChanged signals

	## Memory Leak Prevention

	This method ensures no references to component instances or Roblox instances
	are retained after destruction. All internal tables are cleared, and the Trove
	pattern ensures all connections are properly disconnected.

	## Usage

	```lua
	local MyComponent = Component.new({Tag = "MyComponent"})
	-- ... later when you want to completely disable this component class ...
	MyComponent:Destroy()
	```
]=]
function Component:Destroy()
	local idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	end

	-- Clear component tracking tables to prevent memory leaks
	-- Stop all active components first
	for _, component in pairs(self[KEY_INST_TO_COMPONENTS]) do
		if component[KEY_STARTED] or component[KEY_STARTING] then
			task.spawn(component.Stop, component)
		end
	end

	-- Destroy the trove which will clean up all connections
	self[KEY_TROVE]:Destroy()

	-- Clear all tracking tables
	table.clear(self[KEY_INST_TO_COMPONENTS])
	table.clear(self[KEY_COMPONENTS])
	table.clear(self[KEY_LOCK_CONSTRUCT])

end

return Component
