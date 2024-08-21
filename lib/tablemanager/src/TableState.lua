-- Authors: Logan Hunt (Raildex)
-- January 10, 2024
--[=[
    @class TableState

    This class is used to observe and modify values in a TableManager easier.
    It is not feature complete and is subject to change.
]=]

--// Imports //--
local SuperClass = require(script.Parent.Parent.BaseObject)
type TableManager = any
type CanBeArray<T> = T | {T}
type Path = any

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local TableState = setmetatable({}, SuperClass)
TableState.ClassName = "TableState"
TableState.__index = TableState

--[=[
    Creates a new TableState. This is used to observe and modify values in a TableManager easier.
    Equivalent to `tblMngr:ToState(Path)`
    ```lua
    local tbl = {
        Coins = 0;
        Inventory = {
            "Sword";
            "Shield";
        };
    }

    local tblMngr = TableManager.new(tbl)

    local coinsState = TableState.new(tblMngr, "Coins")
    print( coinsState == tblMngr:ToTableState("Coins") ) -- true

    coinsState:Set(100) -- equivalent to `tblMngr:SetValue("Coins", 100)`

    local inventoryState = TableState.new(tblMngr, "Inventory")
    inventoryState:Insert("Potion") -- equivalent to `tblMngr:ArrayInsert("Inventory", "Potion")`
    ```
    :::warning States with array values
    You should avoid setting states to be a particular index in array because if the array is shifted
    then the state can potentially be pointing to the wrong value.
    :::
]=]
function TableState.new(manager: TableManager, Path: Path): TableState
    return manager:ToTableState(Path) -- Registers the state to the manager and then calls ._new()
end

--[=[
    @private
]=]
function TableState._new(manager: TableManager, Path: Path)
    local self = setmetatable(SuperClass.new(), TableState)

    self._Manager = manager
    self._ArrayPath = TableManager.PathToTable(Path)

    self._RawValue = self._Manager:Get(self._ArrayPath)

    self:RegisterSignal("Changed")
    self:RegisterSignal("ArraySet")
    self:RegisterSignal("ArrayInsert")
    self:RegisterSignal("ArrayRemove")

    self:AddTask(self._Manager:ListenToValueChange(self._ArrayPath, function(new, old)
        self._RawValue = new
        self:FireSignal("Changed", new, old)
    end))

    self:AddTask(self._Manager:ListenToArraySet(self._ArrayPath, function(index, new, old)
        self:FireSignal("ArraySet", index, new, old)
    end))

    self:AddTask(self._Manager:ListenToArrayInsert(self._ArrayPath, function(index, value)
        self:FireSignal("ArrayInsert", index, value)
    end))

    self:AddTask(self._Manager:ListenToArrayRemove(self._ArrayPath, function(index, value)
        self:FireSignal("ArrayRemove", index, value)
    end))


    self:AddTask(self._Manager:GetDestroyedSignal():Once(function()
        self:Destroy()
    end))
    
    return self
end

--[=[
    Sets the value this state is associated with.
    ```lua
    :Set(999) -- Sets the value itself to 999
    :Set(1, 999) -- Sets the value at index 1 to 999 (State must be an array)
    ```
]=]
function TableState:Set(...: any)
    self._Manager:Set(self._ArrayPath, ...)
end


--[=[
    Gets the value this state is associated with.
    Takes an optional argument to specify the index of the array to get.
    ```lua
    :Get() -- Gets the value itself
    :Get(1) -- Gets the value at index 1 of the state (State must be an array) (Equivalent to :Get()[1])
    ```
]=]
function TableState:Get(index: number?): any
    return if index then self._RawValue[index] else self._RawValue;
end

--[=[
    Increments the value this state is associated with.
    ```lua
    :Increment(999) -- Increments the value itself by 999
    :Increment(1, 999) -- Increments the value at index 1 by 999 (State must be an array)
    ```
]=]
function TableState:Increment(...: any): any
    return self._Manager:Increment(self._ArrayPath, ...)
end

--[=[
    Inserts a value into the array this state is associated with.
    ```lua
    :Insert(999) -- Appends 999 onto the array
    :Insert(5, 999) -- Inserts 999 at index 5 of the array
    ```
]=]
function TableState:Insert(...: any)
    self._Manager:ArrayInsert(self._ArrayPath, ...)
end

--[=[
    Removes the value at the given index from the array this state is associated with.
    @return any -- The removed value.
]=]
function TableState:Remove(index: number): any
    return self._Manager:ArrayRemove(self._ArrayPath, index)
end

--[=[
    Removes the first value that matches the given value from the array this state is associated with.
    @return number -- The index of the removed value.
]=]
function TableState:RemoveFirstValue(valueToFind: any): number?
    return self._Manager:ArrayRemoveFirstValue(self._ArrayPath, valueToFind)
end

--[=[
    Observes changes to the value this state is associated with. Also fires immediately.
    See [TableManager:Observe](TableManager.md#observe) for more information.
]=]
function TableState:Observe(fn: (new: any) -> ()): (() -> ())
    return self:AddTask(self._Manager:Observe(self._ArrayPath, fn))
end


export type TableState = typeof(TableState.new({}, {}))

return TableState