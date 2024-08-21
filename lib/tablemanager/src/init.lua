-- Authors: Logan Hunt (Raildex)
-- January 04, 2024
--[=[
    @class TableManager

    A class for managing a table such that you can listen to changes and modify values easily.
    TableManager is designed to provide robust listener functionality at the cost of some performance.

    :::tip
    The TableManager has some methods to combine functionality for both values and arrays.
    It will redirect to the proper method depending on your given arguments.
    ```lua
    :Set() -- Redirects to :SetValue() or :ArraySet()
    :Increment() -- Redirects to :IncrementValue() or :ArrayIncrement()
    :Mutate() -- Redirects to :MutateValue() or :ArrayMutate()
    ```
    :::
    
]=]

--// Imports //--
local Packages = script.Parent
local TableState = require(script.TableState)
local Signal = require(Packages.Signal)
local Fusion = require(Packages.Fusion)
local Promise = require(Packages.Promise)
local BaseObject = require(Packages.BaseObject)
local SuperClass = BaseObject

--// Types //--
type TableState = TableState.TableState
type FusionState<T> = Fusion.StateObject<T>
type Promise = Promise.Promise

type Signal = Signal.Signal
type SignalInternal = Signal & {_head: any}
type Connection = Signal.Connection

type Numeric = number | Vector2 | Vector3 | CFrame | table | any
type table = {[any]: any}

-- Internal type
type ListenerContainer = {
    ChildListeners: {[any]: ListenerContainer?};
    ValueChanged: Signal?;
    ArraySet: Signal?;
    ArrayInsert: Signal?;
    ArrayRemove: Signal?;
    FusionState: FusionState<any>?;
}

--[=[
    @within TableManager
    @type CanBeArray<T> T | {T}
    A type that could be an individual of the type or an array of the type.
]=]
type CanBeArray<T> = T | {T}

--[=[
    @within TableManager
    @type Path string | {any}
    A path to a value in a table.
    Can be written as a string in dot format or an array of strings.
    :::Note
    The array format is faster to parse and should be used when possible.
    :::
    ```lua
    local tbl = {
        MyPath = {
            To = {
                Value = 0;
            };
        };
    }
    
    local path1: Path = "MyPath.To.Value" -- Style 1
    local path2: Path = {"MyPath", "To", "Value"} -- Style 2
    ```
]=]
export type Path = CanBeArray<any>
type PathArray = {any}

--[=[
    @within TableManager
    @type ValueListenerFn (newValue: any, oldValue: any?, changeMetadata: ChangeMetadata?) -> ()
]=]
type ValueListenerFn = (newValue: any?, oldValue: any?, changeMetadata: ChangeMetadata?) -> ()

--// Constants //--
local ROOT_TABLE_PATH = {}
local WEAK_MT = {__mode = "k"}

--[=[
    @within TableManager
    @type ListenerType "ValueChanged" | "ArraySet" | "ArrayInsert" | "ArrayRemove"
    This information is mostly for internal use.
]=]
type ListenerType = string
local ChildListeners = "ChildListeners"
local ListenerTypeEnum = table.freeze {
    ValueChanged = "ValueChanged";
    ArraySet = "ArraySet";
    ArrayInsert = "ArrayInsert";
    ArrayRemove = "ArrayRemove";
    FusionState = "FusionState";
}

--[=[
    @within TableManager
    @type DataChangeSource "self" | "child" | "parent"
    This information is mostly for internal use.
]=]
type DataChangeSource = "self" | "child" | "parent"
local DataChangeSourceEnum = table.freeze {
    SelfChanged = "self";
    ChildChanged = "child";
    ParentChanged = "parent";
}

--[=[
    @within TableManager
    @interface ChangeMetadata
    .ListenerType ListenerType -- The listener type that was fired.
    .SourceDirection DataChangeSource -- The source direction of the change.
    .SourcePath {string} -- The origin path of the change.
    .NewValue any? -- [Only for value changes] The new value.
    .OldValue any? -- [Only for value changes] The old value.

    Metadata about the change that fired a listener. Used to provide more context to listeners.
    Allows you to figure out where the change came from, if it wasnt a direct change.
]=]
type ChangeMetadata = {
    ListenerType: ListenerType;
    SourceDirection: DataChangeSource;
    SourcePath: {string};
    NewValue: any?;
    OldValue: any?;
}

--// Volatiles //--
-- Cache of string paths to arrays. Helps make PathToArray faster when reusing string paths.
local stringToArrayCache: {[string]: {string}} = {}

-- Tables being managed by TableManagers.
local managedTables: {[table]: TableManager} = setmetatable({}, {__mode = "kv"}) :: any


--------------------------------------------------------------------------------
    --// Utility Fns //--
--------------------------------------------------------------------------------

local function AssertPathIsValid(path: Path) -- This method was deprecated with the introduction of non string paths
    --assert((typeof(path) == "string" or typeof(path) == "table"), "Path is required!")
end

local function AssertFnExists(fn: (...any) -> ())
    assert(type(fn) == "function", "Function is required!")
end

--[[
    Ensures the given path is a parsable array.
]]
local function PathToArray(indexPath: Path): {string}
    local pathType = typeof(indexPath)
    if pathType == "table" then
        return indexPath
    elseif pathType == "nil" then
        return ROOT_TABLE_PATH
    elseif pathType == "string" then
        if not stringToArrayCache[indexPath :: string] then
            assert(type(indexPath) == "string", "Invalid indexPath type!")
            local pathArray = indexPath:split(".")
            if pathArray[1] == "" then
                pathArray = {}
            end
            stringToArrayCache[indexPath] = pathArray
        end
        return stringToArrayCache[indexPath :: string]
    end
    return {indexPath :: string}
end

--[[
    Ensures the given path is in the string path format.
]]
local function PathToString(indexPath: Path): string
    if type(indexPath) == "string" then
        return indexPath
    end

    if typeof(indexPath) == "table" then
        local success, result = pcall(function()
            return table.concat(indexPath, ".")
        end)
        if success then
            return result
        end

        local stringPath = ""
        local pathSize = #indexPath
        for i = 1, pathSize do
            stringPath = stringPath..(indexPath :: {any})[i]
            if i < pathSize then
                stringPath = tostring(stringPath).."."
            end
        end
    end

    warn("Invalid path format!", indexPath)
    return ""
end

--[[
    Gets the table containing the value at the given path.
    Effectively gets the second to last value in the path.
    If the path is empty, it will return nothing.
]]
local function GetContainerTable(tbl: table, path: {string}): table?
    local size = #path
    if size > 0 then
        for i = 1, size - 1 do
            tbl = tbl[path[i]]
        end
        return tbl
    end
end

-- iterates through a table using a given path and optional lastKey
local function FetchValueInTableFromPath(tbl: table, path: {string}, lastKey: string | number): any?
    local currentValue = tbl

    if lastKey then
        table.insert(path, lastKey)
    end

    for i = 1, #path do
        if typeof(currentValue) ~= "table" then
            warn("Unable to reach end of path!")
            return nil
        end
        currentValue = currentValue[path[i]]
    end

    return currentValue
end

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local TableManager = setmetatable({}, SuperClass)
TableManager.ClassName = "TableManager"
TableManager.__index = TableManager
TableManager.__call = function(t, ...: any): TableManager
    return t.new(...)
end

-- FLAGS
TableManager.DEBUG = false
TableManager.FIRE_CHILD_LISTENERS = true
TableManager.FIRE_PARENT_LISTENERS = true

-- Exposed Utility Functions
TableManager.PathToString = PathToString
TableManager.PathToArray = PathToArray
TableManager.FetchValueInTableFromPath = FetchValueInTableFromPath

-- Exposed Enums
--[=[
    @within TableManager
    @prop Enums {ListenerType: ListenerTypeEnum, DataChangeSource: DataChangeSourceEnum}
    A collection of enums used by the TableManager.
]=]
TableManager.Enums = table.freeze {
    ListenerType = ListenerTypeEnum;
    DataChangeSource = DataChangeSourceEnum;
}

--[=[
    @tag Constructor
    Creates a new TableManager. Takes a table to manage, if one is not given then it will construct an empty table.

    :::warning Modifying the given table
    Once you give a table to a `TableManager`, you should never modify it directly.
    Doing so can result in the `TableManager` being unable to properly track changes
    and potentially cause data desyncs.
    :::

    :::caution Key/Value Rules
    The given table's keys should follow these rules:
    - No Mixed Tables (Tables containing keys of different datatypes)
    - Avoid using tables as keys.
    - Keys *must* not contain periods.
    - Keys *must* not be empty strings.
    - Tables/Arrays should be assigned to only one key. (No shared references as this can cause desyncs)
    - Nested tables/arrays should not be given to other `TableManager` instances. (Can cause desyncs)
    :::

    :::info
    Only one `TableManager` should be created for a given table. Attempting to create a `TableManager` for a table
    that is already being managed will return the existing `TableManager`.
    :::

    :::tip Call metamethod
    You can call the `TableManager` class to create a new instance of it.
    `TableManager()` is equivalent to `TableManager.new()`.
    :::

    
    ```lua
    local tbl = {
        Coins = 0;
        Inventory = {
            "Sword";
            "Shield";
        };
    }

    local tblMngr = TableManager.new(tbl)

    tblMngr:SetValue("Coins", 100)
    tblMngr:IncrementValue("Coins", 55)
    print(tblMngr:Get("Coins")) -- 155

    tblMngr:ArrayInsert("Inventory", "Potion")
    tblMngr:ArrayInsert("Inventory", 2, "Bow")
    print(tblMngr:Get("Inventory")) -- {"Sword", "Bow", "Shield", "Potion"}
    ```
]=]
function TableManager.new(data: table?): TableManager
    data = data or {}
    assert(type(data) == "table", "Data must be a table!")

    if managedTables[data] then
        warn("TableManager already exists for this table!", data)
        return managedTables[data]
    end

    local self = setmetatable(SuperClass.new(), TableManager)

    self._Data = data
    self._TableStateStorage = {} :: {[string]: any}

    --// Private Signals //--
    self:RegisterSignal("_ValueBulkChange")
    self:RegisterSignal("_ValueChange")

    --// Public Signals //--
    self:RegisterSignal("ValueChanged")
    --self:RegisterSignal("ValueAdded")

    self:RegisterSignal("ArraySet")
    self:RegisterSignal("ArrayInsert")
    self:RegisterSignal("ArrayRemove")

    self._Listeners = {[ChildListeners] = {}} :: ListenerContainer

    -- Store ref to table so we dont accidentally duplicate it.
    managedTables[self._Data] = self

    return self
end


--[=[
    Disconnects any listeners and removes the table from the managed tables.
]=]
function TableManager:Destroy()
    managedTables[self._Data] = nil
    getmetatable(TableManager).Destroy(self)
end

--------------------------------------------------------------------------------
    --// Setters //--
--------------------------------------------------------------------------------

--[=[
    Sets the value at the given path to the given value.
    :Set acts as a combined function for :SetValue and :ArraySet.
    ```lua
    :Set(myPathToValue, newValue)
    :Set(myPathToArray, index, newValue)
    ```

    :::caution Overwriting the root table
    Overwriting the root table is not recommended, but is technically possible by giving
    an empty table or string as a `Path`. Doing so has not been tested in depth and may
    result in unintended behavior.
    :::

    :::caution Setting array values
    You cannot set values to nil in an array with this method due to the way it parses args.
    Use `ArraySet` instead if you need to set values to nil.
    :::
]=]
function TableManager:Set(path: Path, ...: any)
    if select('#', ...) == 2 then
        local index, value = ...
        self:ArraySet(path, index, value)
    else
        local value = ...
        self:SetValue(path, value)
    end
end

--[=[
    Increments the value at the given path by the given amount.
    If the value is not a number, it will throw an error.
    :Increment acts as a combined function for :IncrementValue and :ArrayIncrement.
    ```lua
    :Increment(myPathToValue, amountToIncrementBy)
    :Increment(myPathToArray, index, amountToIncrementBy)
    ```
]=]
function TableManager:Increment(path: Path, ...: any): number?
    if select('#', ...) == 2 then
        local index, amount = ...
        return self:ArrayIncrement(path, index, amount)
    else
        local amount = ...
        return self:IncrementValue(path, amount)
    end
end

--[=[
    Mutates the value at the given path by calling the given function with the current value.
    ```lua
    :Mutate(myPathToValue, function(currentValue)
        return currentValue + 1
    end)
    ```
]=]
function TableManager:Mutate(path: Path, ...: any): any?
    if select('#', ...) == 2 then
        local index, fn = ...
        return self:ArrayMutate(path, index, fn)
    else
        local fn = ...
        return self:MutateValue(path, fn)
    end
end


--[=[
    Sets the value at the given path to the given value.
    This will fire the ValueChanged signal if the value is different.
    Returns a boolean indicating whether or not the value was changed.
    ```lua
    local didChange = manager:SetValue("MyPath.To.Value", 100)
    ```
]=]
function TableManager:SetValue(path: Path, value: any): boolean
    debug.profilebegin("TM:SetValue")
    local success = self:_SetValue(path, value)
    if success then
        self:FireSignal("_ValueChange", path, value)
    end
    debug.profileend()
    return success
end

--[=[
    Increments the value at the given path by the given amount.
    If the value at the path or the given amount is not a number,
    it will throw an error. Returns the newly incremeneted value.
    ```lua
    local newValue = manager:IncrementValue("MyPath.To.Value", 100)
    ```
]=]
function TableManager:IncrementValue(path: Path, amount: Numeric): number
    local currentValue = self:GetValue(path)
    --assert(type(amount) == "number", "Increment amount must be a number!")
    --assert(type(currentValue) == "number", "Cannot increment a non-number value!")
    local newValue = currentValue + amount
    self:SetValue(path, newValue)
    return newValue
end

--[=[
    Mutates the value at the given path by calling the given function with the current value.
    The function should return the new value.
    ```lua
    manager:SetValue("MyPath.To.Value", "Hello World")

    local newValue = manager:MutateValue("MyPath.To.Value", function(currentValue)
        return string.upper(currentValue) .. "!"
    end)

    print(newValue) -- HELLO WORLD!
    print(manager:GetValue("MyPath.To.Value")) -- HELLO WORLD!
    ```
]=]
function TableManager:MutateValue(path: Path, fn: (currentValue: any) -> (any)): any
    local currentValue = self:GetValue(path)
    local newValue = fn(currentValue)
    self:SetValue(path, newValue)
    return newValue
end

--[=[
    Sets the values at the given path to the given values.
    This will fire the ValueChanged listener for each value that is different.
    :::caution
    Uses pairs to check through the given table and thus *Does not support setting values to nil*.
    :::
    ```lua
    local manager = TableManager.new({
        Foo = {
            Bar = {
                Value1 = 0;
                Value2 = 0;
                Value3 = 0;
            };
        };
    })
    
    manager:SetManyValues("Foo.Bar", {
        Value1 = 100;
        Value3 = 300;
    })
    ```
]=]
function TableManager:SetManyValues(path: Path, valueDict: {[any]: any})
    debug.profilebegin("TM:SetValues")
    path = PathToArray(path)
    for key, value in pairs(valueDict) do
        self:_SetValue(path, value, key)
    end
    self:FireSignal("_ValueBulkChange", path, valueDict)
    debug.profileend()
end

--[=[
    Mutates an index or indices in the array at the given path by calling the given function with the current value.
    @param path -- The path to the array to mutate.
    @param index number | {number} | "#" -- The index or indices to mutate. If "#" is given, it will mutate all indices.
    @param fn -- The function to call with the current value. Should return the new value.

    ```lua
    manager:SetValue("MyArray", {1, 2, 3, 4, 5})

    manager:ArrayMutate("MyArray", 3, function(currentValue)
        return currentValue * 2
    })

    print(manager:GetValue("MyArray")) -- {1, 2, 6, 4, 5}
    ```
]=]
function TableManager:ArrayMutate(path: Path, index: CanBeArray<number> | "#", fn: (currentValue: any) -> (any))
    local array = self:GetValue(path)

    if index == "#" then
        for i = 1, #array do
            local currentValue = array[i]
            local newValue = fn(currentValue)
            self:ArraySet(path, i, newValue)
        end
    else
        if typeof(index) ~= "table" then
            index = {index}
        end

        for i = 1, #index do
            local idx = index[i]
            local currentValue = array[idx]
            local newValue = fn(currentValue)
            self:ArraySet(path, idx, newValue)
        end
    end
end

--[=[
    Increments the indices at the given path by the given amount.
    @param path -- The path to the array to increment.
    @param index number | {number} -- The index or indices to increment.
    @param amount number? -- The amount to increment by. If not given, it will increment by 1.

    ```lua
    manager:SetValue("MyArray", {1, 2, 3, 4, 5})

    manager:ArrayIncrement("MyArray", 3, 10)

    print(manager:GetValue("MyArray")) -- {1, 2, 13, 4, 5}
    ```
]=]
function TableManager:ArrayIncrement(path: Path, index: CanBeArray<number> | '#', amount: Numeric?)
    debug.profilebegin("TM:ArrayIncrement")

    local arrayPath = PathToArray(path)
    local containerArray = self:GetValue(arrayPath)
    if typeof(containerArray) ~= "table" then
        warn("RawData:", self._Data)
        error(`Cannot ArrayIncrement a non-array! Value at Path: {containerArray}, Path: {PathToString(path)}`)
    end
    local containerArraySize = #containerArray

    if type(index) ~= "table" then
        if not index or index == '#' then
            index = {}
            for i = 1, containerArraySize do
                table.insert(index, i)
            end
        else
            index = {index}
        end
    end
    
    amount = amount or 1
    for i = 1, #index do
        local idx = index[i]
        assert(idx <= containerArraySize, "Index out of bounds!")

        local fullPath = table.clone(arrayPath)
        table.insert(fullPath, idx)

        local prevValue = containerArray[idx]
        local newValue = prevValue + amount
        containerArray[idx] = newValue

        self:FireSignal(ListenerTypeEnum.ArraySet, arrayPath, idx, newValue, prevValue)
        self:_FireListeners({
            Path = fullPath;
            ArrayPath = arrayPath;
            ArrayIndex = idx;
            ListenerType = ListenerTypeEnum.ArraySet;
            NewValue = newValue;
            OldValue = prevValue;
        })
    end
    debug.profileend()
end

--[=[
    Sets the value at the given index in the array at the given path.
    The index can be a number or an array of numbers. If an array is given then
    the value will be set at each of those indices in the array.
]=]
function TableManager:ArraySet(path: Path, index: (CanBeArray<number> | '#')?, value: any)
    debug.profilebegin("TM:ArraySet")

    local arrayPath = PathToArray(path)
    local containerArray = self:GetValue(arrayPath)
    if typeof(containerArray) ~= "table" then
        warn("RawData:", self._Data)
        error(`Cannot ArraySet a non-array value! Value at Path: {containerArray}, Path: {PathToString(path)}`)
    end
    local containerArraySize = #containerArray

    if type(index) ~= "table" then
        if not index or index == '#' then
            index = {}
            for i = 1, containerArraySize do
                table.insert(index, i)
            end
        else
            index = {index}
        end
    end

    for i = 1, #index do
        local idx = index[i]
        if type(idx) ~= "number" then
            error(`{tostring(idx)} is not a valid index! (Expected: 'number', Got: {typeof(idx)}`)
        elseif idx > containerArraySize then
            warn(("Index[%d] out of bounds[%d]! Consider using ArrayInsert instead."):format(idx, containerArraySize))
        end

        local prevValue = containerArray[idx]
        if prevValue == value then
            continue
        end
        containerArray[idx] = value

        local fullPath = table.clone(arrayPath)
        table.insert(fullPath, idx)

        self:FireSignal(ListenerTypeEnum.ArraySet, arrayPath, idx, value, prevValue)
        self:_FireListeners({
            Path = fullPath;
            ArrayPath = arrayPath;
            ArrayIndex = idx;
            ListenerType = ListenerTypeEnum.ArraySet;
            NewValue = value;
            OldValue = prevValue;
        })
    end
    debug.profileend()
end

--[=[
    Inserts the given value into the array at the given path at the given index.
    If no index is given, it will insert at the end of the array.
    This follows the convention of `table.insert` where the index is given in the middle
    only if there are 3 args.
    ```lua
    x:ArrayInsert("MyArray", "Hello") -- Inserts "Hello" at the end of the array
    x:ArrayInsert("MyArray", 1, "Hello") -- Inserts "Hello" at index 1
    x:ArrayInsert("MyArray", 1) -- appends 1 to the end of the array
    x:ArrayInsert("MyArray", 1, 2) -- Inserts 2 at index 1
    ```
]=]
function TableManager:ArrayInsert(path: Path, ...: any)
    debug.profilebegin("TM:ArrayInsert")
    local containerArray = self:GetValue(path)

    local argCount = select('#', ...)
    local index, value
    if argCount == 1 then
        value = ...
        index = #containerArray + 1
    elseif argCount == 2 then
        index, value = ...
    else
        error("Invalid number of arguments!")
    end

    local currentValue = containerArray[index]
    table.insert(containerArray, index, value)

    
    local arrayPath = PathToArray(path)
    local fullPath = table.clone(arrayPath)
    table.insert(fullPath, index)

    self:FireSignal(ListenerTypeEnum.ArrayInsert, arrayPath, index, value)
    self:_FireListeners({
        Path = fullPath;
        ArrayPath = arrayPath;
        ArrayIndex = index;
        ListenerType = ListenerTypeEnum.ArrayInsert;
        NewValue = value;
        OldValue = currentValue;
    })
    debug.profileend()
end

--[=[
    Removes the value at the given index from the array at the given path.
    If no index is given, it will remove the last value in the array.
    Returns the value that was removed if one was.
]=]
function TableManager:ArrayRemove(path: Path, index: number?): any
    debug.profilebegin("TM:ArrayRemove")

    local containerArray = self:GetValue(path)
    assert(index == nil or typeof(index) == "number", "Index must be a number or nil!")
    assert(typeof(containerArray) == "table", "Cannot remove from a non-array!")

    index = index or #containerArray
    local previousValue = table.remove(containerArray, index)
    local newValue = containerArray[index]

    local arrayPath = PathToArray(path)
    local fullPath = table.clone(arrayPath)
    table.insert(fullPath, index)

    self:FireSignal(ListenerTypeEnum.ArrayRemove, arrayPath, index, previousValue)
    self:_FireListeners({
        Path = fullPath;
        ArrayPath = arrayPath;
        ArrayIndex = index;
        ListenerType = ListenerTypeEnum.ArrayRemove;
        NewValue = newValue;
        OldValue = previousValue;
    })
    debug.profileend()
    return previousValue
end

--[=[
    Removes the first instance of the given value from the array at the given path.
    Returns a number indicating the index that it was was removed from if one was.
]=]
function TableManager:ArrayRemoveFirstValue(path: Path, value: any): number?
    debug.profilebegin("TM:ArrayRemoveFirstValue")
    local containerArray = self:GetValue(path)

    local index = table.find(containerArray, value)
    if index then
        local previousValue = table.remove(containerArray, index)
        local newValue = containerArray[index]

        local arrayPath = PathToArray(path)
        local fullPath = table.clone(arrayPath)
        table.insert(fullPath, index)

        self:FireSignal(ListenerTypeEnum.ArrayRemove, arrayPath, index, previousValue)
        self:_FireListeners({
            Path = fullPath;
            ArrayPath = arrayPath;
            ArrayIndex = index;
            ListenerType = ListenerTypeEnum.ArrayRemove;
            NewValue = newValue;
            OldValue = previousValue;
        })
    end
    debug.profileend()
    return index
end


-- function TableManager:ArraySwapRemove(path: Path, index: number)
--     -- TODO: Implement
-- end


-- function TableManager:ArraySwapRemoveFirstValue(path: Path, value: any)
--     -- TODO: Implement
-- end


--------------------------------------------------------------------------------
    --// Getters //--
--------------------------------------------------------------------------------

--[=[
    Fetches the value at the given path.
    Accepts a string path or an array path.
    Accepts an optional secondary argument to fetch a value at an index in an array.
    Aliases: `GetValue`

    ```lua
    local manager = TableManager.new({
        Currency = {
            Coins = 100;
            Gems = 10;
        };
    })
    
    -- The following are all equivalent acceptable methods of fetching the value.
    print(manager:Get("Currency.Coins")) -- 100
    print(manager:Get({"Currency", "Coins"})) -- 100
    print(manager:Get().Currency.Coins) -- 100
    ```
    :::note Getting the Root Table
    Calling `:Get()` with no arguments, an empty string,
    or an empty table will return the root table.
    :::
]=]
function TableManager:Get(path: Path, idx: (number | string)?): any
    --debug.profilebegin("TM:GetValue")
    path = PathToArray(path or {})

    local tblData = self._Data
    for i = 1, #path do
        if typeof(tblData) ~= "table" then
            warn("Unable to reach end of path!", path, path[i])
            return nil
        end
        tblData = tblData[path[i]]
    end

    if idx then
        if typeof(tblData) ~= "table" then
            warn("Unable to reach end of path!", path, idx)
            return nil
        end
        tblData = tblData[idx]
    end

    --debug.profileend()
    return tblData
end
TableManager.GetValue = TableManager.Get

--[=[
    Returns a <a href="https://supersocial.github.io/orion/api/TableState">TableState</a> Object for the given path.
    :::warning
    This method is not feature complete and does not work for all edge cases and should be used with caution.
    :::
    ```lua
    local path = "MyPath.To.Value"
    local state = manager:ToTableState(path)

    state:Set(100)
    manager:Increment(path, 50)
    state:Increment(25)

    print(state:Get()) -- 175
    ```
]=]
function TableManager:ToTableState(path: Path): TableState
    local stringPath = PathToString(path)
    local state = self._TableStateStorage[stringPath]
    if not state then
        state = TableState._new(self, path)
        self._TableStateStorage[stringPath] = state
        state:AddTask(function()
            self._TableStateStorage[stringPath] = nil
        end)
    end
    return state
end

--[=[
    Returns a Fusion State object that is bound to the value at the given path.
    This method is memoized so calling it repeatedly with the same path will
    return the same State object and quickly.
    :::caution Deffered Signals
    The value of the Fusion State object is updated via the ValueChanged listener
    and thus may be deffered if your signals are deffered.
    :::
    :::caution Setting
    Although this currently returns a Fusion Value object, it is not recommended to set the value
    as this may be a Computed in the future. Setting the state will not actually change the value
    in the TableManager.
    :::

    ```lua
    local path = "MyPath.To.Value"

    manager:SetValue(path, 100)
    local state = manager:ToFusionState(path)
    print(peek(state)) -- 100

    manager:SetValue(path, 200)
    task.wait() -- If your signals are deffered then the state will update on the next frame
    print(peek(state)) -- 200
    ```
]=]
function TableManager:ToFusionState(path: Path): FusionState<any>
    local pathArray = PathToArray(path)
    return self:_UpsertListenerTableForPath(ListenerTypeEnum.FusionState, pathArray) :: FusionState<any>
end

--------------------------------------------------------------------------------
    --// Listeners //--
--------------------------------------------------------------------------------

--[=[
    Creates a promise that resolves when the given condition is met. The condition is immediately and
    every time the value changes. If no condition is given then it will resolve with the current value
    unless it is nil, in which case it will resolve on the first change.
]=]
function TableManager:PromiseValue(path: Path, condition: (value: any?) -> (boolean)): Promise
    local currentValue = self:GetValue(path)
    if (not condition and currentValue ~= nil) or (condition and condition(currentValue)) then
        return Promise.resolve(currentValue)
    end

    local connection: any
    local prom = self:AddPromise(Promise.new(function(resolve, _, onCancel)
        connection = self:ListenToValueChange(path, function(...)
            if not condition or condition(...) then
                resolve(...)
            end
        end)

        onCancel(function()
            connection:Disconnect()
        end)
    end))

    prom:finally(function()
        connection:Disconnect()
    end)
    return prom
end

--[=[
    Observes a value at a path and calls the function immediately with the current value, as well as when it changes.
    :::caution Listening to nil values
    It will *NOT* fire if the new/starting value is nil, unless runOnNil is true. When it changes from nil, the oldValue will
    be the last known non nil value. The binding call of the function is an exception and will give nil as the oldValue.
    This is done so that Observe can be used to execute instructions when a value is percieved as 'ready'.
    :::

    

    @param path -- The path to the value to observe.
    @param fn -- The function to call when the value changes.
    @param runOnNil -- Whether or not to fire the function when the value is nil.

    @return Connection -- A connection used to disconnect the listener.

    ```lua
    local path = "MyPath.To.Value"
    local connection = manager:Observe(path, function(newValue)
        print("Value at", path, "is", newValue)
    end)

    connection() -- Disconnects the listener
    ```
]=]
function TableManager:Observe(path: Path, fn: ValueListenerFn, runOnNil: boolean?): Connection
    AssertPathIsValid(path)
    AssertFnExists(fn)

    local fakeOldValue = self:GetValue(path)
    local connection = self:ListenToValueChange(path, function(newValue, _, metadata)
        if newValue ~= fakeOldValue or typeof(newValue) == "table" then
            if newValue ~= nil or runOnNil == true then
                fn(newValue, fakeOldValue, metadata)
                fakeOldValue = newValue
            end
        end
    end)

    if fakeOldValue ~= nil or runOnNil == true then
        fn(fakeOldValue, nil, nil)
    end

    return connection
end


--[=[
    Listens to a change at a specified path and calls the function when the value changes.

    ```lua
    manager:Set("Stats", {
        Health = 100;
        Mana = 50;
    })

    local connection = manager:ListenToKeyChange("Stats", function(key, newValue)
        print(`{key} changed to {newValue}`)
    end)

    manager:SetValue("Stats.Health", 200) -- Health changed to 200
    manager:SetValue("Stats.Mana", 100) -- Mana changed to 100
    ```
]=]
function TableManager:ListenToKeyChange(parentPath: Path?, fn: (keyChanged: any, newValue: any, oldValue: any) -> ())
    AssertPathIsValid(parentPath)
    AssertFnExists(fn)
    
    local lastRecorded = self:Get(parentPath)
    if type(lastRecorded) ~= "table" then
        lastRecorded = {}
    else
        lastRecorded = table.clone(lastRecorded)
    end

    return self:_AddToListeners(ListenerTypeEnum.ValueChanged, parentPath, function(newTbl, _, _)
        -- TODO: This should be optimized to only check the keys that may have changed.
        if type(newTbl) ~= "table" then
            newTbl = {}
        else
            newTbl = table.clone(newTbl)
        end

        local diffs = {}
        for key, newValue in pairs(newTbl) do
            local oldValue = lastRecorded[key]
            if oldValue ~= newValue or type(newValue) == "table" then
                diffs[key] = {newValue, oldValue}
            end
        end

        for key, oldValue in pairs(lastRecorded) do
            local newValue = newTbl[key]
            if oldValue ~= newValue then
                diffs[key] = {newValue, oldValue}
            end
        end

        for key, diff in pairs(diffs) do
            fn(key, diff[1], diff[2])
        end

        lastRecorded = newTbl

        -- local isChildKey = (metadata.SourceDirection == DataChangeSourceEnum.ChildChanged) and (#pathArray == #metadata.SourcePath - 1)
        -- if isChildKey then
        --     local keyThatChanged = metadata.SourcePath[#metadata.SourcePath]
        --     fn(keyThatChanged, metadata.NewValue, metadata.OldValue)
        -- end
    end)
end

--[=[
    Listens to when a new key is added (Changed from nil) to a table at a specified path and calls the function.
]=]
function TableManager:ListenToKeyAdd(parentPath: Path?, fn: (newKey: any, newValue: any) -> ()): Connection
    return self:ListenToKeyChange(parentPath, function(key, newValue, oldValue)
        if oldValue == nil then
            fn(key, newValue)
        end
    end)
end
TableManager.ListenToKeyAdded = TableManager.ListenToKeyAdd
TableManager.ListenToNewKey = TableManager.ListenToKeyAdd

--[=[
    Listens to when a key is removed (Set to nil) from a table at a specified path and calls the function.
]=]
function TableManager:ListenToKeyRemove(parentPath: Path?, fn: (removedKey: any, lastValue: any) -> ()): Connection
    return self:ListenToKeyChange(parentPath, function(key, newValue, _)
        if newValue == nil then
            fn(key, newValue)
        end
    end)
end
TableManager.ListenToKeyRemoved = TableManager.ListenToKeyRemove
TableManager.ListenToRemoveKey = TableManager.ListenToKeyRemove

--[=[
    Listens to a change at a specified path and calls the function when the value changes.
    This does NOT fire when the value is an array/dictionary and one of its children changes.
    ```lua
    local connection = manager:ListenToValueChange("MyPath.To.Value", function(newValue, oldValue)
        print("Value changed from", oldValue, "to", newValue)
    end)

    connection() -- Disconnects the listener
    ```
]=]
function TableManager:ListenToValueChange(path: Path, fn: ValueListenerFn): Connection
    AssertPathIsValid(path)
    AssertFnExists(fn)
    return self:_AddToListeners(ListenerTypeEnum.ValueChanged, path, fn)
end

--[=[
    Listens to when an index is set in an array at a specified path and calls the function.
    The function receives the index and the new value.
    :::caution
    The array listeners do not fire from changes to parent or child values.
    :::
]=]
function TableManager:ListenToArraySet(path: Path, fn: (changedIndex: number, newValue: any) -> ()): Connection
    AssertPathIsValid(path)
    AssertFnExists(fn)
    return self:_AddToListeners(ListenerTypeEnum.ArraySet, path, fn)
end

--[=[
    Listens to when a value is inserted into an array at a specified path and calls the function when the value changes.
]=]
function TableManager:ListenToArrayInsert(path: Path, fn: (changedIndex: number, newValue: any) -> ()): Connection
    AssertPathIsValid(path)
    AssertFnExists(fn)
    return self:_AddToListeners(ListenerTypeEnum.ArrayInsert, path, fn)
end


--[=[
    Listens to when a value is removed from an array at a specified path and calls the function.
]=]
function TableManager:ListenToArrayRemove(path: Path, fn: (oldIndex: number, oldValue: any) -> ()): Connection
    AssertPathIsValid(path)
    AssertFnExists(fn)
    return self:_AddToListeners(ListenerTypeEnum.ArrayRemove, path, fn)
end


-- function TableManager:GetValueChangedSignal(path: Path): Signal
--     local listeners = self:_UpsertListenerTableForPath(ListenerTypeEnum.ValueChanged, PathToArray(path))
--     return listeners[ListenerTypeEnum.ValueChanged]
-- end


--------------------------------------------------------------------------------
    --// Private //--
--------------------------------------------------------------------------------

--[=[
    @private
    Gets the top level table being managed by this TableManager.
]=]
function TableManager:_GetRawData()
    return self._Data
end

--[=[
    @private
]=]
function TableManager:_AddToListeners(listenerType: ListenerType, path: Path, listenerFn: (...any) -> ()): Connection
    AssertFnExists(listenerFn)

    path = path or {}
    local pathArray = PathToArray(path)

    local listenerSignal = self:_UpsertListenerTableForPath(listenerType, pathArray)
    
    if listenerType == ListenerTypeEnum.ValueChanged then
        local lastValue = self:Get(path)
        return listenerSignal:Connect(function(newValue, metadata)
            if newValue ~= lastValue or typeof(newValue) == "table" then
                listenerFn(newValue, lastValue, metadata)
                lastValue = newValue
            end
        end)

    else
        return listenerSignal:Connect(listenerFn)
        -- if listenerType == ListenerTypeEnum.ArraySet then
        --     return listenerSignal:Connect(listenerFn)
        -- elseif listenerType == ListenerTypeEnum.ArrayInsert then
        --     return listenerSignal:Connect(listenerFn)
        -- elseif listenerType == ListenerTypeEnum.ArrayRemove then
        --     return listenerSignal:Connect(listenerFn)
        -- end
    end
end

--[=[
    @private
    Creates a listener table for the given path if it doesn't exist.
    Returns the listener table.
]=]
function TableManager:_UpsertListenerTableForPath(listenerType: ListenerType, pathArray: PathArray): {[any]: any}
    local listeners = self._Listeners :: ListenerContainer

    for i = 1, #pathArray do
        local currentPathKey = pathArray[i]
        local listenersForKey = listeners[ChildListeners][currentPathKey]
        if listenersForKey == nil then
            listenersForKey = {[ChildListeners] = (setmetatable({}, WEAK_MT) :: any) :: ListenerContainer}
            listeners[ChildListeners][currentPathKey] = listenersForKey
        end
        listeners = listenersForKey
    end
    
    local listenerTypeTable = listeners[listenerType]
    if listenerTypeTable == nil then
        if listenerType == ListenerTypeEnum.FusionState then
            if not self._FScope then
                self._FScope = Fusion.scoped()
                self:AddTask(function()
                    Fusion.doCleanup(self._FScope)
                end)
            end
            listenerTypeTable = Fusion.Value(self._FScope, self:Get(pathArray))
            self:ListenToValueChange(pathArray, function(newValue)
                listenerTypeTable:set(newValue)
            end)
        else
            listenerTypeTable = self:AddTask(Signal.new())
        end
        listeners[listenerType] = listenerTypeTable
    end

    return listenerTypeTable
end

--[=[
    @private
    Gets the listener signal for the given path if it exists.
]=]
function TableManager:_GetListenerSignalForPath(listenerType: ListenerType, pathArray: PathArray): SignalInternal?
    local listeners = self._Listeners :: ListenerContainer

    for i = 1, #pathArray do
        local currentPathKey = pathArray[i]
        local listenersForKey = listeners[ChildListeners][currentPathKey]
        if listenersForKey == nil then
            return nil
        end
        listeners = listenersForKey
    end

    return listeners[listenerType] :: SignalInternal?
end

--[=[
    @private
    Fires listeners for the given path.
    Takes a bunch of props to make processing less intensive. I want to improve performance for this.
]=]
function TableManager:_FireListeners(props: {
    Path: {string};
    ArrayPath: {string}?;
    ArrayIndex: number?;
    ListenerType: ListenerType;
    ListenerContainer: ListenerContainer?;
    NewValue: any;
    OldValue: any;
})

    local FIRE_CHILD_LISTENERS = self.FIRE_CHILD_LISTENERS
    local FIRE_PARENT_LISTENERS = self.FIRE_PARENT_LISTENERS

    local path = props.Path
    local newValue = props.NewValue
    local oldValue = props.OldValue
    local listenerType = props.ListenerType
    local listenerContainer = props.ListenerContainer

    local metadata = table.freeze {
        ListenerType = listenerType;
        SourcePath = path;
        SourceDirection = DataChangeSourceEnum.SelfChanged;
        NewValue = newValue;
        OldValue = oldValue;
    }

    if FIRE_PARENT_LISTENERS then
        listenerContainer = self:_FireParentListeners(metadata)
    end

    if listenerType ~= ListenerTypeEnum.ValueChanged then
        local listenerSignal = self:_GetListenerSignalForPath(listenerType, props.ArrayPath) :: SignalInternal?
        if listenerSignal and listenerSignal._head then -- check if atleast one listener is connected
            if listenerType == ListenerTypeEnum.ArraySet then
                listenerSignal:Fire(props.ArrayIndex, newValue, metadata)
            elseif listenerType == ListenerTypeEnum.ArrayInsert then
                listenerSignal:Fire(props.ArrayIndex, newValue, metadata)
            elseif listenerType == ListenerTypeEnum.ArrayRemove then
                listenerSignal:Fire(props.ArrayIndex, oldValue, metadata)
            end
        else
            if self.DEBUG then
                warn("No listeners found for", listenerType, listenerSignal, props.ArrayPath, self._Listeners)
            end
        end
    end

    if listenerContainer then -- this will be nil if there are no deeper listeners
        --print("Firing Main Listeners", listenerContainer)
        local listenerSignal = listenerContainer[ListenerTypeEnum.ValueChanged] :: SignalInternal?
        if listenerSignal and listenerSignal._head then -- check if atleast one listener is connected
            listenerSignal:Fire(newValue, metadata)
        end
        
        if FIRE_CHILD_LISTENERS then
            self:_FireChildListeners(metadata, listenerContainer)
        end
    else
        if self.DEBUG then
            warn("No Listener Container found for", path, listenerType, self._Listeners)
        end
    end
    
end

--[=[
    @private
    Fires child listeners for the given path.
]=]
function TableManager:_FireChildListeners(_metadata: ChangeMetadata, _listenerContainer: ListenerContainer)
    --print("Firing Child Listeners")

    local metadata = {
        ListenerType = _metadata.ListenerType;
        SourcePath = _metadata.SourcePath;
        SourceDirection = DataChangeSourceEnum.ParentChanged;
        NewValue = _metadata.NewValue;
        OldValue = _metadata.OldValue;
    }

    local function FireChildren(listenerContainer, newSubValue)
        local subListeners = listenerContainer.ChildListeners
        if subListeners then
            for key, subListenerContainer in pairs(subListeners) do -- for any listeners of child keys
                local subData = if newSubValue and typeof(newSubValue) == "table" then newSubValue[key] else nil

                local listenerSignal = subListenerContainer[ListenerTypeEnum.ValueChanged] :: SignalInternal?
                if listenerSignal and listenerSignal._head then -- check if atleast one listener is connected
                    listenerSignal:Fire(subData, metadata)
                end

                FireChildren(subListenerContainer, subData)
            end
        end
    end

    FireChildren(_listenerContainer, metadata.NewValue)
end

--[=[
    @private
    Fires parent listeners for the given path.
]=]
function TableManager:_FireParentListeners(_metadata: ChangeMetadata): ListenerContainer?
    --print("Firing Parent Listeners")
    local path = _metadata.SourcePath or {}
    local arrayPath = PathToArray(path)

    local listenerContainer = self._Listeners
    local parentInfoList = {}

    local parentTable: any, key: string = self, "_Data"
    local currentValue = parentTable[key]

    for i = 1, #arrayPath do
        key = arrayPath[i]
        parentTable = currentValue
        currentValue = parentTable[key]

        local valueChangedListenerSignal = listenerContainer[ListenerTypeEnum.ValueChanged] :: SignalInternal?
        if valueChangedListenerSignal then
            table.insert(parentInfoList, {parentTable, valueChangedListenerSignal})
        end
        
        local listenersForKey = listenerContainer[ChildListeners][key]
        if listenersForKey ~= nil then
            listenerContainer = listenersForKey
            --print("Found Listener Container for", key)
        else
            listenerContainer = nil
            --print("No listeners found for", key)
            break
        end
    end

    local metadata = {
        ListenerType = _metadata.ListenerType;
        SourcePath = arrayPath;
        SourceDirection = DataChangeSourceEnum.ChildChanged;
        NewValue = _metadata.NewValue;
        OldValue = _metadata.OldValue;
    }

    for _, parentData in parentInfoList do
        local parentListenerSignal = parentData[2] :: SignalInternal?
        if parentListenerSignal and parentListenerSignal._head then -- check if atleast one listener is connected
            parentListenerSignal:Fire(
                parentData[1], -- Parent Value Table
                metadata
            )
        end
    end

    return listenerContainer
end


--[=[
    @private
]=]
function TableManager:_SetValue(path: Path, newValue: any, lastKey: (string)?)
    debug.profilebegin("TM:_SetValue")

    local arrayPath = PathToArray(path or {})
    if lastKey then
        arrayPath = table.clone(arrayPath)
        table.insert(arrayPath, lastKey)
    end

    -------------------------------------------------------

    local listenerType = ListenerTypeEnum.ValueChanged
    
    local parentTable: any, key: string = self, "_Data"
    local currentValue = parentTable[key]

    local listenerContainer = self._Listeners

    for i = 1, #arrayPath do
        key = arrayPath[i]
        parentTable = currentValue
        currentValue = parentTable[key]

        local listenersForKey = listenerContainer[ChildListeners][key]
        if listenersForKey ~= nil then
            listenerContainer = listenersForKey
        end
    end
    
    -------------------------------------------------------
    local DidChange = false

    if currentValue ~= newValue or typeof(newValue) == "table" then
        DidChange = true

        if parentTable == self then
            warn("[TableManager] Overwriting value of root table!", self._Data, "->", newValue, if self.DEBUG then "\n"..debug.traceback() else "")
        end

        parentTable[key] = newValue -- ! Actual Data Set Point !

        -- This needs to fire first so that replication happens in the proper order.
        self:FireSignal(listenerType, arrayPath, newValue, currentValue)

        self:_FireListeners({
            Path = arrayPath;
            ListenerType = listenerType;
            ListenerContainer = listenerContainer;
            NewValue = newValue;
            OldValue = currentValue;
        })
    end

    debug.profileend()
    return DidChange
end


export type TableManager = typeof(TableManager.new({}))

return TableManager