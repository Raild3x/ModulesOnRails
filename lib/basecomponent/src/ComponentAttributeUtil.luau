--!strict
-- Authors: Logan Hunt [Raildex]
-- April 19, 2023
--[=[
    @class ComponentAttributeUtil
    @ignore

    This component extension provides easy access to a component's attributes.
]=]

--[[ API
    :DefaultAttribute(attributeName: string, value: any, validTypes: {string}?) -> (any)
    :SetAttribute(attributeName: string, value: any) -> ()
    :GetAttribute(attributeName: string) -> (any | nil)
    :OutAttribute(attributeName: string) -> (Value<any>)
    :IncrementAttribute(attributeName: string, increment: number) -> (number)
    :MutateAttribute<T>(attributeName: string, mutator: (value: any) -> (T)) -> (T)
    :ObserveAttribute(attributeName: string, callback: (newValue: any) -> ()) -> () -> ()
    :AttributeChanged(attributeName: string, fn: ((...any) -> ())?) -> (RBXScriptConnection | RBXScriptSignal)
]]

--// Requires //--
local Packages = script.Parent.Parent
local Fusion = require(Packages.Fusion)
local Util = require(Packages.RailUtil)
local Symbol = require(Packages.Symbol)

--// Types //--
type Component = any
type Value<T> = Fusion.Value<T, T>

export type Extension = {
    SetAttribute: (self: Extension, attributeName: string, value: any) -> (),
    GetAttribute: (self: Extension, attributeName: string) -> (any | nil),
    OutAttribute: (self: Extension, attributeName: string) -> (Value<any>),
    IncrementAttribute: (self: Extension, attributeName: string, increment: number) -> (number),
    MutateAttribute: <T>(self: Extension, attributeName: string, mutator: (value: any) -> (T)) -> (T),
    ObserveAttribute: (self: Extension, attributeName: string, callback: (newValue: any) -> ()) -> () -> (),
    DefaultAttribute: (self: Extension, attributeName: string, value: any, validTypes: {string}?) -> (any),
}

--// Constants //--
local ATTRIBUTE_CONNECTIONS = Symbol("AttributeConnections")
local ATTRIBUTE_VALUES = Symbol("AttributeValues")
local ATTRIBUTE_FUSION_SCOPE = Symbol("AttributeFusionScope")
local ATTRIBUTE_SOURCE = "Instance"

--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

--[=[
    @within BaseComponent
    @method GetAttribute

    Fetches the current Value of an attribute on the Component Instance

    @param attributeName string -- The name of the attribute to fetch
    @return any? -- The current value of the attribute
]=]
local function GetAttribute(self: Component, attributeName: string): (any | nil)
    local attributeValue = self[ATTRIBUTE_SOURCE]:GetAttribute(attributeName)
    return if attributeValue ~= nil then attributeValue else nil
end

--[=[
    @within BaseComponent
    @method SetAttribute

    Sets an attribute of this Component's instance to a value

    @param attributeName string -- The name of the attribute to set
    @param value any -- The value to set the attribute to
]=]
local function SetAttribute(self: Component, attributeName: string, value: any)
    self[ATTRIBUTE_SOURCE]:SetAttribute(attributeName, value)
end

--[=[
    @within BaseComponent
    @method IncrementAttribute

    Increments the current value of the attribute by the increment. If no increment is provided, it defaults to 1

    @param attributeName string -- The name of the attribute to increment
    @param increment number? -- The amount to increment the attribute by. Defaults to 1
    @return number -- The new value of the attribute
]=]
local function IncrementAttribute(self: Component, attributeName: string, increment: number?): (number)
    local value = GetAttribute(self, attributeName) or 0
    assert(typeof(value) == "number", "Attempted to increment a non-number attribute")
    local newValue = value + (increment or 1)
    SetAttribute(self, attributeName, newValue)
    return newValue
end

--[=[
    @within BaseComponent
    @method UpdateAttribute

    Updates the current value of the attribute into a new value from the return of the mutator function

    @param attributeName string -- The name of the attribute to mutate
    @param mutator ((value: any) -> (any)) -- The function to mutate the attribute with
    @return any -- The new value of the attribute
]=]
local function UpdateAttribute<T>(self: Component, attributeName: string, mutator: (value: any) -> (T)): (T)
    local value = GetAttribute(self, attributeName)
    local newValue = mutator(value)
    SetAttribute(self, attributeName, newValue)
    return newValue
end

--[=[
    @within BaseComponent
    @method ObserveAttribute

    Watches for when the attribute changes and calls the callback. Also calls the callback initially with the current value

    @param attributeName string -- The name of the attribute to observe
    @param callback ((newValue: any) -> ()) -- The function to call when the attribute changes
    @return function -- A function to disconnect the observer
]=]
local function ObserveAttribute(self: Component, attributeName: string, callback: (newValue: any) -> ()): () -> ()
    local instance: Instance = self[ATTRIBUTE_SOURCE]
    local connection = instance:GetAttributeChangedSignal(attributeName):Connect(function()
        callback(GetAttribute(self, attributeName))
    end)
    table.insert(self[ATTRIBUTE_CONNECTIONS], connection)
    callback(GetAttribute(self, attributeName))
    return function()
        if not connection.Connected then
            return
        end

        Util.Table.SwapRemoveFirstValue(self[ATTRIBUTE_CONNECTIONS], connection)
        connection:Disconnect()
    end
end

--[=[
    @within BaseComponent
    @method OutAttribute

    Fetches an attribute and turns into into a synchronized usable value

    @param attributeName string -- The name of the attribute to fetch
    @return Value<any> -- The synchronized fusion value of the attribute
]=]
local function OutAttribute(self: Component, attributeName: string): (Value<any, any>)
    if not self[ATTRIBUTE_VALUES][attributeName] then
        local value = Fusion.Value(self[ATTRIBUTE_FUSION_SCOPE], GetAttribute(self, attributeName))

        ObserveAttribute(self, attributeName, function(newValue)
            value:set(newValue)
        end)

        table.insert(self[ATTRIBUTE_CONNECTIONS], Fusion.Observer(self[ATTRIBUTE_FUSION_SCOPE], value):onChange(function()
            SetAttribute(self, attributeName, Fusion.peek(value))
        end))

        self[ATTRIBUTE_VALUES][attributeName] = value
    end
    return self[ATTRIBUTE_VALUES][attributeName]
end

-- Sets an attribute to a default value if it is not already set, allows for type checking of the initial value
--[=[
    @within BaseComponent
    @method DefaultAttribute

    Sets an attribute to a default value if it is not already set, allows for type checking of the initial value


    @param attributeName string -- The name of the attribute to set
    @param value any -- The value to set the attribute to
    @param validDataTypes {string}? -- A list of valid data types for the attribute
    @return any -- The value of the attribute
]=]
local function DefaultAttribute(self: Component, attributeName: string, value: any, validDataTypes: {string}?): (any)
    local currentValue = GetAttribute(self, attributeName)
    if currentValue == nil then
        SetAttribute(self, attributeName, value)
        return value
    elseif validDataTypes then
        local dataType = typeof(currentValue)
        assert(
            table.find(validDataTypes, dataType),
            `{self[ATTRIBUTE_SOURCE]:GetFullName()} Attribute {attributeName} is not of a valid type. Expected [{table.concat(validDataTypes, ", ")}], got {dataType}`
        )
    end
    return currentValue
end


--[=[
    @within BaseComponent
    @method AttributeChanged

    Fetches the AttributeChanged signal for the attribute if no function is given.
    If a function is provided, it will connect the function to the attribute changed signal and return the connection

    @param attributeName string -- The name of the attribute to observe
    @param fn ((...any) -> ())? -- The function to call when the attribute changes
    @return RBXScriptConnection | RBXScriptSignal -- A function to disconnect the observer or the signal
]=]
local function AttributeChanged(self: Component, attributeName: string, fn: ((...any) -> ())?): RBXScriptConnection | RBXScriptSignal
    local sig = self[ATTRIBUTE_SOURCE]:GetAttributeChangedSignal(attributeName)
    if fn then
        local conn = sig:Connect(fn)
        table.insert(self[ATTRIBUTE_CONNECTIONS], conn)
        return conn
    end
    return sig
end


local UtilMethods = {
    SetAttribute = SetAttribute,
    GetAttribute = GetAttribute,
    OutAttribute = OutAttribute,
    IncrementAttribute = IncrementAttribute,
    UpdateAttribute = UpdateAttribute,
    MutateAttribute = UpdateAttribute,
    ObserveAttribute = ObserveAttribute,
    DefaultAttribute = DefaultAttribute,
    AttributeChanged = AttributeChanged,
}

--------------------------------------------------------------------------------
    --// Extension //--
--------------------------------------------------------------------------------

local ComponentAttributeUtilExtension = {}
ComponentAttributeUtilExtension.ClassName = "ComponentAttributeUtil"
ComponentAttributeUtilExtension.Methods = UtilMethods

--[=[
    @within ComponentAttributeUtil
    @ignore
    @param component Component
]=]
function ComponentAttributeUtilExtension.Constructing(component)
    component[ATTRIBUTE_CONNECTIONS] = {}
    component[ATTRIBUTE_VALUES] = {}
    component[ATTRIBUTE_FUSION_SCOPE] = Fusion.scoped()
end

--[=[
    @within ComponentAttributeUtil
    @ignore
    @param component Component
]=]
function ComponentAttributeUtilExtension.Stopped(component)
    for _, connection: RBXScriptConnection | () -> () in component[ATTRIBUTE_CONNECTIONS] do
        if typeof(connection) == "function" then
            connection()
        elseif connection.Connected then
            connection:Disconnect()
        end
    end

    Fusion.doCleanup(component[ATTRIBUTE_FUSION_SCOPE])

    component[ATTRIBUTE_VALUES] = nil
    component[ATTRIBUTE_CONNECTIONS] = nil
    component[ATTRIBUTE_FUSION_SCOPE] = nil
end



return ComponentAttributeUtilExtension