-- Authors: Logan Hunt (Raildex)
-- January 05, 2024
--[=[
    @class BaseTableReplicator

    Inherits from BaseObject.

    Exposed Object Signals:
    ```lua
    :GetSignal("ParentChanged")
    :GetSignal("ChildAdded")
    :GetSignal("ChildRemoved")
    ```
]=]

--// Services //--
local RunService = game:GetService("RunService")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local TableManager = require(Packages.TableManager)
local BaseObject = require(Packages.BaseObject)
local RailUtil = require(Packages.RailUtil)
local Promise = require(Packages.Promise)
local Signal = require(Packages.Signal)
local TableReplicatorUtil = require(script.Parent.TableReplicatorUtil)

--// Types //--
type TableManager = TableManager.TableManager
type ClassToken = TableReplicatorUtil.ClassToken
type Tags = TableReplicatorUtil.Tags
type Promise = typeof(Promise.new())

--[=[
    @within BaseTableReplicator
    @type Id number
    The id of a replicator.
]=]
export type Id = number

type CreationListener = (replicator: BaseTableReplicator) -> ()
type CanBeArray<T> = T | {T}

--// Constants //--
-- Whether or not to defer listener calls to the next frame.
local DEFFERED_LISTENERS = false

--// Volatiles //--
local STORAGE: {[Id]: BaseTableReplicator} = {}

local CREATION_LISTENERS: {[string]: {CreationListener}} = {}

local SwapRemoveFirstValue = RailUtil.Table.SwapRemoveFirstValue

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local BaseTableReplicator = setmetatable({}, BaseObject)
BaseTableReplicator.ClassName = "BaseTableReplicator"
BaseTableReplicator.__index = BaseTableReplicator

--[=[
    @within BaseTableReplicator
    @tag Metamethod
    @function __iter
    Iterates over all replicators that are currently in memory.
    ```lua
    for _, replicator in TableReplicator do
        print(replicator:GetServerId())
    end
    ```
]=]
BaseTableReplicator.__iter = function()
    return next, STORAGE
end


--[=[
    @within BaseTableReplicator
    @prop ReplicatorCreated Signal<BaseTableReplicator>
    A signal that fires whenever a new replicator is created.
]=]
local ReplicatorCreatedSignal = Signal.new()
BaseTableReplicator.ReplicatorCreated = ReplicatorCreatedSignal

--------------------------------------------------------------------------------
    --// Static Methods //--
--------------------------------------------------------------------------------

--[=[
    @within BaseTableReplicator
    @type SearchCondition string | ClassToken | Tags | (replicator: BaseTableReplicator, manager: TableManager?) -> (boolean)
    A condition that can be used to filter replicators.
    The condition can be a `function`, a `ClassToken`, a `string` representing a ClassToken's name, or a `Tags` dictionary.
    - If the condition is a function then it should return a boolean to indicate success.
    - If the condition is a ClassToken then it will check if the replicator's class token matches the given token.
    - If the condition is a string then it will check if the replicator's class token name matches the given string.
    - If the condition is a Tags dictionary then it will check if the replicator's tags are a superset of the given tags.
]=]
type SearchCondition = ((replicator: BaseTableReplicator, manager: TableManager?) -> (boolean)) | ClassToken | string | Tags
local function ReconcileCondition(condition: SearchCondition): ((replicator: BaseTableReplicator, manager: TableManager) -> (boolean))
    -- Ensure the condition is a function
    local conditionType = type(condition)

    if conditionType == "function" then
        return condition :: any
    elseif conditionType == "string" then
        local classTokenName = condition :: string
        condition = function(replicator, _)
            --print("TokenName Check:", replicator, classTokenName)
            return BaseTableReplicator.GetTokenName(replicator) == classTokenName
        end
    elseif conditionType == "table" then
        local classToken = condition :: ClassToken
        local isClassToken = if classToken.Name and tostring(classToken):find("ClassToken") and getmetatable(classToken) then true else false
        if isClassToken then
            condition = function(replicator, _)
                --print("TokenName Check:", replicator, classToken)
                return BaseTableReplicator.GetTokenName(replicator) == classToken.Name
            end
        else -- Is Tags
            local tags = condition :: Tags
            condition = function(replicator, _)
                --print("Tags Check:", replicator, tags)
                return BaseTableReplicator.IsSupersetOfTags(replicator, tags)
            end
        end
    elseif conditionType == "nil" then
        condition = function()
            -- print("No condition provided")
            return true
        end
    else
        error("Invalid condition type. Expected: 'function', 'string', 'table', 'nil', Got: '" .. conditionType .. "'")
    end

    return condition :: any
end


--[=[
    @tag Static
    Returns the replicator with the given id if one exists.
]=]
function BaseTableReplicator.getFromServerId(id: Id): BaseTableReplicator?
    id = tonumber(id) :: number
    if type(id) ~= "number" then
        error("Invalid id type. Expected: 'number', Got: '" .. typeof(id) .. "'")
    end
    return STORAGE[id];
end

--[=[
    @tag Static
    forEach is a special function that allows you to run a function on all replicators that currently
    exist or will exist that match the given condition.

    :::caution
    There are rare edge cases where if a Replicator is destroyed soon after it is created and you have deffered events,
    it will be destroyed before the ReplicatorCreated signal fires. In this case you can set allowDestroyedReplicators to true
    to allow destroyed replicators to be returned.
    :::
]=]
function BaseTableReplicator.forEach(
    condition: SearchCondition,
    fn: (replicator: BaseTableReplicator, manager: TableManager?) -> (),
    allowDestroyedReplicators: boolean?
)
    local SatisfiesCondition = ReconcileCondition(condition)

    -- Iterate over all current replicators
    for _, replicator in pairs(STORAGE) do
        if replicator.IsDestroyed then
            if allowDestroyedReplicators and SatisfiesCondition(replicator) then
                fn(replicator, nil)
            end
        else
            local manager = replicator:GetTableManager()
            if SatisfiesCondition(replicator, manager) then
                fn(replicator, manager)
            end
        end
    end

    -- Watch for new replicators
    return ReplicatorCreatedSignal:Connect(function(replicator)
        if replicator.IsDestroyed then
            if allowDestroyedReplicators and SatisfiesCondition(replicator) then
                fn(replicator, nil)
            end
        else
            local manager = replicator:GetTableManager()
            if SatisfiesCondition(replicator, manager) then
                fn(replicator, manager)
            end
        end
    end)
end


--[=[
    @tag Static
    promiseFirstReplicator is a special function that allows you to run a function on the first replicator to satisfy
    the given condition. If no replicator currently exists that satisfies the condition then it will wait for one to be created.
    
    @return Promise<BaseTableReplicator, TableManager?>

    ```lua
    BaseTableReplicator.promiseFirstReplicator("Test")
    ```
    :::caution
    There are rare edge cases where if a Replicator is destroyed soon after it is created and you have deffered events,
    it will be destroyed before the ReplicatorCreated signal fires. In this case you can set allowDestroyedReplicators to true
    to allow destroyed replicators to be returned.
    :::
]=]
function BaseTableReplicator.promiseFirstReplicator(condition: SearchCondition, allowDestroyedReplicators: boolean?): Promise
    local SatisfiesCondition = ReconcileCondition(condition)

    -- Check all current replicators
    for _, replicator in pairs(STORAGE) do
        if replicator.IsDestroyed then
            if allowDestroyedReplicators and SatisfiesCondition(replicator) then
                return Promise.resolve(replicator)
            end
        else
            local manager = replicator:GetTableManager()
            if SatisfiesCondition(replicator, manager) then
                return Promise.resolve(replicator, manager)
            end
        end
    end

    -- Watch for new replicators
    return Promise.fromEvent(ReplicatorCreatedSignal, function(replicator)
        if replicator.IsDestroyed then
            return if allowDestroyedReplicators then SatisfiesCondition(replicator) else false
        else
            return SatisfiesCondition(replicator, replicator:GetTableManager())
        end
    end):andThen(function(replicator)
        return replicator, (not replicator.IsDestroyed and replicator:GetTableManager())
    end)
end

--[=[
    @tag Static
    Fetches all replicators that are currently in memory. This is very slow and should be used sparingly.
]=]
function BaseTableReplicator.getAll(classTokenName: string?): {BaseTableReplicator}
    local results = {}
    for _, replicator in pairs(STORAGE) do
        if not classTokenName or replicator:GetTokenName() == classTokenName then
            table.insert(results, replicator)
        end
    end
    return results
end

--[=[
    @tag Static
    Listens for new replicators that are created with the given class token.
]=]
function BaseTableReplicator.onNew(classToken: CanBeArray<string | ClassToken>, fn: (replicator: BaseTableReplicator) -> ()): (() -> ())
    if typeof(classToken) == "string" or (classToken :: any).Name then
        classToken = {classToken}
    end
    assert(typeof(fn) == "function", "fn must be a function")
    assert(typeof(classToken) == "table", "classToken must be a string or Token(table)")
    for i, token in ipairs(classToken) do
        token = (if typeof(token) == "table" then token.Name else token) :: string
        (classToken :: any)[i] = token

        local listeners = CREATION_LISTENERS[token]
        if not listeners then
            listeners = {}
            CREATION_LISTENERS[token] = listeners
        end
        table.insert(listeners, fn)
    end
    

    return function ()
        for _, tokenName in ipairs(classToken) do
            SwapRemoveFirstValue(CREATION_LISTENERS[tokenName], fn)
        end
    end
end
BaseTableReplicator.listenForNewReplicator = BaseTableReplicator.onNew

--[=[
    @private
    @tag Static
]=]
function BaseTableReplicator.new(config: {
    ServerId: Id?;
    Tags: Tags?;
    TableManager: TableManager;
    IsTopLevel: boolean?;
})
    local self = setmetatable(BaseObject.new(), BaseTableReplicator)

    -- Validate the config
    local Id = if RunService:IsServer() then self:GetId() else config.ServerId
    assert(typeof(Id) == "number", `Invalid ServerId type. Expected: 'number', Got: '{typeof(Id)}'`)
    
    local tags = config.Tags or {}
    assert(typeof(tags) == "table", `Invalid tags type. Expected: 'table', Got: '{typeof(tags)}'`)
    
    local tblManager = config.TableManager
    assert(typeof(tblManager) == "table" and tblManager:IsA(TableManager), `Invalid TableManager.`)
    
    -- Set the properties
    self._ServerId = Id
    self._Tags = table.freeze(tags)
    self._TableManager = tblManager;
    self._Parent = nil;
    self._Children = {};

    self:RegisterSignal("ParentChanged")
    self:RegisterSignal("ChildAdded")
    self:RegisterSignal("ChildRemoved")

    -- Store the id of this object in a global table so we can find it later
    STORAGE[self:GetServerId()] = self

    return self
end

--[=[
    @private
]=]
function BaseTableReplicator:Destroy()
    if self:GetParent() then
        SwapRemoveFirstValue(self:GetParent()._Children, self)
        self:GetParent():FireSignal("ChildRemoved", self)
    end

    STORAGE[self:GetServerId()] = nil
    getmetatable(BaseTableReplicator).Destroy(self)
end

--[=[
    @private
    Fires the creation listeners for this replicator.
]=]
function BaseTableReplicator:_FireCreationListeners()
    assert(not self._CreationListenersFired, "Creation listeners already fired")
    self._CreationListenersFired = true

    local classTokenName = self:GetTokenName()
    local spawner = if DEFFERED_LISTENERS then task.defer else task.spawn
    local listeners = CREATION_LISTENERS[classTokenName] or {}

    for _, listener in pairs(table.clone(listeners)) do
        if spawner == task.defer or table.find(listeners, listener) then
            spawner(listener, self)
        else
            warn("Listener was removed during the call process.")
        end
    end

    --print("Firing core signal")
    ReplicatorCreatedSignal:Fire(self)
end

--------------------------------------------------------------------------------
    --// Getters //--
--------------------------------------------------------------------------------

--[=[
    Gets the TableManager that is being replicated.
]=]
function BaseTableReplicator:GetTableManager(): TableManager
    return self._TableManager;
end

--[=[
    Returns the server id for this replicator.
    On the Server this is equivalent to :GetId()
]=]
function BaseTableReplicator:GetServerId(): Id
    return self._ServerId;
end

--[=[
    Fetches the name of the class token that this replicator is using.
]=]
function BaseTableReplicator:GetTokenName(): string
    return self._ClassTokenName or self._ClassToken.Name
end

--[=[
    Returns whether or not this replicator is a top level replicator.
    A top level replicator is a replicator that has no parent.
    Only top level replicators can have their ReplicationTargets set.
]=]
function BaseTableReplicator:IsTopLevel(): boolean
    return self._Parent == nil;
end


--------------------------------------------------------------------------------
    --// Child Fetchers //--
--------------------------------------------------------------------------------

--[=[
    Returns the parent of this replicator if it has one.
    If this replicator is a top level replicator then this will return nil.
]=]
function BaseTableReplicator:GetParent(): BaseTableReplicator?
    return self._Parent;
end

--[=[
    Returns the immediate children of this replicator.
]=]
function BaseTableReplicator:GetChildren(): {BaseTableReplicator}
    return table.clone(self._Children);
end

--[=[
    Returns the descendants of this replicator.
]=]
function BaseTableReplicator:GetDescendants(): {BaseTableReplicator}
    local descendants = {}

    local function AddChildren(parent: BaseTableReplicator)
        table.move(parent._Children, 1, #parent._Children, #descendants + 1, descendants)
        for _, child in pairs(parent._Children) do
            AddChildren(child)
        end
    end
    AddChildren(self)

    return descendants
end

--[=[
    Finds the first child that satisfies the given condition.
    The condition can be a `function`, a `ClassToken`, a `string` representing a ClassToken's name, or a `Tags` dictionary.
    If recursive is true then it will search through all descendants.
    ```lua
    local child = tr:FindFirstChild(function(child)
        local manager = child:GetTableManager()
        return manager:Get("Test") == 1
    })
    ```
]=]
function BaseTableReplicator:FindFirstChild(condition: SearchCondition, recursive: boolean?): BaseTableReplicator?
    local SatisfiesCondition = ReconcileCondition(condition)

    for _, child in pairs(self._Children) do
        if SatisfiesCondition(child, child:GetTableManager()) then
            return child
        end
    end

    if recursive then
        for _, child in pairs(self._Children) do
            local found = child:FindFirstChild(condition, true)
            if found then
                return found
            end
        end
    end
    return nil
end

--[=[
    Returns a promise that resolves when the first child that satisfies the given function is found.

    ```lua
    tr:PromiseFirstChild(function(replicator)
        local manager = replicator:GetTableManager()
        return manager:Get("Test") == 1
    }):andThen(function(replicator)
        print("Found child with data key 'Test' equal to 1!")
    end)

    tr:PromiseFirstChild("Test"):andThen(function(replicator)
        print("Found child with classtoken 'Test'!")
    end)

    tr:PromiseFirstChild({UserId == 12345}):andThen(function(replicator)
        print("Found child with UserId Tag matching 12345!")
    end)
    ```

    @return Promise<BaseTableReplicator>
]=]
function BaseTableReplicator:PromiseFirstChild(condition: SearchCondition): Promise
    condition = ReconcileCondition(condition)

    local child = self:FindFirstChild(condition)
    if child then
        return Promise.resolve(child)
    end

    return self:AddPromise(Promise.fromEvent(self:GetSignal("ChildAdded"), condition))
end


--------------------------------------------------------------------------------
    --// Tag Util Methods //--
--------------------------------------------------------------------------------

--[=[
    Returns the value of the given tag for this replicator.
]=]
function BaseTableReplicator:GetTag(tagKey: string): any
    return self._Tags[tagKey]
end

--[=[
    Returns the tags dictionary for this replicator.
]=]
function BaseTableReplicator:GetTags(): Tags
    return self._Tags
end

--[=[
    Checks whether or not the given tags are a subset of this replicator's tags.
    ELI5: Are all the given tags also on this replicator?
    Aliased as `:ContainsAllTags(tags)`
        ```lua
    local tr = TableReplicator.new({
        Tags = {
            Test1 = 1,
            Test2 = 2,
        }
    })

    tr:IsSupersetOfTags({
        Test1 = 1,
    }) -- true

    tr:IsSupersetOfTags({
        Test2 = 2,
    }) -- true
    ```
]=]
function BaseTableReplicator:IsSupersetOfTags(tags: Tags): boolean
    local currentTags = self._Tags
    for tag, value in pairs(tags) do
        if currentTags[tag] ~= value then
            return false
        end
    end
    return true
end
BaseTableReplicator.ContainsAllTags = BaseTableReplicator.IsSupersetOfTags

--[=[
    Checks whether or not this replicator's tags are a subset of the given tags.
    ELI5: Are all the tags on this replicator also on the given tags?
    Aliased as `:IsWithinTags(tags)`
    ```lua
    local tr = TableReplicator.new({
        Tags = {
            Test1 = 1,
            Test2 = 2,
        }
    })

    tr:IsSubsetOfTags({
        Test1 = 1,
        Test2 = 2,
        Test3 = 3,
    }) -- true

    tr:IsSubsetOfTags({
        Test1 = 1,
    }) -- false
    ```
]=]
function BaseTableReplicator:IsSubsetOfTags(tags: Tags): boolean
    for tag, value in pairs(self._Tags) do
        if tags[tag] ~= value then
            return false
        end
    end
    return true
end
BaseTableReplicator.IsWithinTags = BaseTableReplicator.IsSubsetOfTags

--------------------------------------------------------------------------------
    --// Final Return //--
--------------------------------------------------------------------------------

export type BaseTableReplicator = typeof(BaseTableReplicator.new({TableManager = TableManager.new()}))

return BaseTableReplicator