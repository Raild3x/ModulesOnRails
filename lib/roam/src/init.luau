--!strict
-- Logan Hunt (Raildex)
-- September 12, 2022
-- DOCUMENTATION LINK: https://raild3x.github.io/ModulesOnRails/api/Roam
--[=[
	@class Roam

	Roam is a systems bootstrapping tool for Roblox luau projects, designed to make it easy to
	initialize and start services in a topologically sorted manner without the need to
	manually order and start services.
	
	Roam follows a design pattern similar to [Knit](https://sleitnick.github.io/Knit/), but is more lightweight. 
	It removes all networking and replication functionality, and instead focuses on providing a simple methodology 
	to easily initialize and start Services given to it.

	Roam is RunContext agnostic, meaning it can be used on both the server and client in the same manner.
	It makes no distinction between the two, and instead focuses on providing a simple
	interface for initializing and starting services. This means you could create a service and register it on 
	both the server and client, and it will be initialized and started on both ends. 

	**[EXAMPLE SERVICE]**
	```lua 
	-- MyService.lua
	local MyService = {}

	function MyService:RoamInit()
		print("MyService initialized!")
	end

	function MyService:RoamStart()
		print("MyService started!")
	end

	-- Register the service table with Roam
	local Roam = require(ReplicatedStorage.Roam)
	Roam.registerService(MyService, "MyService")

	return MyService
	```

	**[EXAMPLE STARTUP]**
	```lua 
	-- ServerBootstrapper.server.lua
	local Roam = require(ReplicatedStorage.Roam)

	-- Require your services. (Tip: Roam.requireModules can help abstract this process!)
	require(ReplicatedStorage.MyService)

	-- Start Roam
	Roam.start()
	:andThenCall(print, "Roam started!")
	:catch(warn)
	```

	**[CONTRACTS]**
	- Services must be created/registered before Roam is started.
	- Services must be created/registered with a unique name.
	- Services with `RoamInit` and `RoamStart` methods will have those methods
	  called when Roam is started at the appropriate time. (Names are configurable)
	- `RequiredServices` boot in proper topological order if specified in the ServiceConfig.
	- Roam functions the same regardless of RunContext (Server/Client).

	:::info Setting up Services
	Services can be set up in a variety of ways. The most common way is to create a ModuleScript
	that returns a table with the methods you want to define, and then register it with Roam just prior
	to the final module's return.

	See [Roam.registerService](Roam#registerService) for more information on setting up a new service.
	:::
	
	:::tip Networking
	Roam does not inherently have networking functionality. However, it can easily be added through the use of NetWire's 
	**[.setupServiceNetworking](https://raild3x.github.io/ModulesOnRails/api/ServerNetWire/#setupServiceNetworking)** funtion.
	:::

	----
	LIFECYCLE
	----
	For those interested in the full execution order roam follows for booting services, see the diagrams below:

	**Initialization Phase (Synchronous):**
	- `GlobalPreInit` - Called once before ANY service initializes (global setup)
	- For each service (in dependency order):
		- Await dependencies to finish initializing
		- `PreInit(service)` - Called before this service's RoamInit
		- Service's `RoamInit()` method executes
		- `PostInit(service)` - Called after this service's RoamInit
	- `GlobalPostInit` - Called once after ALL services finish initializing
	
	**Start Phase (Fully Async - Does Not Block):**
	- `GlobalPreStart` - Called once before ANY service starts.
	- For each service (in dependency order):
		- `PreStart(service)` - Called before this service's RoamStart
		- Service's `RoamStart()` method executes
		- `PostStart(service)` - Called after this service's RoamStart
	- `GlobalPostStart` - Called once after ALL services start


	**Key Concepts:**
	- **Parallel Initialization**: Services without dependencies initialize concurrently via coroutines
	- **Dependency Blocking**: Services wait for their dependencies' PostInit before starting their PreInit
	- **Synchronous Init Phase**: The Initialization Phase completes fully before Start Phase begins
	- **Async Start Phase**: The Start Phase spawns services lifecycle methods asynchronously

	![Advanced Roam Lifecycle Diagram](../roam/RoamLifecycleAdvanced.png)
]=]

local RunService = game:GetService("RunService")

local Packages = script.Parent
local Promise = require(Packages.Promise)
local Symbol = require(Packages.Symbol)

local Roam = {}

--------------------------------------------------------------------------------
--// Types //--
--------------------------------------------------------------------------------

type table = { [any]: any }
export type Service = table

--[=[
	@within Roam
	@interface ServiceConfig
	@field Name string -- Name of the Service. Must be unique. Used when accessing via .getService
	@field RequiredServices {Service}? -- The Services that this Service depends on. Roam will ensure that these Services are initialized before this Service.
	@field StartMethodName string? -- Overrides default StartMethodName of "RoamStart"
	@field InitMethodName string? -- Overrides default InitMethodName of "RoamInit"

	```lua
	local myOtherService = require(ReplicatedStorage.MyOtherService)

	-------------------------------------------------

	local MyService = {}

	function MyService:CustomStartMethod()
		print("MyService started!")
	end

	-------------------------------------------------

	Roam.registerService(MyService, {
		Name = "MyService",
		RequiredServices = {myOtherService},
		StartMethodName = "CustomStartMethod",
	})

	return MyService
	```

	:::caution Deferring RequiredServices
	Do NOT add services to the RequiredServices after you have created or registered the service. This will cause undefined behavior.
	:::
]=]
export type ServiceConfig = {
	Name: string, -- Name of the Service. Must be unique. Used when accessing via .getService
	RequiredServices: { Service }?, -- The Services that this Service depends on. Roam will ensure that these Services are initialized before this Service.
	StartMethodName: string?, -- Overrides default StartMethodName of "RoamStart"
	InitMethodName: string?, -- Overrides default InitMethodName of "RoamInit"
	InitTimeout: number?, -- Overrides default init timeout in seconds (default: 120)
	[any]: any,
}

--[=[
	@within Roam
	@private
	@tag debug
	@type ServiceState "REGISTERED" | "AWAITING_DEPENDENCIES" | "PRE_INIT" | "ROAM_INIT" | "POST_INIT" | "INITIALIZED" | "PRE_START" | "ROAM_START" | "POST_START" | "STARTED" | "FAILED"

	Represents the current lifecycle state of a service:
	- `REGISTERED` - Service has been registered but not yet initialized
	- `AWAITING_DEPENDENCIES` - Service is waiting for its RequiredServices to finish initializing
	- `PRE_INIT` - Calling PreInit with service
	- `ROAM_INIT` - Calling Service:RoamInit method
	- `POST_INIT` - Calling PostInit with service
	- `INITIALIZED` - Service has completed all initialization steps
	- `PRE_START` - Calling PreStart with service
	- `ROAM_START` - Calling Service:RoamStart method
	- `POST_START` - Calling PostStart with service
	- `ACTIVE` - Service is actively running and has completed its startup routine
	- `FAILED` - Service initialization failed
]=]
export type ServiceState =
	"REGISTERED"
	| "AWAITING_DEPENDENCIES"
	| "PRE_INIT"
	| "ROAM_INIT"
	| "POST_INIT"
	| "INITIALIZED"
	| "PRE_START"
	| "ROAM_START"
	| "POST_START"
	| "STARTED"
	| "FAILED"

type Promise = typeof(Promise.new())

--[=[
	@within Roam
	@interface StartConfig
	.GlobalPreInit (() -> ())? -- Called once before ANY service initializes
	.PreInit ((service: Service) -> ())? -- Called before each service's RoamInit
	.PostInit ((service: Service) -> ())? -- Called after each service's RoamInit
	.GlobalPostInit (() -> ())? -- Called once after ALL services finish initializing
	.GlobalPreStart (() -> ())? -- Called once before ANY service starts. (Async)
	.PreStart ((service: Service) -> ())? -- Called before each service's RoamStart (Async)
	.PostStart ((service: Service) -> ())? -- Called after each service's RoamStart (Async)
	.GlobalPostStart (() -> ())? -- Called once after ALL services start (Async)

	Yielding in `Init` lifecycle hooks will prevent Roam from progressing to the next step.
	
	`Start` lifecycle hooks are fully asynchronous and do not block progression at any point.
]=]
export type StartConfig = {
	GlobalPreInit: (() -> Promise?)?,
	PreInit: ((service: Service) -> Promise?)?,
	PostInit: ((service: Service) -> Promise?)?,
	GlobalPostInit: (() -> Promise?)?,
	GlobalPreStart: (() -> ())?,
	PreStart: ((service: Service) -> ())?,
	PostStart: ((service: Service) -> ())?,
	GlobalPostStart: (() -> ())?,
}

--------------------------------------------------------------------------------
--// Constants //--
--------------------------------------------------------------------------------

local KEY_CONFIG = Symbol("RoamServiceConfig")
local DEFAULT_START_METHOD = "RoamStart"
local DEFAULT_INIT_METHOD = "RoamInit"
local INIT_TIMEOUT_SECONDS = 120
local RUN_CONTEXT = RunService:IsServer() and "SERVER" or "CLIENT"

--------------------------------------------------------------------------------
--// State //--
--------------------------------------------------------------------------------

local services: { [string]: Service } = {}
local serviceStates: { [Service]: ServiceState } = {} -- Track state of each service
local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

--------------------------------------------------------------------------------
--// Utility Functions //--
--------------------------------------------------------------------------------

local function serviceNameMatch(obj: Instance): boolean
	return obj.Name:match("Service$") ~= nil
end

local function setServiceState(service: Service, state: ServiceState): ()
	serviceStates[service] = state
end

local function serviceExists(service: string | table): boolean
	if type(service) == "string" then
		return services[service] ~= nil
	elseif type(service) == "table" then
		-- Check if the service table is registered
		for _, registeredService in pairs(services) do
			if registeredService == service then
				return true
			end
		end
		return false
	else
		error("serviceExists expects a string or table as argument")
	end
end

local FAILED_REQUIRE_YIELD = Symbol("FailedRequireYield")
local function ensureUnyieldingRequire(module: ModuleScript)
	local moduleContent = FAILED_REQUIRE_YIELD
	task.spawn(function()
		local current
		task.spawn(function()
			current = coroutine.running()
			local success, msg = pcall(function()
				moduleContent = require(module) :: any
			end)
			assert(success, `Failed to load module: {module.Name}\n{msg}`)
		end)

		if coroutine.status(current) ~= "dead" then
			-- This is not a great traceback. I wish it could find the original yield point, but I can't detect which modules are being required.
			error(
				`Roam Require detected yield. Check the following module and the modules it requires: {module:GetFullName()}`
			)
		end
	end)

	return moduleContent
end

local function formatError(context: string, details: string): string
	return `[Roam {RUN_CONTEXT}] {context}: {details}`
end

--------------------------------------------------------------------------------
--// Validation Functions //--
--------------------------------------------------------------------------------

local function validateServiceConfig(serviceConfig: any, serviceName: string?): ServiceConfig
	if typeof(serviceConfig) == "string" then
		serviceConfig = { Name = serviceConfig }
	elseif not serviceConfig then
		serviceConfig = {}
	end

	if typeof(serviceConfig) ~= "table" then
		error(formatError("Invalid ServiceConfig", `Expected table, got {typeof(serviceConfig)}`))
	end

	local name = serviceConfig.Name or serviceName
	if not name then
		error(formatError("Missing Service Name", "Service must have a name"))
	end

	if type(name) ~= "string" or #name == 0 then
		error(formatError("Invalid Service Name", `Name must be a non-empty string, got {type(name)}`))
	end

	if serviceExists(name) then
		error(formatError("Duplicate Service", `Service "{name}" already exists`))
	end

	if serviceConfig.RequiredServices then
		for i, requiredService in ipairs(serviceConfig.RequiredServices) do
			if type(requiredService) ~= "table" then
				error(
					formatError(
						"Invalid Required Service",
						`RequiredServices[{i}] must be a Service table, got {typeof(requiredService)} while registering "{name}"`
					)
				)
			end
			if not serviceExists(requiredService) then
				warn(
					formatError(
						"Unregistered Required Service",
						`RequiredServices[{i}] is not a registered service while registering "{name}"`
					)
				)
			end
		end
	end

	-- remove duplicates from RequiredServices
	if serviceConfig.RequiredServices then
		local seen = {}
		local uniqueRequiredServices = {}
		for i, reqService in ipairs(serviceConfig.RequiredServices) do
			if not seen[reqService] then
				seen[reqService] = true
				table.insert(uniqueRequiredServices, reqService)
			else
				warn(
					formatError(
						"Duplicate RequiredService",
						`Service "{name}" has duplicate required service at index {i}`
					)
				)
			end
		end
		serviceConfig.RequiredServices = uniqueRequiredServices
	end

	return serviceConfig :: ServiceConfig
end

local function validateRequiredServices(): { string }
	local missingServices = {}

	for serviceName, service in pairs(services) do
		local config: ServiceConfig = service[KEY_CONFIG]
		if not config.RequiredServices then
			continue
		end

		for _, requiredService in ipairs(config.RequiredServices) do
			local found = false
			for _, existingService in pairs(services) do
				if requiredService == existingService then
					found = true
					break
				end
			end

			if not found then
				table.insert(missingServices, `Required service for '{serviceName}' not found`)
			end
		end
	end

	return missingServices
end

--------------------------------------------------------------------------------
--// Service Management //--
--------------------------------------------------------------------------------

local function createServiceInitPromise(service: Service, config: ServiceConfig): Promise?
	local initMethodName = config.InitMethodName or DEFAULT_INIT_METHOD
	local initMethod = service[initMethodName]

	if type(initMethod) ~= "function" then
		return Promise.resolve(0)
	end

	return Promise.new(function(resolve, reject)
		if Roam.Debug then
			print(`[{RUN_CONTEXT}] Initializing {config.Name}`)
		end

		local startTime = os.clock()
		local initFunction = service[initMethodName]

		-- Prevent re-initialization
		service[initMethodName] = function()
			error(`{config.Name} | Cannot call Init method after service has been initialized`)
		end

		local elapsed
		local initThread = task.spawn(function()
			debug.setmemorycategory(config.Name .. "_Init")
			initFunction(service)
			elapsed = os.clock() - startTime
		end)

		while coroutine.status(initThread) ~= "dead" do
			task.wait()
		end

		if not elapsed then
			reject(`Failed to initialize {config.Name}`)
			return
		end

		if Roam.Debug then
			print(`[{RUN_CONTEXT}] Initialized {config.Name} in {string.format("%.3f", elapsed)}s`)
		end

		resolve(elapsed)
	end):timeout(config.InitTimeout or INIT_TIMEOUT_SECONDS, `Service {config.Name} took too long to initialize`)
end

local function startService(service: Service, config: ServiceConfig): ()
	local startMethodName = config.StartMethodName or DEFAULT_START_METHOD
	local startMethod = service[startMethodName]

	if type(startMethod) ~= "function" then
		return
	end

	task.spawn(function()
		if Roam.Debug then
			print(`[{RUN_CONTEXT}] Starting {config.Name}`)
		end

		debug.setmemorycategory(config.Name .. "_Start")
		local startFunction = service[startMethodName]

		-- Prevent re-starting
		service[startMethodName] = function()
			error(`{config.Name} | Cannot call Start method after service has been started`)
		end

		startFunction(service)
	end)
end

--------------------------------------------------------------------------------
--// Topological Sorting //--
--------------------------------------------------------------------------------

local function createAdjacencyList(): { [Service]: { Service } }
	local adjacencyList = {}
	for _, service in pairs(services) do
		adjacencyList[service] = service[KEY_CONFIG].RequiredServices or {}
	end
	return adjacencyList
end

local function topologicalSort(adjacencyList: { [Service]: { Service } }): { Service }
	local visited = {}
	local stack = {}

	local function visit(service: Service)
		if visited[service] then
			return
		end

		visited[service] = true

		for _, dependency in ipairs(adjacencyList[service] or {}) do
			visit(dependency)
		end

		table.insert(stack, service)
	end

	for service in pairs(adjacencyList) do
		visit(service)
	end

	return stack
end

local function getSortedServices(): { Service }
	local adjacencyList = createAdjacencyList()
	return topologicalSort(adjacencyList)
end

--------------------------------------------------------------------------------
--// Main Roam Module //--
--------------------------------------------------------------------------------

--[=[
	@within Roam
	@deprecated 0.1.6
	@prop Services {[string]: Service}
	A table of Services. Only properly accessible after Roam has been started.
]=]
Roam.Services = services -- A table of Services. Only properly accessible after Roam has been started.

Roam.ServiceNameMatch = serviceNameMatch

--[=[
	@within Roam
	@tag debug
	@private
	@prop Debug boolean
	Whether or not to print debug messages. Default is false.
]=]
Roam.Debug = false -- Whether or not to print debug messages

--[=[
	@within Roam
	@private
	@prop DEFAULT_SRC_NAME string
	The default name of the source folder where your modules are located. Default is "src".
	This is only used by the generic Bootstrappers provided with Roam.
]=]
Roam.DEFAULT_SRC_NAME = "src"

--[=[
	@within Roam
	@prop Bootstrappers {Server: (script: Script) -> Promise, Client: (script: Script) -> Promise}
	A table of generic bootstrappers for Roam that you can use to quickly setup new projects.
	```lua
	local Roam = require(Packages.Roam)
	
	Roam.Bootstrappers.Server(script)
	:andThenCall(print, "Roam Server Bootstrapped!")
	```
]=]
type BootStrapper = (script: Script, config: { [string]: any }?) -> Promise
Roam.Bootstrappers = { -- Generic Bootstrappers for Roam / Orion
	Server = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ServerBootstrapper")) :: BootStrapper,
	Client = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ClientBootstrapper")) :: BootStrapper,
}

--[=[
	Registers a Service/Table with Roam to be Initialized and Started when Roam starts.
	Cannot be called after Roam has been started.

	```lua -- MyRegisteredService.lua
	local MyRegisteredService = {}

	function MyRegisteredService:RoamStart()
		print("MyRegisteredService started!")
	end

	function MyRegisteredService:RoamInit()
		print("MyRegisteredService initialized!")
	end

	----------------------------------------------------------------

	local Roam = require(Packages.Roam)
	Roam.registerService(MyRegisteredService, "MyRegisteredService")

	return MyRegisteredService
	```
]=]
function Roam.registerService(service: Service, serviceConfig: (ServiceConfig | string)?): Service
	if started then
		error(formatError("Registration Error", "Cannot register services after Roam has started"))
	end

	if type(service) ~= "table" then
		error(formatError("Invalid Service", `Service must be a table, got {type(service)}`))
	end

	local config = validateServiceConfig(serviceConfig, service.Name)

	service[KEY_CONFIG] = config
	services[config.Name] = service
	serviceStates[service] = "REGISTERED" -- Track initial state

	return service
end

--[=[
	@within Roam

	Starts Roam. Should only be called once. Calling multiple times will result in a promise rejection.

	Optional config argument provides lifecycle hooks.

	```lua
	Roam.start({
		GlobalPreInit = function()
			print("=== Initialization Phase Starting ===")
		end,
		PreInit = function(service)
			print("Initializing:", Roam.getServiceName(service))
		end,
		PostInit = function(service)
			print("✓ Initialized:", Roam.getServiceName(service))
		end,
		GlobalPostInit = function()
			print("=== All Services Initialized ===")
		end,
	})
	:andThenCall(print, "Roam started!")
	:catch(warn)
	```

	:::caution
	Be sure that all services have been created _before_
	calling `Start`. Services cannot be added later.
	:::
]=]
function Roam.start(config: StartConfig?): Promise
	if started then
		return Promise.reject("Roam already started")
	end

	-- Validate and extract lifecycle hooks from config
	local function validateHook(hookName: string): ((...any) -> any)?
		if not config then
			return nil
		end

		local hookValue = (config :: any)[hookName]
		if hookValue ~= nil and type(hookValue) ~= "function" then
			error(formatError("Invalid Parameter", `{hookName} must be a function or nil, got {type(hookValue)}`))
		end
		return hookValue
	end

	-- Helper to call a lifecycle hook and handle Promise results
	local function callLifecycleHook(hook: ((service: Service?) -> Promise?)?, service: Service?, async: boolean?)
		if not hook then
			return
		end

		if async then
			task.defer(hook, service)
		else
			local result = hook(service)
			-- If the hook returns a Promise, await it
			if result and typeof(result) == "table" and result.await then
				result:await()
			end
		end
	end

	-- Extract and validate all lifecycle hooks
	local globalPreInit = validateHook("GlobalPreInit")
	local preInit = validateHook("PreInit")
	local postInit = validateHook("PostInit")
	local globalPostInit = validateHook("GlobalPostInit")
	local globalPreStart = validateHook("GlobalPreStart")
	local preStart = validateHook("PreStart")
	local postStart = validateHook("PostStart")
	local globalPostStart = validateHook("GlobalPostStart")

	started = true

	-- Validate all required services are registered
	local missingServices = validateRequiredServices()
	if #missingServices > 0 then
		error(formatError("Missing Dependencies", table.concat(missingServices, "; ")))
	end

	local sortedServices = getSortedServices()

	return Promise.new(function(resolve, reject)
		local startTime = os.clock()
		table.freeze(services)
		Roam.Services = services

		-- GlobalPreInit hook
		callLifecycleHook(globalPreInit)

		-- Track completion promises for each service (for dependency blocking)
		local rejectedInitializations: { string } = {}
		local serviceCompletionPromises: { [Service]: Promise } = {}
		local initPromises: { Promise } = {}

		-- Initialize services with dependency-aware parallelization
		for _, service in ipairs(sortedServices) do
			local serviceConfig = service[KEY_CONFIG]

			local dependencyPromises = {}
			if serviceConfig.RequiredServices then
				for _, requiredService in ipairs(serviceConfig.RequiredServices) do
					local depPromise = serviceCompletionPromises[requiredService]
					if depPromise then
						table.insert(dependencyPromises, depPromise)
					else
						warn(
							formatError(
								"Missing Dependency Promise",
								`Service "{serviceConfig.Name}" has a required service that lacks a completion promise`
							)
						)
					end
				end
			end

			serviceStates[service] = "AWAITING_DEPENDENCIES"
			local errMsg = "\n - " .. serviceConfig.Name

			local servicePromise = Promise.all(dependencyPromises):andThen(function()
				-- Dependencies are ready
				return Promise.resolve()
					:andThenCall(setServiceState, service, "PRE_INIT")
					:andThenCall(callLifecycleHook, preInit, service)
					:andThenCall(setServiceState, service, "ROAM_INIT")
					:andThenCall(createServiceInitPromise, service, serviceConfig)
					:andThenCall(setServiceState, service, "POST_INIT")
					:andThenCall(callLifecycleHook, postInit, service)
					:andThenCall(setServiceState, service, "INITIALIZED")
					:catch(function(err)
						table.insert(rejectedInitializations, errMsg)
						serviceStates[service] = "FAILED"
						return Promise.reject(err)
					end)
			end, function(err)
				table.insert(rejectedInitializations, errMsg .. " (Dependency Failed) [" .. tostring(err) .. "]")
				serviceStates[service] = "FAILED"
				return Promise.reject(err)
			end)

			-- Track this service's completion for dependent services
			serviceCompletionPromises[service] = servicePromise
			table.insert(initPromises, servicePromise)
		end

		-- Wait for all services to complete initialization
		local success: boolean = Promise.all(initPromises):await()

		if success then
			-- GlobalPostInit hook
			callLifecycleHook(globalPostInit)
			local totalInitTime = os.clock() - startTime
			if Roam.Debug then
				print(`[{RUN_CONTEXT}] All services initialized in {string.format("%.3f", totalInitTime)}s`)
			end
			resolve(totalInitTime)
		else
			local errMsg =
				formatError("Initialization Failed for the following services", table.concat(rejectedInitializations))
			reject(errMsg)
		end
	end):andThen(function()
		---------------------------------------------------------------------
		-- START Phase (Fully Async - Does Not Block) --
		---------------------------------------------------------------------

		-- GlobalPreStart hook
		callLifecycleHook(globalPreStart, nil, true)

		-- Start services with interleaved hooks (respects dependency order)
		for _, service in ipairs(sortedServices) do
			if serviceStates[service] == "FAILED" then
				continue -- skip starting failed services
			end
			local serviceConfig = service[KEY_CONFIG]
			-- PreStart hook
			serviceStates[service] = "PRE_START"
			callLifecycleHook(preStart, service, true)

			-- Service Start
			serviceStates[service] = "ROAM_START"
			startService(service, serviceConfig)

			-- PostStart hook
			serviceStates[service] = "POST_START"
			callLifecycleHook(postStart, service, true)

			serviceStates[service] = "STARTED"
		end

		-- GlobalPostStart hook
		callLifecycleHook(globalPostStart, nil, true)

		startedComplete = true
		onStartedComplete:Fire()

		task.defer(function()
			onStartedComplete:Destroy()
		end)
	end)
end

--[=[
	@return Promise
	Returns a promise that is resolved once Roam has started. This is useful
	for any code that needs to tie into Roam services but is not the script
	that called `start`.
	```lua
	Roam.onStart():andThen(function()
		local MyService = require(ReplicatedStorage.MyService)
		MyService:DoSomething()
	end):catch(warn)
	```
]=]
function Roam.onStart(): Promise
	if startedComplete then
		return Promise.resolve()
	else
		return Promise.fromEvent(onStartedComplete.Event)
	end
end

--[=[
	Returns whether or not Roam has been successfully started and is ready for external access.
]=]
function Roam.isReady(): boolean
	return startedComplete
end

--[=[
	Requires all the modules that are children of the given parent. This is an easy
	way to quickly load all services that might be in a folder. Takes an optional predicate
	function to filter which modules are loaded. Services collected this way must not yield.
	- `DeepSearch` -> whether it checks descendants or just children
	- `AllowYieldingRequires` -> whether to allow required modules to yield (default: false)
	- `RequirePredicate` -> a predicate function that determines whether a module should be required
	- `IgnoreDescendantsPredicate` -> A Predicate for whether the Descendants of an instance should be Searched (Only matters if DeepSearch is true)
	- `StopOnFailedRequire` -> whether to stop requiring modules if one fails to require (default: false). Useful for debugging, helps to clear excessive noise from the output.

	```lua
	local pred = function(obj: ModuleScript): boolean
		return obj.Name:match("Service$") ~= nil
	end

	Roam.requireModules(ReplicatedStorage.Shared, {
		DeepSearch = true,
		RequirePredicate = pred,
		IgnoreDescendantsPredicate = function(obj: Instance): boolean
			return obj.Name == "Ignore"
		end,
	})
	```
]=]
function Roam.requireModules(
	parents: Instance | { Instance },
	config: {
		DeepSearch: boolean?,
		AllowYieldingRequires: boolean?,
		StopOnFailedRequire: boolean?,
		RequirePredicate: ((obj: ModuleScript) -> boolean)?,
		IgnoreDescendantsPredicate: ((obj: Instance) -> boolean)?,
	}?
): {
	Success: boolean,
	ModuleContent: { [ModuleScript]: any },
	FailedModuleRequires: { ModuleScript },
}
	if typeof(parents) == "Instance" then
		parents = { parents }
	end

	config = config or {}
	if typeof(config) ~= "table" then
		error(formatError("Invalid Config", `Config must be a table, got {typeof(config)}`))
	end

	local deepSearch = config.DeepSearch or false
	local requirePredicate = config.RequirePredicate
	local ignoreDescendantsPredicate = config.IgnoreDescendantsPredicate
	local successfullyRequiredModuleContent = {}
	local failedModuleRequires = {}

	local function searchInstance(obj: Instance | { Instance })
		if typeof(obj) == "table" then
			for _, child in ipairs(obj) do
				local success = searchInstance(child)
				if not success and config.StopOnFailedRequire then
					return false
				end
			end
			return true
		end

		if typeof(obj) ~= "Instance" then
			error(formatError("Invalid Object", `Expected Instance or table of Instances, got {typeof(obj)}`))
		end

		if obj:IsA("ModuleScript") and (not requirePredicate or requirePredicate(obj)) then
			if config.AllowYieldingRequires then
				local success, moduleContent = pcall(function()
					return require(obj) :: any
				end)
				if success then
					successfullyRequiredModuleContent[obj] = moduleContent
					return true
				else
					table.insert(failedModuleRequires, obj)
					return false
				end
			end

			local moduleContent = ensureUnyieldingRequire(obj)
			if moduleContent == FAILED_REQUIRE_YIELD then
				table.insert(failedModuleRequires, obj)
				return false
			end

			successfullyRequiredModuleContent[obj] = moduleContent
		end

		if deepSearch and (not ignoreDescendantsPredicate or not ignoreDescendantsPredicate(obj)) then
			return searchInstance(obj:GetChildren())
		end
		return true
	end

	if typeof(parents) ~= "table" then
		error(formatError("Invalid Parents", "Parents must be an Instance or table of Instances"))
	end

	searchInstance(parents)

	return {
		Success = #failedModuleRequires == 0,
		ModuleContent = successfullyRequiredModuleContent,
		FailedModuleRequires = failedModuleRequires,
	}
end

--------------------------------------------------------------------------------
--// DEBUG //--
--------------------------------------------------------------------------------
--[=[
	@within Roam
	@private
	@tag debug
	Prints the dependency graph of all registered services to the output.
]=]
function Roam.printDependencyGraph(): ()
	print("Service Dependency Graph:")
	for serviceName, service in pairs(services) do
		local config = service[KEY_CONFIG]
		print(`  {serviceName}:`)
		if config.RequiredServices then
			for _, dep in ipairs(config.RequiredServices) do
				local depName = dep[KEY_CONFIG].Name
				print(`    -> {depName}`)
			end
		else
			print("    (no dependencies)")
		end
	end
end

--[=[
	@within Roam
	@private
	@tag debug
	Returns the current lifecycle state of a service.
	
	@param serviceName string | Service -- Either the name of the service or the service table itself
	@return ServiceState? -- The current state of the service, or nil if not found
	
	```lua
	local state = Roam.getServiceState("MyService")
	if state == "STARTED" then
		print("MyService is fully running!")
	end
	```
]=]
function Roam.getServiceState(serviceName: string | Service): ServiceState?
	local service: Service?

	if type(serviceName) == "string" then
		service = services[serviceName]
	elseif type(serviceName) == "table" then
		service = serviceName
	else
		error(
			formatError(
				"Invalid Argument",
				`getServiceState expects a string or Service table, got {type(serviceName)}`
			)
		)
	end

	if not service then
		return nil
	end

	return serviceStates[service]
end

--[=[
	@within Roam
	@private
	@tag debug
	Fetches the name of a registered Service.
]=]
function Roam.getServiceName(service: Service): string
	local config = service[KEY_CONFIG]
	if not config then
		error(formatError("Invalid Service", "Service is not registered with Roam"))
	end
	return config.Name
end
Roam.getNameFromService = Roam.getServiceName -- backwards compat

--------------------------------------------------------------------------------
--// DEPRECATED //--
--------------------------------------------------------------------------------
--[=[
	@deprecated 0.1.5
	@private
	Creates a Service/Table with Roam to be Initialized and Started when Roam starts.
	Cannot be called after Roam has been started.

	This is an alternative method to setting up services over using `registerService`.

	```lua
	local Roam = require(ReplicatedStorage.Roam)

	local MyService = Roam.createService { Name = "MyService" }
	
	function MyService:DoSomething()
		print("yeee haw!")
	end

	-- Default StartMethodName is "RoamStart" (Can be overriden in service creation config)
	function MyService:RoamStart()
		print("MyService started!")
		self:DoSomething()
	end

	-- Default InitMethodName is "RoamInit" (Can be overriden in service creation config)
	function MyService:RoamInit()
		print("MyService initialized!")
	end

	return MyService
	```
]=]
function Roam.createService(serviceDef: ServiceConfig): Service
	warn("[Roam] createService is deprecated, use registerService instead")
	return Roam.registerService(serviceDef, serviceDef)
end

--[=[
	@deprecated 0.1.5
	@private
	Fetches a registered Service by name.
	Cannot be called until Roam has been started.
]=]
function Roam.getService(serviceName: string): Service
	warn("[Roam] getService is deprecated. Prefer to use direct requires")

	if not started then
		warn(formatError("Early Access", "Services accessed before Roam started\n" .. debug.traceback()))
	end

	if type(serviceName) ~= "string" then
		error(formatError("Invalid Service Name", `ServiceName must be a string, got {type(serviceName)}`))
	end

	local service = services[serviceName]
	if not service then
		error(formatError("Service Not Found", `Could not find service "{serviceName}"`))
	end

	return service
end

return Roam
