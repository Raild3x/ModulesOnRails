--!strict
--!native
--[=[
    @class ObjectCache

    This module is a fork of https://github.com/Pyseph/ObjectCache

    ObjectCaches provide an efficient way to manage and reuse BaseParts and Models in Roblox.

    ```lua
    local ObjectCache = require(script.ObjectCache)
    type ObjectCache<T> = ObjectCache.ObjectCache<T>

    local myPartTemplate = Instance.new("Part")
    myPartTemplate.Size = Vector3.new(1, 1, 1)
    myPartTemplate.Anchored = true -- make sure your part is anchored!

    local cache: ObjectCache<Part> = ObjectCache.new({
        Name = "MyPartsCache",
        Template = myPartTemplate,
    })

    local myPart = cache:Get()

    myPart.CFrame = CFrame.new(0, 10, 0)

    task.wait(1)

    cache:Return(myPart)
    ```
]=]

--// Imports //--
local T = require(script.Parent.T)

--// Types //--
type Template = (BasePart | Model) | () -> (BasePart | Model)

export type ObjectCache<T> = {
    Get: (self: ObjectCache<T>) -> T,
    Return: (self: ObjectCache<T>, obj: T) -> (),
    IsInUse: (self: ObjectCache<T>, Object: T) -> boolean,
    ExpandCache: (self: ObjectCache<T>, Amount: number?) -> (),
    SetExpandAmount: (self: ObjectCache<T>, Amount: number) -> (),
    Update: (self: ObjectCache<T>) -> (),
    Destroy: (self: ObjectCache<T>) -> (),
    GetCacheParent: (self: ObjectCache<T>) -> Instance,
    ConnectOnReturn: (self: ObjectCache<T>, (obj: T) -> ()) -> (() -> ()),
}

--// Constants //--
local FAR_AWAY_CFRAME = CFrame.new(0, 2^24, 0)
local EXPAND_BY_AMOUNT = 50

--// Variables //--
local MovingParts = table.create(10_000)
local MovingCFrames = table.create(10_000)

local ScheduledUpdate = false
local function UpdateMovement()
	while true do
		workspace:BulkMoveTo(MovingParts, MovingCFrames, Enum.BulkMoveMode.FireCFrameChanged)

		table.clear(MovingParts)
		table.clear(MovingCFrames)

		ScheduledUpdate = false
		coroutine.yield()
	end
end
local UpdateMovementThread = coroutine.create(UpdateMovement)



--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

local CACHE_OBJECT_REF_NAME = "CacheObject"
local WELDS_FOLDER_NAME = "ObjectCacheWelds"

-- Sets up a model for cache movement by welding all of its descendant BaseParts to its PrimaryPart.
local function SetupModelForCacheMovement(model: Model)
    local PrimaryPart = model.PrimaryPart :: BasePart

    assert(not PrimaryPart:FindFirstChild(CACHE_OBJECT_REF_NAME), "Model already setup for cache movement!")
    local CachedParentRef = Instance.new("ObjectValue") -- stores a reference to the model this object is the PrimaryPart of
    CachedParentRef.Name = CACHE_OBJECT_REF_NAME
    CachedParentRef.Value = model
    CachedParentRef.Parent = PrimaryPart

    if model:FindFirstChild(WELDS_FOLDER_NAME) then
        warn(model, "Already setup for cache movement!")
        return
    end

    local WeldFolder = Instance.new("Folder")
    WeldFolder.Name = WELDS_FOLDER_NAME

    for _, obj in model:GetDescendants() do
        if obj:IsA("BasePart") then
            local Weld = Instance.new("WeldConstraint")
            Weld.Part0 = obj
            Weld.Part1 = PrimaryPart
            Weld.Parent = WeldFolder
        end
    end

    WeldFolder.Parent = model
end

-- Checks if a model is setup for cache movement.
function IsModelSetupForCacheMovement(model: Model)
    return model:FindFirstChild(WELDS_FOLDER_NAME) ~= nil
end

-- Gets the root part of a model or part.
local function GetRoot(obj: BasePart | Model): BasePart
    return obj:IsA("Model") and obj.PrimaryPart :: BasePart or obj :: BasePart
end


--Dupes a part from the template.
local function MakeFromTemplate(template: Template): (BasePart | Model, BasePart)
	local obj: BasePart | Model

	if typeof(template) == "function" then
		obj = template()
        if obj:IsA("Model") and not IsModelSetupForCacheMovement(obj) then
            SetupModelForCacheMovement(obj)
        end
	else
		obj = template:Clone()
	end

	-- obj:GetPropertyChangedSignal("Parent"):Connect(function()
	-- 	if obj.Parent ~= cache.CurrentCacheParent then 
	-- 		warn(`PartCache: {obj.Name} was moved out of the cache folder! This may result in unexpected behavior. New Parent:`, obj.Parent)
	-- 	end
	-- end)

	local root: BasePart = GetRoot(obj :: any)
	return obj, root
end

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local ObjectCache = {}
ObjectCache.ClassName = "ObjectCache"
ObjectCache.__index = ObjectCache

--[=[
    @private
]=]
function ObjectCache:_GetNew(Amount: number, Warn: boolean)
	if Warn then
		warn(`ObjectCache: Cache retrieval exceeded preallocated amount! expanding by {Amount}...`)
	end

    assert(T.numberPositive(Amount))

	local InitialLength = #self._FreeObjects
	local CacheHolder = self.CacheHolder

	local Template = self._Template

	local TargetParts = table.create(Amount)
	local TargetCFrames = table.create(Amount)
	local AddedObjects = table.create(Amount)

	for i = 1, Amount do
		local Object, ObjectRoot = MakeFromTemplate(Template)

		self._FreeObjects[InitialLength + i] = Object

		TargetParts[i] = ObjectRoot
		TargetCFrames[i] = FAR_AWAY_CFRAME
		AddedObjects[i] = Object
	end

	workspace:BulkMoveTo(TargetParts, TargetCFrames, Enum.BulkMoveMode.FireCFrameChanged)

	for _, Object in AddedObjects do
		(Object:: Instance).Parent = CacheHolder
	end

	return self._FreeObjects[InitialLength + Amount]
end

--[=[
    Gets an object from the cache, moving it to the specified CFrame if provided.
    :::caution Moving the returned object
    If you provide a CFrame, the movement is deferred so it can be bulk moved.
    Keep this in mind if you need to do other operations on the object immediately after moving it.
    :::
]=]
function ObjectCache:Get<T>(moveTo: CFrame?): T
	local obj = table.remove(self._FreeObjects) or self:_GetNew(self._ExpandAmount, true)

	self._InUseObjects[obj] = true

	if moveTo then
		table.insert(MovingParts, GetRoot(obj))
		table.insert(MovingCFrames, moveTo)

		if not ScheduledUpdate then
			ScheduledUpdate = true
			task.defer(UpdateMovementThread)
		end
	end

	return obj :: any
end

--[=[
    Returns an object to the cache.
]=]
function ObjectCache:Return<T>(obj: T)
	if not self:IsInUse(obj) then
        assert(self:BelongsTo(obj), "Attempted to return an object that does not belong to this cache!")
		return -- Already Returned!
	end

    for _, fn in ipairs(self._OnReturnFns) do
        fn(obj)
    end

	self._InUseObjects[obj] = nil

	table.insert(self._FreeObjects, obj)
	table.insert(MovingParts, GetRoot(obj :: any))
	table.insert(MovingCFrames, FAR_AWAY_CFRAME)

	if not ScheduledUpdate then
		ScheduledUpdate = true
		task.defer(UpdateMovementThread)
	end
end

--[=[
    Expands the cache by the specified amount.
    @param Amount number -- The amount to expand the cache by.
]=]
function ObjectCache:ExpandCache(Amount: number?)
	assert(typeof(Amount) == "nil" or Amount >= 0, `Invalid argument #1 to 'ObjectCache:ExpandCache' (positive number expected, got {typeof(Amount)})`)
	self:_GetNew(Amount, false)
end

--[=[
    Sets the default amount to expand the cache by.
    @param Amount number -- The amount to expand the cache by.
]=]
function ObjectCache:SetExpandAmount(Amount: number)
	assert(typeof(Amount) == "number" and Amount > 0, `Invalid argument #1 to 'ObjectCache:SetExpandAmount' (positive number expected, got {typeof(Amount)})`)
	self._ExpandAmount = Amount
end

--[=[
    Returns whether the specified object is currently in use.
]=]
function ObjectCache:IsInUse(obj: PVInstance): boolean
	return self._InUseObjects[obj] == true
end

--[=[
    Checks if an object belongs to this cache.
]=]
function ObjectCache:BelongsTo(obj: PVInstance): boolean
    return table.find(self._FreeObjects, obj) ~= nil or self:IsInUse(obj)
end

--[=[
    Forces an immediate position update for all objects in the cache.
]=]
function ObjectCache:Update()
	task.spawn(UpdateMovementThread)
end

--[=[
    Destroys the cache and all objects within it.
]=]
function ObjectCache:Destroy()
	self.CacheHolder:Destroy()
end

--[=[
    Sets a function to run when an object is returned to the cache. Passes the object that was returned as an argument.
    @param fn (obj: T) -> () -- The function to run.
    @return () -> boolean -- A cleaner function to disconnect the connection.
]=]
function ObjectCache:ConnectOnReturn<T>(fn: (obj: T) -> ()): () -> boolean
    table.insert(self._OnReturnFns, fn)
    return function()
        local idx = table.find(self._OnReturnFns, fn)
        if idx then
            table.remove(self._OnReturnFns, idx)
            return true
        end
        return false
    end
end


-- function ObjectCache:SetCacheParent()
    
-- end

-- function ObjectCache:GetCacheParent()
--     return self.CacheHolder
-- end

--------------------------------------------------------------------------------
    --// Class Constructor //--
--------------------------------------------------------------------------------


local CachesFolder
local function GetDefaultCacheParent()
    if not CachesFolder then
        CachesFolder = Instance.new("Folder")
        CachesFolder.Name = "ObjectCaches"
        CachesFolder.Parent = workspace
    end
	return CachesFolder
end

local function CreateCacheContainer(name: string?)
    local CacheHolder = Instance.new("Folder")
	CacheHolder.Name = name or "ObjectCache"
    return CacheHolder
end


local validateConstructor = T.interface({
    Template = T.union(T.instanceIsA("PVInstance"), T.callback),
    InitialSize = T.optional(T.numberPositive),
    ExpansionSize = T.optional(T.numberPositive),
    Parent = T.optional(T.instanceIsA("Instance")),
})

---------------------------------------------------------------------

local OBJECT_CACHE_CLASS = {}
setmetatable(OBJECT_CACHE_CLASS, {
    __call = function(t, config)
        return t.new(config)
    end
})

--[=[
    @within ObjectCache
    @function setupModelForCacheMovement
    @param model Model
    Sets up a model for cache movement by welding all of its descendant BaseParts to its PrimaryPart.
]=]
OBJECT_CACHE_CLASS.setupModelForCacheMovement = SetupModelForCacheMovement

--[=[
    @within ObjectCache
    @function isModelSetupForCacheMovement
    @param model Model
    @return boolean
    Checks if a model is setup for cache movement.
]=]
OBJECT_CACHE_CLASS.isModelSetupForCacheMovement = IsModelSetupForCacheMovement


--[=[
    @within ObjectCache
    @interface CacheConfig
    .Template T | () -> T -- The template object to use for the cache. Must be a PVInstance or a function that returns a PVInstance.
    .InitialSize number? -- The initial size of the cache. Defaults to 10.
    .ExpansionSize number? -- The amount to expand the cache by. Defaults to 50.
    .ObjectsParent Instance? -- The parent to put the objects in.
    .CacheParent Instance? -- The parent to put the cache in.
    .Name string? -- The name of the cache.
]=]

--[=[
    @within ObjectCache
    @function new
    @param config CacheConfig

    Creates a new ObjectCache.

    ```lua
    local myCache: ObjectCache<Part> = ObjectCache.new({
        Template = function()
            local part = Instance.new("Part")
            part.Anchored = true
            return part
        end,
    })
    ```

    :::warning Anchored Parts
    Make sure that your template object is anchored. Otherwise when it returns to the cache it will fall out of existence.
    :::

    :::info
    Luau LSP type inference for the template is not yet robust enough to properly infer the type of the template object.
    As a result, you should properly assign the right type to your cache object.
    :::
]=]
function OBJECT_CACHE_CLASS.new<T>(config: {
    Template: T | () -> (T), 

    InitialSize: number?, 
    ExpansionSize: number?,
    
    ObjectsParent: Instance?,
    CacheParent: Instance?,
    Name: string?,
}): ObjectCache<T>
    assert(validateConstructor(config))

    local Template = config.Template

    if typeof(Template) == "Instance" then
        assert(Template:IsA("BasePart") or Template:IsA("Model"), `Invalid argument #1 to 'ObjectCache.new' (BasePart or Model expected, got {Template.ClassName})`)
        assert(Template.Archivable, `ObjectCache: Cannot use template object provided, as it has Archivable set to false.`)
        if Template:IsA("Model") then
            assert(Template.PrimaryPart ~= nil, `Invalid Template provided to 'ObjectCache.new': Model has no PrimaryPart set!`)
            SetupModelForCacheMovement(Template)
        else
            assert(Template.Anchored, `Invalid Template provided to 'ObjectCache.new': BasePart is not anchored!`)
        end
    end
    
	local PreallocAmount = config.InitialSize or 10
    local ObjectsParent = config.ObjectsParent or CreateCacheContainer(config.Name)

	local FreeObjects: {T} = table.create(PreallocAmount)
	local InUseObjects: {[T]: boolean?} = {}
    setmetatable(InUseObjects, {__mode = "k"}) -- mark as weak keys

	for Index = 1, PreallocAmount do
		local Object, ObjectRoot = MakeFromTemplate(Template :: any)

		FreeObjects[Index] = Object :: any

		ObjectRoot.CFrame = FAR_AWAY_CFRAME;
		(Object:: Instance).Parent = ObjectsParent
	end

	(ObjectsParent :: Instance).Parent = config.CacheParent or GetDefaultCacheParent()

    -- Create the cache object
	return setmetatable({
		CacheHolder = ObjectsParent,
		_ExpandAmount = EXPAND_BY_AMOUNT,
		_Template = Template,
		_FreeObjects = FreeObjects,
		_InUseObjects = InUseObjects ,
		_PreallocatedAmount = PreallocAmount,
        _OnReturnFns = {},
	}, ObjectCache) :: any
end


return table.freeze(OBJECT_CACHE_CLASS)