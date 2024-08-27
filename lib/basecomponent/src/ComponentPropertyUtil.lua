--!strict
-- Authors: Logan Hunt [Raildex]
-- May 10, 2024
--[=[
    @class ComponentPropertyUtil
    @ignore

    This component extension provides easy access to a component's propertys.
]=]

--[[ API
    :OutProperty(propertyName: string) -> (Value<any>)
    :ObserveProperty(propertyName: string, callback: (newValue: any) -> ()) -> () -> ()
    :PropertyChanged(propertyName: string, fn: ((...any) -> ())?) -> (RBXScriptConnection | RBXScriptSignal)
]]

--// Requires //--
local Packages = script.Parent.Parent
local Symbol = require(Packages.Symbol)
local Util = require(Packages.RailUtil)
local Fusion = require(Packages.Fusion)

--// Types //--
type Value<T> = Fusion.Value<T>
type Component = any

export type Extension = {
    OutProperty: (self: Extension, propertyName: string) -> (Value<any>),
    ObserveProperty: (self: Extension, propertyName: string, callback: (newValue: any) -> ()) -> () -> (),
    PropertyChanged: (self: Extension, propertyName: string, fn: ((...any) -> ())?) -> (RBXScriptConnection | RBXScriptSignal),
}

--// Constants //--
local PROPERTY_CONNECTIONS = Symbol("PropertyConnections")
local PROPERTY_VALUES = Symbol("PropertyValues")
local PROPERTY_FUSION_SCOPE = Symbol("PropertyFusionScope")
local PROPERTY_SOURCE = "Instance"

--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

--[=[
    @within BaseComponent
    @method ObserveProperty

    Watches for when the property changes and calls the callback. Also calls the callback initially with the current value

    @param propertyName string -- The name of the property to observe
    @param callback ((newValue: any) -> ()) -- The function to call when the property changes
    @return function -- A function to disconnect the observer
]=]
local function ObserveProperty(self: Component, propertyName: string, callback: (newValue: any) -> ()): () -> ()
    local instance: Instance = self[PROPERTY_SOURCE]
    local connection = instance:GetPropertyChangedSignal(propertyName):Connect(function()
        callback(self[PROPERTY_SOURCE][propertyName])
    end)
    table.insert(self[PROPERTY_CONNECTIONS], connection)
    task.spawn(callback, self[PROPERTY_SOURCE][propertyName])
    return function()
        if not connection.Connected then
            --warn(`ObserveProperty: "{propertyName}" has already been disconnected!`)
            return
        end

        Util.Table.SwapRemoveFirstValue(self[PROPERTY_CONNECTIONS], connection)
        connection:Disconnect()
    end
end

--[=[
    @within BaseComponent
    @method OutProperty

    Fetches an property and turns into into a synchronized usable value

    @param propertyName string -- The name of the property to fetch
    @return Value<any> -- The synchronized fusion value of the property
]=]
local function OutProperty(self: Component, propertyName: string): (Value<any>)
    if not self[PROPERTY_VALUES][propertyName] then
        local value = Fusion.Value(self[PROPERTY_FUSION_SCOPE], self[PROPERTY_SOURCE][propertyName])

        ObserveProperty(self, propertyName, function(newValue)
            value:set(newValue)
        end)

        table.insert(self[PROPERTY_CONNECTIONS], Fusion.Observer(self[PROPERTY_FUSION_SCOPE], value):onChange(function()
            self[PROPERTY_SOURCE][propertyName] = Fusion.peek(value)
        end))

        self[PROPERTY_VALUES][propertyName] = value
    end
    return self[PROPERTY_VALUES][propertyName]
end


--[=[
    @within BaseComponent
    @method PropertyChanged

    Fetches the PropertyChanged signal for the property if no function is given.
    If a function is provided, it will connect the function to the property changed signal and return the connection

    @param propertyName string -- The name of the property to observe
    @param fn ((...any) -> ())? -- The function to call when the property changes
    @param connectOnce boolean? -- If true, the function will only be called the first time the property changes
    @return RBXScriptConnection | RBXScriptSignal -- A connection or signal
]=]
local function PropertyChanged(self: Component, propertyName: string, fn: ((...any) -> ())?, connectOnce: boolean?): RBXScriptConnection | RBXScriptSignal
    local sig = self[PROPERTY_SOURCE]:GetPropertyChangedSignal(propertyName)
    if fn then
        local conn
        if connectOnce then
            conn = sig:Once(fn)
        else
            conn = sig:Connect(fn)
        end
        table.insert(self[PROPERTY_CONNECTIONS], conn)
        return conn
    end
    return sig
end


local UtilMethods = {
    OutProperty = OutProperty,
    ObserveProperty = ObserveProperty,
    PropertyChanged = PropertyChanged,
}

--------------------------------------------------------------------------------
    --// Extension //--
--------------------------------------------------------------------------------

local ComponentPropertyUtilExtension = {}
ComponentPropertyUtilExtension.ClassName = "ComponentPropertyUtil"
ComponentPropertyUtilExtension.Methods = UtilMethods

--[=[
    @within ComponentPropertyUtil
    @ignore
    @param component Component
]=]
function ComponentPropertyUtilExtension.Constructing(component)
    component[PROPERTY_CONNECTIONS] = {}
    component[PROPERTY_VALUES] = {}
    component[PROPERTY_FUSION_SCOPE] = Fusion.scoped()
end

--[=[
    @within ComponentPropertyUtil
    @ignore
    @param component Component
]=]
function ComponentPropertyUtilExtension.Stopped(component)
    for _, connection: RBXScriptConnection | () -> () in component[PROPERTY_CONNECTIONS] do
        if typeof(connection) == "function" then
            connection()
        elseif connection.Connected then
            connection:Disconnect()
        end
    end

    Fusion.doCleanup(component[PROPERTY_FUSION_SCOPE])

    component[PROPERTY_VALUES] = nil
    component[PROPERTY_CONNECTIONS] = nil
    component[PROPERTY_FUSION_SCOPE] = nil
end



return ComponentPropertyUtilExtension