--!strict
-- Logan Hunt (Raildex)
-- September 12, 2022
-- DOCUMENTATION LINK: https://raild3x.github.io/ModulesOnRails/api/Roam
--[=[
	@class Roam

	Roam is a systems bootstrapping tool for Roblox luau projects, designed to make it easy to
	initialize and start services in a topologically sorted manner without the need to
	manually order and start services.
	
	Roam follows a design pattern similar to [Knit](https://sleitnick.github.io/Knit/), but is more lightweight. It removes all networking and replication
	functionality, and instead focuses on providing a simple methodology to easily
	initialize Services given to it.

	Roam gathers a collection of specified services and initializes 'syncronously'.
	Once all services have been fully initialized, it then starts them 'asyncronously' by
	spawning their 'RoamStart' method in a new thread.

	Roam is RunContext agnostic, meaning it can be used on both the server and client in the same manner.
	It makes no distinction between the two, and instead focuses on providing a simple
	interface for initializing and starting services. This means you could create a service and register it on 
	both the server and client, and it will be initialized and started on both ends. 

	**[CONTRACTS]**
	- Services must be created/registered before Roam is started.
	- Services must be created/registered with a unique name.
	- Services with `RoamInit` and `RoamStart` methods will have those methods
	  called when Roam is started at the appropriate time. (Names are configurable)
	- `RequiredServices` boot in proper topological order if specified in the ServiceConfig.
	- Roam functions the same regardless of RunContext (Server/Client).

	**[EXAMPLE STARTUP]**
	```lua -- ServerBootstrapper.Server.lua
	local Roam = require(ReplicatedStorage.Roam)

	-- Just iterates through all the children of the given parents
	-- and requires any module scripts that match the given predicate
	Roam.requireModules({
		ReplicatedStorage.Shared;
		ServerScriptService.Server;
	})

	-- Start Roam
	Roam.start()
	:andThenCall(print, "Roam started!")
	:catch(warn)
	```

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

	:::caution Deffering RequiredServices
	Do NOT add services to the RequiredServices after you have created or registered the service. This will cause undefined behavior.
	:::
]=]
export type ServiceConfig = {
	Name: string, -- Name of the Service. Must be unique. Used when accessing via .getService
	RequiredServices: { Service }?, -- The Services that this Service depends on. Roam will ensure that these Services are initialized before this Service.
	StartMethodName: string?, -- Overrides default StartMethodName of "RoamStart"
	InitMethodName: string?, -- Overrides default InitMethodName of "RoamInit"
	[any]: any,
}

type Promise = typeof(Promise.new())

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
local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

--------------------------------------------------------------------------------
--// Utility Functions //--
--------------------------------------------------------------------------------

local function serviceNameMatch(obj: Instance): boolean
	return obj.Name:match("Service$") ~= nil
end

local function reconcile<T>(primary: T?, secondary: T): T
	primary = primary or {} :: any
	secondary = secondary or {} :: any
	for key, value in pairs(secondary :: any) do
		(primary :: any)[key] = (primary :: any)[key] or value
	end
	return primary :: T
end

local function serviceExists(service: string | table): boolean
	if type(service) == "string" then
		return services[service] ~= nil
	elseif type(service) == "table" then
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

local rejectedInitializations = {}
local function createServiceInitPromise(service: Service, config: ServiceConfig): Promise?
	local initMethodName = config.InitMethodName or DEFAULT_INIT_METHOD
	local initMethod = service[initMethodName]

	if type(initMethod) ~= "function" then
		return nil
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

		local success = false
		local initThread = task.spawn(function()
			debug.setmemorycategory(config.Name)
			initFunction(service)
			success = true
		end)

		while coroutine.status(initThread) ~= "dead" do
			task.wait()
		end

		if not success then
			table.insert(rejectedInitializations, "\n - " .. config.Name)
			reject(`Failed to initialize {config.Name}`)
			return
		end

		local elapsed = os.clock() - startTime
		if Roam.Debug then
			print(`[{RUN_CONTEXT}] Initialized {config.Name} in {string.format("%.3f", elapsed)}s`)
		end

		resolve(elapsed)
	end):timeout(INIT_TIMEOUT_SECONDS, `Service {config.Name} took too long to initialize`)
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

		debug.setmemorycategory(config.Name)
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
	@private
	@within Roam
	@tag ReadOnly
	@prop ClassName "Roam"
	The ClassName of the Roam module.
]=]
Roam.ClassName = "Roam"

--[=[
	@within Roam
	@prop Services {[string]: Service}
	A table of Services. Only properly accessible after Roam has been started.
]=]
Roam.Services = services -- A table of Services. Only properly accessible after Roam has been started.

Roam.ServiceNameMatch = serviceNameMatch

--[=[
	@within Roam
	@prop Debug boolean
	Whether or not to print debug messages. Default is false.
]=]
Roam.Debug = false -- Whether or not to print debug messages

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
Roam.Bootstrappers = { -- Generic Bootstrappers for Roam / Orion
	Server = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ServerBootstrapper")) :: (script: Script, config: { [string]: any }?) -> Promise,
	Client = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ClientBootstrapper")) :: (script: Script, config: { [string]: any }?) -> Promise,
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
	local reconciledConfig = table.freeze(reconcile(config, { Name = config.Name }))

	service[KEY_CONFIG] = reconciledConfig
	services[config.Name] = service

	return service
end

--[=[
	@param postInitPreStart (() -> (Promise?))?
	@return Promise

	Starts Roam. Should only be called once. Calling multiple times will result in a promise rejection.
	
	Optional argument `postInitPreStart` is a function that is called
	after all services have been initialized, but before they are started.

	```lua
	Roam.start()
	:andThenCall(print, "Roam started!")
	:catch(warn)
	```

	:::caution
	Be sure that all services have been created _before_
	calling `Start`. Services cannot be added later.
	:::

	:::tip Bootstrapping
	You can use the [Roam.Bootstrappers](Roam#Bootstrappers) table/methods to quickly bootstrap Roam in your project.
	This is reccomended as it will provide a consistent starting point for your projects.
	:::
]=]
function Roam.start(postInitPreStart: (() -> Promise?)?): Promise
	if started then
		return Promise.reject("Roam already started")
	end

	if postInitPreStart and type(postInitPreStart) ~= "function" then
		error(
			formatError("Invalid Parameter", `postInitPreStart must be a function or nil, got {type(postInitPreStart)}`)
		)
	end

	started = true

	-- Validate all required services are registered
	local missingServices = validateRequiredServices()
	if #missingServices > 0 then
		error(formatError("Missing Dependencies", table.concat(missingServices, "; ")))
	end

	local sortedServices = getSortedServices()

	return Promise.new(function(resolve)
		table.freeze(services)

		-- Initialize services
		local initPromises = {}
		local totalInitTime = 0

		for _, service in ipairs(sortedServices) do
			local config = service[KEY_CONFIG]
			local initPromise = createServiceInitPromise(service, config)

			if initPromise then
				table.insert(
					initPromises,
					initPromise:andThen(function(elapsed)
						totalInitTime += elapsed
					end)
				)
			end
		end

		Roam.Services = services

		local initializationPromise = Promise.all(initPromises)
			:andThen(function()
				if Roam.Debug then
					print(`[{RUN_CONTEXT}] All services initialized in {string.format("%.3f", totalInitTime)}s`)
				end
			end)
			:catch(function(error)
				return Promise.reject(
					formatError(
						"Initialization Failed for the following services",
						table.concat(rejectedInitializations)
					)
				)
			end)

		resolve(initializationPromise)
	end)
		:andThen(function()
			-- Call post-init hook if provided
			if postInitPreStart then
				return postInitPreStart()
			end
			return nil
		end)
		:andThen(function()
			-- Start services
			for _, service in ipairs(sortedServices) do
				local config = service[KEY_CONFIG]
				startService(service, config)
			end

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
	that called `Start`.
	```lua
	Roam.onStart():andThen(function()
		local MyService = Roam.Services.MyService
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
	- `RequirePredicate` -> a predicate function that determines whether a module should be required
	- `IgnoreDescendantsPredicate` -> A Predicate for whether the Descendants of the Module should be Searched (Only matters if DeepSearch is true)
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

--[=[
	@within Roam
	@private
	Fetches the name of a registered Service.
]=]
function Roam.getNameFromService(service: Service): string
	local config = service[KEY_CONFIG]
	if not config then
		error(formatError("Invalid Service", "Service is not registered with Roam"))
	end
	return config.Name
end

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
	warn("[Roam] getService is deprecated, use Roam.Services[serviceName] instead")

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
