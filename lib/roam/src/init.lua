--!strict
-- Logan Hunt (Raildex)
-- September 12, 2022
--[=[
	@class Roam

	Roam follows a design pattern similar to Knit, but is more lightweight (Shoutout
	to Stephen Leitnick [Sleitnick]). It removes all networking and replication
	functionality, and instead focuses on providing a simple method to easily
	initialize Services given to it and provide global accessors.

	Roam gathers a collection of specified services and initializes 'syncronously'.
	Once all services have been fully initialized, it then starts them 'asyncronously' by
	spawning their 'RoamStart' method in a new thread.

	Roam enforces contracts to ensure that only the Services that you intend are
	initialized. By following the contracts of service construction/registration,
	Roam is able to ensure that nothing that isnt intended to be initialized doesnt
	cause any issues during the loading or start process.

	[CONTRACTS]
	- Services must be created/registered before Roam is started.
	- Services must be created/registered with a unique name.
	- Services with `RoamInit` and `RoamStart` methods will have those methods
	  called when Roam is started at the appropriate time. (Names are configurable)
	- All Services are guaranteed safe to access in RoamStart.
	- Only StaticMethods are safe to call prior to RoamStart.

	[EXAMPLE USAGE]
	```lua -- init.Server.lua
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

	-- Accessing a potential Service
	Roam.getService("MyService"):DoSomething()
	```
]=]

--[[
	[API]
	[PROPERTIES]
	.ClassName: "Roam"
	.Services: { [string]: Service }
	.Debug: boolean

	[FUNCTIONS]
	.createService(serviceDef: ServiceConfig): Service
	.registerService(service: Service, serviceConfig: (string | ServiceConfig)?): Service

	.getService(serviceName: string): Service
	.requireModules(
		parent: Instance,
		config: {
			DeepSearch: boolean?,
			RequirePredicate: ((obj: ModuleScript) -> boolean)?,
			IgnoreDescendantsPredicate: ((obj: Instance) -> boolean)?
		}?
	): { Service }

	.start(): Promise
	.onStart(): Promise
	.isReady(): boolean
]]

local RunService = game:GetService("RunService")

local Packages = script.Parent
local Promise = require(Packages.Promise) ---@module _Promise
local Symbol = require(Packages.Symbol) ---@module _Symbol

local KEY_CONFIG = Symbol("RoamServiceConfig")

local Roam_START_METHOD_NAME = "RoamStart"
local Roam_INIT_METHOD_NAME = "RoamInit"

local RunContext = RunService:IsServer() and "SERVER" or "CLIENT"

--// Types //--
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

	local MyService = Roam.createService {
		Name = "MyService",
		RequiredServices = {myOtherService},
	}
	```
	:::tip Automatic Service Dependency Resolution (RequiredServices)
	If you require services to a `global` variable then ROAM will automatically add the service to the RequiredServices table.
	This will ***NOT*** work if it is required to a `local` variable. If it is localized then you must manually add it to the RequiredServices table
	if you want it marked as a dependency.
	```lua
	myOtherService = require(ReplicatedStorage.MyOtherService) -- services required to global variables are automatically added to RequiredServices

	local MyService = Roam.createService { Name = "MyService" }
	```
	:::

	:::caution Deffering RequiredServices
	Do NOT add services to the RequiredServices after you have created or registered the service. This will cause undefined behavior.
	:::
]=]
export type ServiceConfig = {
	Name: string, -- Name of the Service. Must be unique. Used when accessing via .getService
	RequiredServices: {Service}?, -- The Services that this Service depends on. Roam will ensure that these Services are initialized before this Service.
	StartMethodName: string?, -- Overrides default StartMethodName of "RoamStart"
	InitMethodName: string?, -- Overrides default InitMethodName of "RoamInit"
	[any]: any,
}

type Promise = typeof(Promise.new())

--------------------------------------------------------------------------------
--// Volatiles //--
--------------------------------------------------------------------------------

local services: { [string]: Service } = {}

local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

-- Checks to see if an Instance's Name ends in `Service`
local function ServiceNameMatch(obj: Instance)
	return obj.Name:match("Service$") ~= nil
end

-- Reconciles a primary table with a secondary table
local function Reconcile(primary, secondary)
	primary = primary or {}
	secondary = secondary or {}
	for i in pairs(secondary) do
		primary[i] = primary[i] or secondary[i]
	end
	return primary
end

-- checks if a service exists with the given name
local function DoesServiceExist(serviceName: string): boolean
	local service: Service? = services[serviceName]
	return service ~= nil
end

-- requires a given modulescript and throws a safe error if it yields
local function EnsureUnyieldingRequire(module: ModuleScript)
	local moduleContent
	task.spawn(function()
		local current
		task.spawn(function()
			current = coroutine.running()
			local success, msg = pcall(function()
				moduleContent = require(module) :: any
			end)
			assert(success, `Failed to load module: {module.Name}\n{msg}`)
		end)
		assert(coroutine.status(current) == "dead", "Roam Require Yielded: ".. module:GetFullName())
	end)
	return moduleContent
end

--------------------------------------------------------------------------------
--// Roam //--
--------------------------------------------------------------------------------

local Roam = {}
Roam.ClassName = "Roam"
Roam.Services = services -- A table of Services. Only properly accessible after Roam has been started.
Roam.ServiceNameMatch = ServiceNameMatch
Roam.Debug = false -- Whether or not to print debug messages
Roam.DEFAULT_SRC_NAME = "src"

Roam.Bootstrappers = { -- Generic Bootstrappers for Roam / Orion
	Server = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ServerBootstrapper")) :: (script: Script) -> ();
	Client = require(script:FindFirstChild("Bootstrappers"):FindFirstChild("ClientBootstrapper")) :: (script: Script) -> ();
}

--[=[
	@within Roam
	@prop ClassName "Roam"
	The ClassName of the Roam module.
]=]

--[=[
	@within Roam
	@prop Debug boolean
	Whether or not to print debug messages. Default is false.
]=]

--[=[
	@within Roam
	@prop Bootstrappers {Server: (script: Script) -> (), Client: (script: Script) -> ()}
	A table of generic bootstrappers for Roam / Orion.
]=]


--[=[
	Creates a Service/Table with Roam to be Initialized and Started when Roam starts.
	Cannot be called after Roam has been started. This is the advised method of creating
	services over registering them.

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
	assert(not started, "Cannot create Services after Roam has been started")
	assert(type(serviceDef) == "table", `Service must be a table; got {type(serviceDef)}`)

	local Name = serviceDef.Name
	assert(type(Name) == "string", `Service.Name must be a string; got {type(Name)}`)
	assert(#Name > 0, "Service.Name must be a non-empty string")
	assert(not DoesServiceExist(Name), `Service "{Name}" already exists`)

	local service: Service = serviceDef
	service[KEY_CONFIG] = table.freeze({
		Name = Name,
		StartMethodName = serviceDef.StartMethodName,
		InitMethodName = serviceDef.InitMethodName,
		ENV = getfenv(2),
	})

	-- Register Service to Roam
	services[Name] = service

	return service
end

--[=[
	Registers a Service/Table with Roam to be Initialized and Started when Roam starts.
	Cannot be called after Roam has been started. This method was added to allow for easy
	backporting of existing services to Roam.

	```lua -- MyRegisteredService.lua
	local MyRegisteredService = {}

	function MyRegisteredService:Start()
		print("MyRegisteredService started!")
	end

	function MyRegisteredService:Init()
		print("MyRegisteredService initialized!")
	end

	local Roam = require(ReplicatedStorage.Roam)
	Roam.registerService(MyRegisteredService, {
		Name = "MyRegisteredService";
		StartMethodName = "Start"; -- Overrides default StartMethodName of "RoamStart" [Optional]
		InitMethodName = "Init"; -- Overrides default InitMethodName of "RoamInit" [Optional]
	})

	return MyRegisteredService
	```
]=]
function Roam.registerService(service: Service, serviceConfig: (ServiceConfig | string)?): Service
	assert(not started, "Cannot register Services after Roam has been started")
	assert(type(service) == "table", `Service must be a table; got {type(service)}`)

	if typeof(serviceConfig) == "string" then
		serviceConfig = { Name = serviceConfig }
	elseif not serviceConfig then
		serviceConfig = {} :: any
	end

	assert(typeof(serviceConfig) == "table", `ServiceConfig must be a table; got {typeof(serviceConfig)}`)
	serviceConfig.ENV = getfenv(2)

	local Name = serviceConfig.Name or service.Name
	if not Name then
		Name = serviceConfig.ENV.script.Name
		warn(`No Service name was given; this is not recommended. Roam will attempt to continue by attempting to infer the ServiceName. [Inferred Service Name: "{Name}"]`)
	end

	assert(
		not serviceConfig or type(serviceConfig) == "table",
		`ServiceConfig must be a table; got {type(serviceConfig)}`
	)
	assert(type(Name) == "string", `Service.Name must be a string; got {type(Name)}`)
	assert(#Name > 0, "Service.Name must be a non-empty string")
	assert(not DoesServiceExist(Name), `Service "{Name}" already exists`)

	service[KEY_CONFIG] = table.freeze(Reconcile(serviceConfig :: any, {
		Name = Name,
	}))
	services[Name] = service

	return service
end

--[=[
	Requires all the modules that are children of the given parent. This is an easy
	way to quickly load all services that might be in a folder. Takes an optional predicate
	function to filter which modules are loaded. Services collected this way must not yield.
	- `DeepSearch` -> whether it checks descendants or just children
	- `RequirePredicate` -> a predicate function that determines whether a module should be required
	- `IgnoreDescendantsPredicate` -> A Predicate for whether the Descendants of the Module should be Searched (Only matters if DeepSearch is true)

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
		RequirePredicate: ((obj: ModuleScript) -> boolean)?,
		IgnoreDescendantsPredicate: ((obj: Instance) -> boolean)?,
	}?
): { Service }
	if typeof(parents) == "Instance" then
		parents = { parents }
	end

	config = config or {}
	assert(typeof(config) == "table", `config must be a table; got {typeof(config)}`)
	local deepSearch = config.DeepSearch or false
	local predicate = config.RequirePredicate
	local ignoreDescendantsPredicate = config.IgnoreDescendantsPredicate

	local addedServices = {}
	local function SearchInstance(obj: Instance | {Instance})
		if typeof(obj) == "table" then
			for _, v in ipairs(obj) do
				SearchInstance(v)
			end
			return
		end

		assert(typeof(obj) == "Instance", "Expected Instance or table of Instances. Got:"..tostring(obj))
		if obj:IsA("ModuleScript") and (not predicate or predicate(obj)) then
			local service = EnsureUnyieldingRequire(obj)
			if table.find(addedServices, service) then
				warn("Already added service '" .. service[KEY_CONFIG].Name .. "' | " .. obj:GetFullName())
				return
			end

			table.insert(addedServices, service)
		end

		if deepSearch and (not ignoreDescendantsPredicate or not ignoreDescendantsPredicate(obj)) then
			SearchInstance(obj:GetChildren())
		end
	end
	
	assert(typeof(parents) == "table", "Parents must be an Instance or table of Instances")
	for _, parent in ipairs(parents) do
		SearchInstance(parent:GetChildren())
	end

	return addedServices
end

--[=[
	Fetches the name of a registered Service.
]=]
function Roam.getNameFromService(service: Service): string
	return service[KEY_CONFIG].Name
end

--[=[
	Fetches a registered Service by name.
	Cannot be called until Roam has been started.
]=]
function Roam.getService(serviceName: string): Service
	assert(started, "Cannot call GetService until Knit has been started")
	assert(type(serviceName) == "string", `ServiceName must be a string; got {type(serviceName)}`)
	return assert(services[serviceName], `Could not find service "{serviceName}"`) :: Service
end

--[=[
	@param postInitPreStart (() -> (Promise?))?
	@return Promise

	Starts Roam. Should only be called once.
	Optional argument `postInitPreStart` is a function that is called
	after all services have been initialized, but before they are started.

	:::caution
	Be sure that all services have been created _before_
	calling `Start`. Services cannot be added later.
	:::

	```lua
	Roam.start()
	:andThenCall(print, "Roam started!")
	:catch(warn)
	```
]=]
function Roam.start(postInitPreStart: (() -> Promise?)?): Promise
	if started then
		return Promise.reject("Roam already started")
	end

	assert(
		not postInitPreStart or type(postInitPreStart) == "function",
		`postInitPreStart must be a function or nil; got {type(postInitPreStart)}`
	)

	started = true
	--Roam.Started = started

	local topologicallySortedServices: {Service}
	do -- fetch topologically sorted services
		local function sortUtil(service, adjacencyList, visited, stack)
			visited[service] = true
			for _, neighbor in pairs(adjacencyList[service] or {}) do
				if not visited[neighbor] then
					sortUtil(neighbor, adjacencyList, visited, stack)
				end
			end
			table.insert(stack, service)
		end

		local function topologicalSort(adjacencyList)
			local stack, visited = {}, {}
			for service in pairs(adjacencyList) do
				if not visited[service] then
					sortUtil(service, adjacencyList, visited, stack)
				end
			end
			return stack
		end

		-- Generate Adjacency List of Required Services
		local adjacencyList = {}
		for _, service in pairs(services) do
			adjacencyList[service] = service[KEY_CONFIG].RequiredServices or {}
			for _, envProp in pairs(service[KEY_CONFIG].ENV) do
				if typeof(envProp) == "table" and envProp[KEY_CONFIG] then
					if not table.find(adjacencyList[service], envProp) then
						table.insert(adjacencyList[service], envProp)
					end
				end
			end
		end

		topologicallySortedServices = topologicalSort(adjacencyList)
	end


	return Promise.new(function(resolve)
		table.freeze(services)

		-- Init:
		local totalInitTime = 0
		local promisesInitServices = {}
		for _, service in topologicallySortedServices do
			local ServiceConfig = service[KEY_CONFIG]
			local InitMethodName = ServiceConfig.InitMethodName or Roam_INIT_METHOD_NAME
			if type(service[InitMethodName]) == "function" then
				table.insert(
					promisesInitServices,
					Promise.new(function(r)
						if Roam.Debug then
							print(`[{RunContext}] Initializing {ServiceConfig.Name}`)
						end
						local t = os.clock()
						debug.setmemorycategory(ServiceConfig.Name)
						service[InitMethodName](service)
						service[InitMethodName] = function()
							error(`{ServiceConfig.Name} | Cannot call Init method after service has been initialized`)
						end
						t = os.clock() - t
						totalInitTime += t
						if Roam.Debug then
							print(`[{RunContext}] Initialized {ServiceConfig.Name} in {t} seconds.`)
						end
						r()
					end)
				)
			end
		end

		Roam.Services = services

		resolve(Promise.all(promisesInitServices):tap(function()
			if Roam.Debug then
				print(`[{RunContext}] ROAM Initialized all services in {totalInitTime} seconds.`)
			end
		end))
	end)
	:andThen(function()
		if postInitPreStart then
			return postInitPreStart() :: Promise?
		end
		return nil
	end)
	:andThen(function()
		-- Start:
		for _, service in topologicallySortedServices do
			local ServiceConfig = service[KEY_CONFIG]
			local StartMethodName = ServiceConfig.StartMethodName or Roam_START_METHOD_NAME
			if type(service[StartMethodName]) == "function" then
				task.spawn(function()
					if Roam.Debug then
						print(`[{RunContext}] Starting {ServiceConfig.Name}`)
					end
					debug.setmemorycategory(ServiceConfig.Name)
					service[StartMethodName](service)
					service[StartMethodName] = function()
						error(`{ServiceConfig.Name} | Cannot call Start method after service has been initialized`)
					end
				end)
			end
		end

		startedComplete = true
		--Roam.Ready = startedComplete
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
function Roam.onStart()
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

return Roam
