--!strict
-- Logan Hunt [Raildex], Brandon Wilcox
-- August 16th, 2023
--[=[
	@class BaseObject

	BaseObject provides interface methods for three core features:
	- Object Destruction via adding a :Destroy() method and IsDestroyed flag property,
	- Task Management across the objects lifetime by providing a janitor internally,
	- and Signal Management by providing interfaces to Register, Get, and Fire signals easily.
	

	Destroy Behavior:
	* When a BaseObject instance is destroyed, it's `IsDestroyed` property is set to true, and it's `Destroyed` signal is fired.
	* It's metatable is set to a metatable that will error when any of it's methods or metamethods are called.
	
	You should check `IsDestroyed` before calling any methods on a BaseObject instance if you are not sure if it has been destroyed or not.
]=]

--[[ API
	[CLASS PROPS]
	.ClassName: string
	._DEBUG: boolean -- Whether or not to print debug messages

	[STATIC METHODS]
	.getObjectFromId(id: number) -> BaseObject?
	.new(tbl: {}?) -> BaseObject
	.isDestroyed(self: BaseObject) -> boolean

	[OBJECT PROPS]
	.IsDestroyed: boolean?

	[OBJECT METHODS]
	:GetId() -> number
	:IsA(class: any) -> boolean
	:Destroy()

	:BindToInstance(obj: Instance, destroyOnParentNil: boolean?) -> function

	:GetTask(taskId: any) -> Task?
	:AddTask(task: Task, cleanupMethodName: (string | true)?, taskId: any?) -> Task
	:AddPromise(prom: Promise) -> Promise
	:RemoveTask(taskId: any, dontClean: boolean?)
	:RemoveTaskNoClean(taskId: any)

	:GetSignal(signalName: string) -> Signal
	:HasSignal(signalName: string) -> boolean
	:FireSignal(signalName: string, ...)
	:RegisterSignal(signalName: string)
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
type Signal = Signal.ScriptSignal<any>
type Promise = typeof(Promise.new())

type genericFn = () -> ()
type Destructable = Instance | { Destroy: genericFn }
type Task = genericFn | thread | Destructable | RBXScriptConnection

--// Constants //--
local KEY_ID = Symbol("Id")
local KEY_JANITOR = Symbol("Janitor")
local KEY_SIGNALS = Symbol("Signals")
local SIGNAL_MARKER = Symbol("SignalMarker")

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
	@prop ClassName string
	@within BaseObject
	@readonly
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
	return self.IsDestroyed == true
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
	(self :: any).IsDestroyed = nil :: boolean?

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
	```lua
	function MyCustomClass:Destroy()
		SuperClass.Destroy(self) -- calls the superclass method to clean up events, tasks, etc..
	end
	```
]=]
function BaseObject:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	local ClassName = self.ClassName
	self.Destroy = function()
		if BaseObject._DEBUG then
			warn(`Attempted to destroy an already destroyed object! {ClassName}[{self[KEY_ID]}]`)
		end
	end
	
	-- Fire signal if it exists
	if self:HasSignal(DESTROYED_SIGNAL_NAME) then
		self:GetSignal(DESTROYED_SIGNAL_NAME):Fire()
	end

	-- Mark as destroyed and clean janitor
	(self[KEY_JANITOR] :: any):Destroy()

	-- Set metatable to destroyed metatable
	setmetatable(self, destroyedMetatable)

	-- Add stack
	destroyedObjectStacks[self] = debug.traceback()
end

--[=[
	Returns the ID of the BaseObject
	Can be used to fetch the object with BaseObject.getObjectFromId(id)
]=]
function BaseObject:GetId(): number
	return self[KEY_ID] :: number
end

--[=[
	Returns true if the given object is of a given class.
	Takes a class name or class object.
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
]=]
function BaseObject:AddTask<T>(task: T, taskCleanupMethod: (string | true | nil)?, taskId: any?): T
	return self[KEY_JANITOR]:Add(task, taskCleanupMethod, taskId)
end
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
	Equivalent to calling `:GetSignal(signalName):Fire(...)` except this does not require
	the signal to exist first.
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
		signal:Fire(...)
	end
end

--[=[
	Marks a signal with the given name as registered. Does not actually
	build a new signal, it sets the index to a SignalMarker to identify
	it as registered so that it can be fetched later.
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
	local sigtbl = (self :: any)[KEY_SIGNALS]

	-- Register signal if it doesn't exist
	if not sigtbl or not sigtbl[signalName] then
		warn(`Signal name '{signalName}' not pre-registered. Please Register before fetching on {self.ClassName}`)
		self:RegisterSignal(signalName)
	end

	-- Replace SignalMarker with a new Signal
	if sigtbl[signalName] == SIGNAL_MARKER then
		sigtbl[signalName] = self:AddTask(Signal.new())
	end

	return sigtbl[signalName] :: Signal
end

--[=[
	Returns a signal that fires when the object is destroyed. Creates the signal JIT.
	Kept for backwards compatibility.

	```lua
	local obj = BaseObject.new()

	obj:GetDestroyedSignal():Connect(function()
		print("Object Destroyed!")
	end)

	obj:Destroy() -- Prints "Object Destroyed!"
	```
]=]
function BaseObject:GetDestroyedSignal(): Signal
	if not self:HasSignal(DESTROYED_SIGNAL_NAME) then
		self:RegisterSignal(DESTROYED_SIGNAL_NAME)
		-- if not self.Destroyed then
		-- 	self.Destroyed = self:GetSignal(DESTROYED_SIGNAL_NAME)
		-- end
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
	local connections = {}
	local function CleanConnections()
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
	end

	table.insert(connections, self:GetDestroyedSignal():Once(function()
		pcall(obj.Destroy, obj)
	end))

	table.insert(connections, self:AddTask(obj.Destroying:Once(function()
		if not self.IsDestroyed then
			self:Destroy()
		end
	end)))

	if destroyOnNilParent then
		table.insert(connections, self:AddTask(obj.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:Destroy()
			end
		end)))
	end
	
	return CleanConnections
end


--------------------------------------------------------------------------------
--// Finalization //--
--------------------------------------------------------------------------------

-- Exported Type Def
export type BaseObject = typeof(BaseObject.new())

return BaseObject
