-- Component
-- Stephen Leitnick, Logan Hunt
-- November 26, 2021

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
	.Methods {[string]: function}?

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
	local player = game:GetService("Players").LocalPlayer

	local OnlyLocalPlayer = {}
	function OnlyLocalPlayer.ShouldConstruct(component)
		local ownerId = component.Instance:GetAttribute("OwnerId")
		return ownerId == player.UserId
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
type table = {[any]: any}
type Component = table
type ComponentClass = table

local IS_SERVER = RunService:IsServer()
local DEFAULT_ANCESTORS = { workspace, game:GetService("Players") }
local DEFAULT_TIMEOUT = 60
local UNSETUP_COMPONENTS = {}

-- Symbol keys:
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

local function InvokeExtensionFn(component, fnName: string)
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension[fnName]
		if type(fn) == "function" then
			fn(component)
		end
	end
end

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

-- Handles which extensions should be applied and in what order.
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

-- Added by Raildex
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

local function BindExtensionMethods(component, extensionList)
	for _, extension in ipairs(extensionList) do
		BindExtensionMethod(component, extension)
	end
end

--[=[
    @class Component

    This is a fork of the original Component module by Stephen Leitnick. This fork expands upon the functionality of
    extensions and provides several new useful methods.


    Bind components to Roblox instances using the Component class and CollectionService tags.

    To avoid confusion of terms:
    - `Component` refers to this module.
    - `Component Class` (e.g. `MyComponent` through this documentation) refers to a class created via `Component.new`
    - `Component Instance` refers to an instance of a component class.
    - `Roblox Instance` refers to the Roblox instance to which the component instance is bound.

    Methods and properties are tagged with the above terms to help clarify the level at which they are used.
]=]
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
function Component.getUnsetupComponents(): {ComponentClass}
	return table.clone(UNSETUP_COMPONENTS) :: any
end


function Component:_instantiate(instance: Instance)
	local component = setmetatable({}, self)
	component.Instance = instance

	component[KEY_ACTIVE_EXTENSIONS] = GetActiveExtensions(component, self[KEY_EXTENSIONS], table.clone(self[KEY_CLASS_ACTIVE_EXTENSIONS] :: any))
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		if not table.find(self[KEY_CLASS_ACTIVE_EXTENSIONS], extension) then
			BindExtensionMethod(component, extension)
		end
	end

	if not ShouldConstruct(component) then
		return nil
	end
	InvokeExtensionFn(component, "Constructing")
	if type(component.Construct) == "function" then
		component:Construct()
	end
	InvokeExtensionFn(component, "Constructed")
	return component
end

--[=[
	@tag Component Class
	@within Component
	@method _setup

	This is an internal method that is called to set up the component class.
	It is automatically called when the component class is created, unless the
	`DelaySetup` option is set to `true` in the component configuration.
	If `DelaySetup` is `true`, then this method must be called manually.
]=]
function Component:_setup()
	local idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	else
		warn(self, ":_setup was already called for this component.")
	end
	
	local watchingInstances = {}

	self[KEY_CLASS_ACTIVE_EXTENSIONS] = GetActiveExtensions(self, self[KEY_EXTENSIONS], {}, true)
	BindExtensionMethods(self, self[KEY_CLASS_ACTIVE_EXTENSIONS]) -- Added by Raildex

	local function StartComponent(component)
		component[KEY_STARTING] = coroutine.running()

		InvokeExtensionFn(component, "Starting")

		component:Start()
		if component[KEY_STARTING] == nil then
			-- Component's Start method stopped the component
			return
		end

		InvokeExtensionFn(component, "Started")

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

	local function StopComponent(component)
		if component[KEY_STARTING] then
			-- Stop the component during its start method invocation:
			local startThread = component[KEY_STARTING] :: thread
			if coroutine.status(startThread) ~= "normal" then
				pcall(function()
					task.cancel(startThread)
				end)
			else
				task.defer(function()
					pcall(function()
						task.cancel(startThread)
					end)
				end)
			end
			component[KEY_STARTING] = nil
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

	local function SafeConstruct(instance, id)
		if self[KEY_LOCK_CONSTRUCT][instance] ~= id then
			return nil
		end
		local component = self:_instantiate(instance)
		if self[KEY_LOCK_CONSTRUCT][instance] ~= id then
			return nil
		end
		return component
	end

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

	local function TryDeconstructComponent(instance)
		local component = self[KEY_INST_TO_COMPONENTS][instance]
		if not component then
			return
		end
		self[KEY_INST_TO_COMPONENTS][instance] = nil
		self[KEY_LOCK_CONSTRUCT][instance] = nil
		local components = self[KEY_COMPONENTS] :: table
		local index = table.find(components, component)
		if index then
			local n = #components
			components[index] = components[n]
			components[n] = nil
		end
		if component[KEY_STARTED] or component[KEY_STARTING] then
			task.spawn(StopComponent, component)
		end
	end

	local function StartWatchingInstance(instance)
		if watchingInstances[instance] then
			return
		end
		local function IsInAncestorList(): boolean
			for _, parent in ipairs(self[KEY_ANCESTORS] :: {Instance}) do
				if instance:IsDescendantOf(parent) then
					return true
				end
			end
			return false
		end
		local ancestryChangedHandle = self[KEY_TROVE]:Connect(RailUtil.Signal.combine({
			instance.AncestryChanged,
			self.AncestorsChanged,
		}), function(_, parent)
			if parent and IsInAncestorList() then
				TryConstructComponent(instance)
			else
				TryDeconstructComponent(instance)
			end
		end)
		watchingInstances[instance] = ancestryChangedHandle
		if IsInAncestorList() then
			TryConstructComponent(instance)
		end
	end

	local function InstanceTagged(instance: Instance)
		StartWatchingInstance(instance)
	end

	local function InstanceUntagged(instance: Instance)
		local watchHandle = watchingInstances[instance]
		if watchHandle then
			watchingInstances[instance] = nil
			self[KEY_TROVE]:Remove(watchHandle)
		end
		TryDeconstructComponent(instance)
	end

	self[KEY_TROVE]:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), InstanceTagged)
	self[KEY_TROVE]:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), InstanceUntagged)

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
function Component:UpdateAncestors(newAncestors: {Instance})
	local lastAncestors = self[KEY_ANCESTORS]
	self[KEY_ANCESTORS] = newAncestors
	self.AncestorsChanged:Fire(newAncestors, lastAncestors)
end

--[=[
	@tag Component Class

	Gets the current valid ancestors of a component class.
]=]
function Component:GetAncestors(): {Instance}
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
	you may make within it. The Janitor is cleaned up whenever either compenent is stopped.

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
function Component:WhileHasComponent(componentClassOrClasses: ComponentClass | {ComponentClass}, fn: (components: Component | {Component}, jani: Janitor) -> ())
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
		end
	})

	bindJani:Add(connProxy)
	bindJani:AddPromise(Promise.fromEvent(self.Stopped, function(c)
		return c.Instance == self.Instance
	end):andThen(connProxy.Destroy))

	assert(typeof(componentClassOrClasses) == "table", "Component:WhileHasComponent() expects a component class or an array of component classes.")
	local isSingleComponentClass = if (componentClassOrClasses :: any).Tag == nil then true else false
	-- Normalize to array of classes
	local componentClasses = if isSingleComponentClass then componentClassOrClasses else {componentClassOrClasses}

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

	-- Track janitors for each set of components
	local activeJanitors = {}

	local function SetupIfAllPresent()
		local components = getAllComponents()
		if not components then return end
		-- Prevent duplicate setups for the same set
		if activeJanitors[self.Instance] then return end
		local currentJani = bindJani:Add(Janitor.new(), "Destroy", self.Instance)
		activeJanitors[self.Instance] = currentJani

		if isSingleComponentClass then
			-- If only one component class, just pass it directly to maintain backwards compatibility
			components = table.unpack(components)
		end
		currentJani:Add(task.spawn(fn, components, currentJani))

		-- If any component stops, destroy janitor
		for i, class in ipairs(componentClasses) do
			currentJani:AddPromise(Promise.fromEvent(class.Stopped, function(c)
				return c.Instance == self.Instance
			end):andThen(function()
				currentJani:Destroy()
				activeJanitors[self.Instance] = nil
			end))
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

-- DEPRECATED: Use WhileHasComponent instead. Kept for backwards compat
function Component:ForEachSibling(...)
	warn("ForEachSibling is deprecated. Use WhileHasComponent instead.")
	return self:WhileHasComponent(...)
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

function Component:Destroy()
	local idx = table.find(UNSETUP_COMPONENTS, self)
	if idx then
		table.remove(UNSETUP_COMPONENTS, idx)
	end
	self[KEY_TROVE]:Destroy()
end

return Component
