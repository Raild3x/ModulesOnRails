--!strict
-- Logan Hunt [Raildex], Brandon Wilcox
-- August 16th, 2023
--[=[
	@class BaseObject

	BaseObject provides interface methods for three core features:
	- Object Destruction via adding a :Destroy() method and Destroyed flag property,
	- Task Management across the objects lifetime by providing a janitor internally,
	- and Signal Management by providing interfaces to Register, Get, and Fire signals easily.
	

	Destroy Behavior:
	* When a BaseObject instance is destroyed, it's `Destroyed` property is set to true, and it's `Destroyed` signal is fired.
	* It's metatable is set to a metatable that will error when any of it's methods or metamethods are called.
	
	You should check `Destroyed` before calling any methods on a BaseObject instance if you are not sure if it has been destroyed or not.
]=]

--[[ API
	[CLASS PROPS]
	.ClassName: string
	.SignalBehavior: Enum.SignalBehavior -- Determines the default signal behavior for signals fired from this BaseObject
	._DEBUG: boolean -- Whether or not to print debug messages

	[STATIC METHODS]
	.getObjectFromId(id: number) -> BaseObject?
	.new(tbl: {}?) -> BaseObject
	.isDestroyed(self: BaseObject) -> boolean

	[OBJECT PROPS]
	.Destroyed: boolean?

	[OBJECT METHODS]
	:GetId() -> number
	:IsA(class: any) -> boolean
	:Destroy()

	:BindToInstance(obj: Instance, destroyOnNilParent: boolean?) -> function

	:GetTask(taskId: any) -> Task?
	:AddTask(task: Task, cleanupMethodName: (string | true)?, taskId: any?) -> Task
	:GiveTask(task: Task, cleanupMethodName: (string | true)?, taskId: any?) -> Task -- Alias for AddTask
	:AddPromise(prom: Promise) -> Promise
	:GivePromise(prom: Promise) -> Promise -- Alias for AddPromise
	:RemoveTask(taskId: any, dontClean: boolean?)
	:RemoveTaskNoClean(taskId: any)

	:GetSignal(signalName: string) -> Signal
	:HasSignal(signalName: string) -> boolean
	:FireSignal(signalName: string, ...)
	:RegisterSignal(signalName: string)
	:ConnectSignal(signalName: string, func: (...any) -> ()) -> Connection
	:GetDestroyingSignal() -> Signal
	:GetDestroyedSignal() -> Signal
]]

--// Services //--
local RunService = game:GetService("RunService")

--// Requires //--
local Signal = require(script.Parent.Signal)
local Symbol = require(script.Parent.Symbol)
local Janitor = require(script.Parent.Janitor)
local Promise = require(script.Parent.Promise)

--// Types //--
type Janitor = Janitor.Janitor
type Signal = Signal.ClassicSignal<...any>
type Connection = Signal.Connection
type Promise = typeof(Promise.new())

type genericFn = () -> ()
type Destructable = Instance | { Destroy: genericFn }
type Task = genericFn | thread | Destructable | RBXScriptConnection

--// Constants //--
local KEY_ID = Symbol("Id")
local KEY_JANITOR = Symbol("Janitor")
local KEY_SIGNALS = Symbol("Signals")
local SIGNAL_MARKER = Symbol("SignalMarker")

local DESTROYING_SIGNAL_NAME = "Destroying"
local DESTROYED_SIGNAL_NAME = "Destroyed"

--// Volatiles //--
local GLOBAL_ID = if RunService:IsServer() then 0 else 1
local STORAGE = (setmetatable({}, { __mode = "v" }) :: any) :: {[number]: BaseObject}-- Stores all objects weakly

--// Ethans Funky Stuff //--
-- Create weaktable to store destroyed object stacks
local destroyedObjectStacks = setmetatable({}, { __mode = "k" })

-- Create an warn message for destroyed objects
local function errorDestroyed(self: any, ...)
	warn(`Attempted to perform operation on a destroyed Object!\n{debug.traceback(" Operation Traceback:", 2)}\n Destruction Traceback:\n{destroyedObjectStacks[self]}`)
end

-- Metatable that produces an error when any method is called
local destroyedMetatable = {
	__index = errorDestroyed,
	__newindex = errorDestroyed,
	__call = errorDestroyed,
	__concat = errorDestroyed,
	__unm = errorDestroyed,
	__add = errorDestroyed,
	__mul = errorDestroyed,
	__sub = errorDestroyed,
	__div = errorDestroyed,
	__mod = errorDestroyed,
	__pow = errorDestroyed,
	__eq = errorDestroyed,
	__lt = errorDestroyed,
	__le = errorDestroyed,
	__len = errorDestroyed,
}

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local BaseObject = {}
BaseObject.ClassName = "BaseObject"
BaseObject.SignalBehavior = Enum.SignalBehavior.Immediate
-- BaseObject.AllowSignalsToFireAfterDestroy = false -- Not implemented yet
BaseObject._DEBUG = false
BaseObject.__index = BaseObject
BaseObject.__call = function(t, ...)
	return t.new(...)
end

--[=[
	@type BaseObject BaseObject
	@within BaseObject
]=]

--[=[
	@prop _DEBUG boolean
	@within BaseObject
	@tag static
	@private
	When set to true, enables debug warnings for operations like attempting to destroy an already destroyed object.
]=]

--[=[
	@prop ClassName string
	@within BaseObject
	@readonly
	@tag static
]=]

--[=[
	@prop SignalBehavior Enum.SignalBehavior
	@within BaseObject
	@tag static
	Determines the default signal behavior for signals fired from this BaseObject via `FireSignal`.
]=]

--[=[
	@prop Destroyed boolean?
	@within BaseObject
	@readonly

	Indicates whether or not the object has been destroyed.
	```lua
	local obj = BaseObject.new()
	print(obj.Destroyed) -- nil
	obj:Destroy()
	print(obj.Destroyed) -- true
	```
]=]

--[=[
	@tag static

	Fetches the object with the given ID if it exists.
	@param id number
	@return BaseObject?

	```lua
	local obj = BaseObject.new()

	local id = obj:GetId()

	print(BaseObject.getObjectFromId(id) == obj) -- true
	```
]=]
function BaseObject.getObjectFromId(id: number): BaseObject?
	return STORAGE[id]
end

--[=[
	@tag static
	Checks whether or not the object is destroyed.
	@return boolean

	```lua
	local obj = BaseObject.new()

	print(BaseObject.isDestroyed(obj)) -- false

	obj:Destroy()

	print(BaseObject.isDestroyed(obj)) -- true
	```
]=]
function BaseObject.isDestroyed(self: BaseObject): boolean
	return self.Destroyed == true
end

--[=[
	@tag static

	Constructs a new BaseObject

	@param tbl -- Table to construct the BaseObject with

	@return BaseObject

	```lua
	local obj = BaseObject.new({
		X = 1,
		Y = 2,
	})

	obj.Z = 3

	print(obj.X, obj.Y, obj.Z) -- 1, 2, 3
	```

	```lua
	local SuperClass = BaseObject

	local MyClass = setmetatable({}, SuperClass)
	MyClass.__index = MyClass
	MyClass.ClassName = "MyClass"

	function MyClass.new()
		local self = setmetatable(SuperClass.new(), MyClass)
		-- Custom logic here
		return self
	end

	function MyClass:Destroy() -- Overwrite the BaseObject Destroy method
		SuperClass.Destroy(self) -- If you overwrite the BaseObject Destroy method you need to have this line to call the original.
	end

	function MyClass:Print()
		print("Hello, World!")
	end

	return MyClass
	```
]=]
function BaseObject.new<T>(tbl: {[any]: any}?)
	assert(typeof(tbl) == "table" or tbl == nil, "Argument 1 must be a table or nil")
	local self = setmetatable(tbl or {}, BaseObject)

	self[KEY_SIGNALS] = (nil :: any) :: { [string]: Signal }
	self[KEY_JANITOR] = Janitor.new() :: Janitor

	self[KEY_ID] = GLOBAL_ID
	STORAGE[self[KEY_ID]] = self
	GLOBAL_ID += 2

	-- Leave this as nil until destroyed to avoid bloat
	(self :: any).Destroyed = nil :: boolean?

	return self
end

--------------------------------------------------------------------------------
--// Core //--
--------------------------------------------------------------------------------

--[=[
	Marks the Object as Destroyed, fires the Destroyed Signal, cleans up
	the BaseObject, and sets the metatable to nil/a special locked MT.
	:::caution Overriding
	If you override this method, you need to make sure you call
	`SuperClass.Destroy(self)` to call the superclass methods.
	:::
	```lua
	function MyCustomClass:Destroy()
		SuperClass.Destroy(self) -- calls the superclass method to clean up events, tasks, etc..
	end
	```
]=]
function BaseObject:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.IsDestroyed = true -- kept for backwards compatibility

	-- Add stack traceback for debugging
	destroyedObjectStacks[self] = debug.traceback()

	local ClassName = self.ClassName
	self.Destroy = function()
		if BaseObject._DEBUG then
			warn(`Attempted to destroy an already destroyed object! {ClassName}[{self[KEY_ID]}]`)
		end
	end
	
	-- Fire destroying signal if it exists
	if self:HasSignal(DESTROYING_SIGNAL_NAME) then
		self:GetSignal(DESTROYING_SIGNAL_NAME):Fire()
	end

	-- I added this coroutine check to prevent unexpected yielding during janitor destruction
	local jani = self[KEY_JANITOR] :: any
	local janiThread = coroutine.create(function()
		jani:Destroy()
	end)
	coroutine.resume(janiThread)
	if coroutine.status(janiThread) ~= "dead" then
		warn(`Detected Janitor Destroy yielded for {ClassName}[{self[KEY_ID]}]. This may cause unexpected behavior.`)
	end

	-- Fire destroyed signal, allows deferring if configured
	self:FireSignal(DESTROYED_SIGNAL_NAME)

	-- Destroy any existing signals
	if self[KEY_SIGNALS] then
		for _, signal: Signal in self[KEY_SIGNALS] :: any do
			if typeof(signal) == "table" and signal ~= SIGNAL_MARKER then
				signal:Destroy()
			end
		end
		self[KEY_SIGNALS] = nil
	end

	-- Set metatable to destroyed metatable
	setmetatable(self, destroyedMetatable)

	-- Remove from storage
	STORAGE[self[KEY_ID] :: any] = nil
end

--[=[
	Returns the ID of the BaseObject
	Can be used to fetch the object with BaseObject.getObjectFromId(id)
	@return number
]=]
function BaseObject:GetId(): number
	return self[KEY_ID] :: number
end

--[=[
	Returns true if the given object is of a given class.
	Takes a class name or class object.
	@param classOrClassName {[any]: any} | string -- The class or class name to check against
	@return boolean
]=]
function BaseObject:IsA(classOrClassName: {[any]: any} | string): boolean
	local current = self
	while current do
		current = getmetatable(current)
		if current == classOrClassName :: any or (current and current.ClassName == classOrClassName) then
			return true
		end
	end
	return false
end



--------------------------------------------------------------------------------
--// Task Management //--
--------------------------------------------------------------------------------

--[=[
	Fetches the task with the given ID if it exists.
	@param taskId any
	@return Task?

	```lua
	local obj = BaseObject.new()

	local part = Instance.new("Part")

	obj:AddTask(part, nil, "Test")

	print(obj:GetTask("Test") == part) -- true
	```
]=]
function BaseObject:GetTask(taskId: any): Task?
	return self[KEY_JANITOR]:Get(taskId) :: Task
end

--[=[
	Adds a task to the janitor. If a taskId is provided, it will be used as the
	key for the task in the janitor and can then be fetched later with :GetTask().
	If an ID is provided and there already exists a task with that ID, it will
	clean up the existing task and then replace the index with the new one.
	It will return the task that was added/given.
	@param task Task
	@param taskCleanupMethod (string | true | nil)? -- (if none is given it will try to infer; Passing true tells it to call it as a function)
	@param taskId any?
	@return Task -- The task that was given

	```lua
	local obj = BaseObject.new()

	local task = obj:AddTask(function()
		print("Hello, World!")
	end)

	obj:Destroy() -- Prints "Hello, World!"
	```

	:::caution yielding
	Avoid yielding within added tasks as it may cause unexpected behavior during destruction.
	:::
]=]
function BaseObject:AddTask<T>(task: T, taskCleanupMethod: (string | true | nil)?, taskId: any?): T
	return self[KEY_JANITOR]:Add(task, taskCleanupMethod, taskId)
end

-- Alias for :AddTask(). Provided for compatibility with maid-style APIs.
BaseObject.GiveTask = BaseObject.AddTask -- Alias for those familiar with maids

--[=[
	Adds a promise to the janitor. Similar to :AddTask(). Returns the same Promise
	that was given to it.
	@param prom
	@return Promise

	```lua
	local prom = Promise.delay(math.random(10))

	local obj = BaseObject.new()
	obj:AddPromise(prom)

	task.wait(math.random(10))

	obj:Destroy() -- Cancels the promise if it hasn't resolved yet
	```
]=]
function BaseObject:AddPromise(prom: Promise): Promise
	self[KEY_JANITOR]:AddPromise(prom)
	return prom
end

-- Alias for :AddPromise(). Provided for compatibility with maid-style APIs.
BaseObject.GivePromise = BaseObject.AddPromise

--[=[
	Removes a task from the janitor. Cleans the task as if :DoCleaning was called.
	If dontClean is true, it will not clean up the task, it will just remove
	it from the janitor.
	@param taskId any
	@param dontClean boolean?

	```lua
	local obj = BaseObject.new()

	local task = obj:AddTask(function()
		print("Hello, World!")
	end, nil, "Test")

	obj:RemoveTask("Test") -- Prints "Hello, World!"
	```
]=]
function BaseObject:RemoveTask(taskId: any, dontClean: boolean?)
	if dontClean then
		return self:RemoveTaskNoClean(taskId)
	end
	return self[KEY_JANITOR]:Remove(taskId)
end

--[=[
	Removes a task from the janitor without cleaning it.
	@param taskId any

	```lua
	local obj = BaseObject.new()

	local task = obj:AddTask(function()
		print("Hello, World!")
	end, nil, "Test")

	obj:RemoveTaskNoClean("Test") -- Does NOT print "Hello, World!"
	```
]=]
function BaseObject:RemoveTaskNoClean(taskId: any)
	return self[KEY_JANITOR]:RemoveNoClean(taskId)
end

--------------------------------------------------------------------------------
--// Signal Management //--
--------------------------------------------------------------------------------

--[=[
	Fires the signal with the given name, if it exists.
	
	:::info deferred signals
	If the BaseObject's SignalBehavior is not set to Immediate, signals will be fired deferred.
	:::

	@param signalName string -- The name of the signal to fire
	@param ... any -- Arguments to pass to the signal

	```lua
	local obj = BaseObject.new()
	local SignalName = "Test"

	obj:RegisterSignal(SignalName)

	obj:GetSignal(SignalName):Connect(print)

	obj:FireSignal(SignalName, "Hello, World!") -- Fires the signal with the argument "Hello, World!"
	```
]=]
function BaseObject:FireSignal(signalName: string, ...)
	if self[KEY_SIGNALS] and typeof(self[KEY_SIGNALS][signalName]) == "table" then
		local signal = self[KEY_SIGNALS][signalName] :: Signal
		if self.SignalBehavior :: any == Enum.SignalBehavior.Immediate then
			signal:Fire(...)
		else
			signal:FireDeferred(...)
		end	
	end
end

--[=[
	Marks a signal with the given name as registered. Does not actually
	build a new signal, it sets the index to a SignalMarker to identify
	it as registered so that it can be fetched later.

	This is mainly here to just enforce good patterns with registering
	signals before fetching them.

	@param signalName string -- Name of signal to register
]=]
function BaseObject:RegisterSignal(signalName: string)
	if not self[KEY_SIGNALS] then
		self[KEY_SIGNALS] = {}
	end

	if self[KEY_SIGNALS][signalName] then
		warn(`Signal name '{signalName}' already registered on `, self)
		return
	end

	self[KEY_SIGNALS][signalName] = SIGNAL_MARKER
end

--[=[
	Checks whether or not a signal with the given name is registered.

	```lua
	local obj = BaseObject.new()

	local SignalName = "Test"

	print(obj:HasSignal(SignalName)) -- false

	obj:RegisterSignal(SignalName)

	print(obj:HasSignal(SignalName)) -- true
	```
]=]
function BaseObject:HasSignal(signalName: string): boolean
	return if self[KEY_SIGNALS] then self[KEY_SIGNALS][signalName] ~= nil else false
end

--[=[
	Fetches a signal with the given name. Creates the Signal JIT.
	@param signalName string
	@return Signal
]=]
function BaseObject:GetSignal(signalName: string): Signal
	-- Register signal if it doesn't exist
	if not self[KEY_SIGNALS] or not (self[KEY_SIGNALS] :: any)[signalName] then
		warn(`Signal name '{signalName}' not pre-registered. Please Register before fetching on {self.ClassName}`)
		self:RegisterSignal(signalName)
	end

	-- Get sigtbl after potential RegisterSignal call
	local sigtbl = (self :: any)[KEY_SIGNALS]

	-- Replace SignalMarker with a new Signal
	if sigtbl[signalName] == SIGNAL_MARKER then
		sigtbl[signalName] = Signal.new()
	end

	return sigtbl[signalName] :: Signal
end

--[=[
	Connects a function to a signal with the given name. Creates the signal JIT.
	Shorthand for `:GetSignal(signalName):Connect(func)`.
	@param signalName string -- The name of the signal to connect to
	@param func (...any) -> () -- The function to connect
	@return Connection -- The connection object
]=]
function BaseObject:ConnectSignal(signalName: string, func: (...any) -> ()): Connection
	return self:GetSignal(signalName):Connect(func)
end

--[=[
	Returns a signal that fires when the object is being destroyed. Creates the signal JIT.
	
	The Destroying signal is unique in that it always fires immediately instead of deferred.

	```lua
	local obj = BaseObject.new()

	obj:GetDestroyingSignal():Connect(function()
		print("Object Destroying!")
	end)

	obj:Destroy() -- Prints "Object Destroying!"
	```
]=]
function BaseObject:GetDestroyingSignal(): Signal
	if not self:HasSignal(DESTROYING_SIGNAL_NAME) then
		self:RegisterSignal(DESTROYING_SIGNAL_NAME)
	end
	return self:GetSignal(DESTROYING_SIGNAL_NAME)
end

--[=[
	Returns a signal that fires when the object is destroyed. Creates the signal JIT.

	```lua
	local obj = BaseObject.new()

	obj:GetDestroyedSignal():Connect(function()
		print("Object Destroyed!")
	end)

	obj:Destroy()
	```
]=]
function BaseObject:GetDestroyedSignal(): Signal
	if not self:HasSignal(DESTROYED_SIGNAL_NAME) then
		self:RegisterSignal(DESTROYED_SIGNAL_NAME)
	end
	return self:GetSignal(DESTROYED_SIGNAL_NAME)
end

--------------------------------------------------------------------------------
	--// Methods //--
--------------------------------------------------------------------------------

--[=[
	Binds the object to the given instance. When the object is destroyed, it will
	destroy the instance. When the instance is destroyed, it will destroy the object.
	@param obj Instance
	@param destroyOnNilParent boolean? -- Whether or not to destroy the object when the parent is nil'd
	@return function -- Disconnects the binding

	```lua
	local obj = BaseObject.new()
	local part = Instance.new("Part")
	obj:BindToInstance(part)

	do -- setup prints on destroy
		obj:AddTask(function()
			print("Object Destroyed!")
		end)

		part.Destroying:Connect(function()
			print("Part Destroyed!")
		end)
	end

	local X = if math.random(1,2) == 1 then obj or part
	X:Destroy() -- Prints "Object Destroyed!" and "Part Destroyed!" (Destroying one will destroy the other)
	```
]=]
function BaseObject:BindToInstance(obj: Instance, destroyOnNilParent: boolean?): () -> ()
	-- Validate that obj is an Instance with required signals
	assert(typeof(obj) == "Instance", "Argument 1 must be an Instance")
	
	local connections = {}
	local janitorKeys = {}
	local isCleanedUp = false
	
	local function CleanConnections()
		if isCleanedUp then
			return
		end
		isCleanedUp = true
		
		-- Disconnect raw connections
		for _, conn in ipairs(connections) do
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
		end
		
		-- Remove tasks from janitor
		for _, key in ipairs(janitorKeys) do
			self:RemoveTaskNoClean(key)
		end
	end

	-- Connection 1: When BaseObject is destroyed, destroy the Instance
	table.insert(connections, self:GetDestroyedSignal():Once(function()
		pcall(obj.Destroy, obj)
	end))

	-- Connection 2: When Instance is destroyed, destroy the BaseObject
	local key1 = {}
	table.insert(janitorKeys, key1)
	self:AddTask(obj.Destroying:Once(function()
		if not self.Destroyed and not self.IsDestroyed then
			self:Destroy()
		end
	end), true, key1)

	-- Connection 3: When Instance parent is nil'd, destroy the BaseObject
	if destroyOnNilParent then
		local key2 = {}
		table.insert(janitorKeys, key2)
		self:AddTask(obj.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:Destroy()
			end
		end), true, key2)
	end
	
	return CleanConnections
end


--------------------------------------------------------------------------------
--// Finalization //--
--------------------------------------------------------------------------------

-- Exported Type Def
export type BaseObject = typeof(BaseObject.new())

return BaseObject
