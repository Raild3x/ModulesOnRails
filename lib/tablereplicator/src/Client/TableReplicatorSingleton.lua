-- Authors: Logan Hunt (Raildex)
-- January 22, 2024
--[=[
    @class TableReplicatorSingleton
    @client

    This class provides a system for creating easy access to a single TableReplicator
    that is guaranteed to exist. This is useful for when you want to access data, that
    may not have replicated yet, immediately. You provide a default schema to use if
    the TableReplicator is not ready yet.
]=]


local Packages = script.Parent.Parent.Parent
local Fusion = require(Packages.Fusion)
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local TableManager = require(Packages.TableManager)
local BaseObject = require(Packages.BaseObject)
local SuperClass = BaseObject

local ClientTableReplicator : typeof(require(script.Parent.ClientTableReplicator))
type ClientTableReplicator = typeof(ClientTableReplicator)

type Promise = typeof(Promise.new())
type table = {[any]: any}
type Path = TableManager.Path
type TableManager = TableManager.TableManager
type State<T> = Fusion.StateObject<T>

local PathToArray = TableManager.PathToArray
local PathToString = TableManager.PathToString
local ParseTableFromPath = function(tbl: table, pathArray: {string}): any?
    local currentTable = tbl
    for _, key in PathToArray(pathArray) do
        currentTable = currentTable[key]
        if not currentTable then -- if the rest of the path is missing then stop
            return nil
        end
    end
    return currentTable
end

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local TableReplicatorSingleton = setmetatable({}, SuperClass)
TableReplicatorSingleton.ClassName = "TableReplicatorSingleton"
TableReplicatorSingleton.__index = TableReplicatorSingleton

--[=[
    @within TableReplicatorSingleton
    @interface Config
    .ClassTokenName string -- The name of the class token to listen for.
    .DefaultDataSchema table? -- The default schema to use if the replicator is not ready yet.
    .ConditionFn ((replicator: ClientTableReplicator) -> boolean)? -- A function that returns whether or not the replicator is valid and should be bound.
]=]
type Config = {
    ClassTokenName: string,
    DefaultDataSchema: table?,
    ConditionFn: ((replicator: ClientTableReplicator) -> boolean)?,
}

--[=[
    Creates a new TableReplicatorSingleton.

    ```lua
    local ClientPlayerData = TableReplicatorSingleton.new {
        ClassTokenName = "PlayerData";
        DefaultDataSchema = Import("PlayerDataSchema");
        ConditionFn = function(replicator)
            return replicator:GetTag("UserId") == LocalPlayer.UserId
        end;
    }

    return ClientPlayerData
    ```
]=]
function TableReplicatorSingleton.new(config: Config)
    local self = setmetatable(SuperClass.new(), TableReplicatorSingleton)

    self:RegisterSignal("Loaded")

    assert(typeof(config.ClassTokenName) == "string", "TableReplicatorSingleton.new() requires a string ClassTokenName")
    self._ClassTokenName = config.ClassTokenName
    self._DefaultSchema = config.DefaultDataSchema

    self._TR = nil

    self._FStates = {}

    ------------------------------------------------------------------------

    local conditionFn = config.ConditionFn
    local TableReplicator = require(script.Parent.ClientTableReplicator)

    -- Check if a valid replicator already exists
    for _, replicator in TableReplicator.getAll(self._ClassTokenName) do
        if not conditionFn or conditionFn(replicator)  then
            self._TR = replicator
            self:FireSignal("Loaded", replicator)
            break
        end
    end

    -- Listen for a new replicator to be created
    if not self._TR then
        self:AddTask(TableReplicator.listenForNewReplicator(self._ClassTokenName, function(replicator)
            if conditionFn and not conditionFn(replicator) then
                return
            end

            self._TR = replicator
            self:FireSignal("Loaded", replicator)
            self:RemoveTask("ReplicationListener")
        end), nil, "ReplicationListener")
    end
    
    ------------------------------------------------------------------------

    return self
end

--[=[
    Fetches the value at the path. An index can be provided to fetch the value at
    that index. If the value is not ready yet, it will return the value rom the
    default schema if one was given. If the path is untraversable, it will return
    nil.

    ```lua
    local coins = ClientPlayerData:Get("Coins")
    local thirdItem = ClientPlayerData:Get("Inventory", 3) -- Equivalent to `ClientPlayerData:Get("Inventory")[3]`
    ```
]=]
function TableReplicatorSingleton:Get(path: Path, index: number?): any?
    if index then
        path = PathToArray(path)
        table.insert(path, index)
    end

    if not self:IsReady() then
        if self._DefaultSchema then
            local valueAtPath = ParseTableFromPath(self._DefaultSchema, path)
            return valueAtPath
        else
            warn(":Get() called before TableReplicatorSingleton was ready and no default schema is set.")
            return nil
        end
    end
    return self:GetTableManager():Get(path, index)
end


--[=[
    Called immediately and then whenever the value at the path changes.
    The callback will be called with the new value.

    ```lua
    ClientPlayerData:Observe("Coins", function(newValue)
        print("Coins changed to", newValue)
    end)
    ```
]=]
function TableReplicatorSingleton:Observe(path: Path, callback: (newValue: any?) -> ()): () -> ()
    local currentValue = self:Get(path)
    task.spawn(callback, currentValue)
    return self:ListenToValueChange(path, callback)
end

--[=[
    Called when the value at the path is changed.
    The callback will be called with the new value.

    ```lua
    ClientPlayerData:ListenToValueChange("Coins", function(newValue)
        print("Coins changed to", newValue)
    end)
    ```

    @return function -- A function that, when called, will disconnect the listener.
]=]
function TableReplicatorSingleton:ListenToValueChange(path: Path, callback: (...any) -> ()): () -> ()
    local jani = Janitor.new()
    if not self:IsReady() then
        jani:AddPromise(self:OnReady():andThen(function()
            local TM = self:GetTableManager()
            jani:Add(TM:ListenToValueChange(path, callback))
            callback(self:Get(path))
        end))
    else
        local TM = self:GetTableManager()
        jani:Add(TM:ListenToValueChange(path, callback))
    end

    return function ()
        jani:Destroy()
    end
end

--[=[
    Called when the value at the path is changed through any means.
    This includes if the value is an array and a value in the array is changed, inserted, or removed.
]=]
function TableReplicatorSingleton:ListenToAnyChange(path: Path, callback: (...any) -> ()): () -> ()
    local jani = Janitor.new()
    if not self:IsReady() then
        jani:AddPromise(self:OnReady():andThen(function()
            local TM = self:GetTableManager()
            jani:Add(TM:ListenToArraySet(path, callback))
            jani:Add(TM:ListenToArrayInsert(path, callback))
            jani:Add(TM:ListenToArrayRemove(path, callback))
            jani:Add(TM:ListenToValueChange(path, callback))
            callback(self:Get(path))
        end))
    else
        local TM = self:GetTableManager()
        jani:Add(TM:ListenToArraySet(path, callback))
        jani:Add(TM:ListenToArrayInsert(path, callback))
        jani:Add(TM:ListenToArrayRemove(path, callback))
        jani:Add(TM:ListenToValueChange(path, callback))
    end

    return function ()
        jani:Destroy()
    end
end

--[=[
    Returns a Fusion State object that will automatically update when the value at
    the path changes. This is useful for when you want to use Fusion dependents
    to respond to changes in the value.

    ```lua
    local coinsState = ClientPlayerData:ToFusionState("Coins")
    
    New "TextLabel" {
        Text = coinsState;
    }
    ```
]=]
function TableReplicatorSingleton:ToFusionState(path: Path): State<any>
    local stringPath = PathToString(path)
    if not self._FStates[stringPath] then
        local state = Fusion.Value(self:Get(path))
        self._FStates[stringPath] = state

        self:ListenToAnyChange(path, function()
            state:set(self:Get(path))
        end)
    end
    return self._FStates[stringPath]
end

--[=[
    Gets the TableManager for the TableReplicatorSingleton. This will error if
    the TableManager is not ready yet.
    
    ```lua
    local TM = ClientPlayerData:GetTableManager()
    ```
]=]
function TableReplicatorSingleton:GetTableManager(): TableManager
    assert(self:IsReady(), "TableManager is not ready yet")
    return self:GetTableReplicator():GetTableManager()
end

--[=[
    Gets the TableReplicator for the TableReplicatorSingleton. This will error if
    the TableReplicator is not ready yet.
    
    ```lua
    local TR = ClientPlayerData:GetTableReplicator()
    ```
]=]
function TableReplicatorSingleton:GetTableReplicator(): ClientTableReplicator
    assert(self:IsReady(), "TableReplicator is not ready yet")
    return self._TR
end

--[=[
    Returns a promise that resolves with the TableManager when it is ready.
    
    ```lua
    ClientPlayerData:PromiseTableManager():andThen(function(TM: TableManager)
        print("TableManager is ready!")
    end)
    ```

    @return Promise<TableManager>
]=]
function TableReplicatorSingleton:PromiseTableManager(): Promise
    return self:OnReady():andThen(function()
        return self:GetTableManager()
    end)
end

--[=[
    Returns a promise that resolves with the TableReplicator when it is ready.
    
    ```lua
    ClientPlayerData:PromiseTableReplicator():andThen(function(TR: ClientTableReplicator)
        print("TableReplicator is ready!")
    end)
    ```

    @return Promise<ClientTableReplicator>
]=]
function TableReplicatorSingleton:PromiseTableReplicator(): Promise
    return self:OnReady():andThen(function()
        return self:GetTableReplicator()
    end)
end

--[=[
    Returns whether or not a valid Replicator has been found and hooked into.
    
    ```lua
    if ClientPlayerData:IsReady() then
        print("We have a valid Replicator!")
    end
    ```
]=]
function TableReplicatorSingleton:IsReady(): boolean
    return self._TR ~= nil
end

--[=[
    Returns a promise that resolves when the TableReplicatorSingleton is ready.
    
    ```lua
    ClientPlayerData:OnReady():andThen(function()
        print("Found a valid Replicator!")
    end)
    ```

    @return Promise<()>
]=]
function TableReplicatorSingleton:OnReady(): Promise
    if self:IsReady() then
        return Promise.resolve(self:GetTableReplicator())
    else
        return self:AddPromise(Promise.fromEvent(self:GetSignal("Loaded")))
    end
end

return TableReplicatorSingleton