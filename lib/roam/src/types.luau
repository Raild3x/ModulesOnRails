--!strict
-- Logan Hunt (Raildex)
-- January 20, 2026
-- Type definitions for Roam

type table = { [any]: any }

--[=[
	@within Roam
	@type Service table
	A service is a table that can be registered with Roam.
]=]
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
	- `STARTED` - Service is actively running and has completed its startup routine
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
	GlobalPreInit: (() -> any)?,
	PreInit: ((service: Service) -> any)?,
	PostInit: ((service: Service) -> any)?,
	GlobalPostInit: (() -> any)?,
	GlobalPreStart: (() -> ())?,
	PreStart: ((service: Service) -> ())?,
	PostStart: ((service: Service) -> ())?,
	GlobalPostStart: (() -> ())?,
}

return {}
