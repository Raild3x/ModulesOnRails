--!strict
-- Authors: Logan Hunt [Raildex]
-- February 15, 2023
--[=[
    @class BaseComponent

    A Component Extension which applies simple Janitor, Attribute, and Signal functionality to a component.
    Also adds a way to check if a Component has been destroyed.

    Extends **ComponentJanitorUtil** and **ComponentAttributeUtil**.
    Check their documentation for more information.

]=]

--[[ API
    .Signals: {
        Destroyed: Signal;
    }

    :RegisterSignal(SignalName: string) -> Signal
    :GetSignal(SignalName: string) -> Signal
    :IsDestroyed() -> boolean
]]


--// Requires //--
local Packages = script.Parent
local Signal = require(Packages.Signal)
local Symbol = require(Packages.Symbol)
local ComponentJanitorUtil = require(script.ComponentJanitorUtil); ---@module ComponentJanitorUtil
local ComponentAttributeUtil = require(script.ComponentAttributeUtil); ---@module ComponentAttributeUtil
local ComponentPropertyUtil = require(script.ComponentPropertyUtil); ---@module ComponentPropertyUtil
local ComponentFusionUtil = require(script.ComponentFusionUtil); ---@module ComponentFusionUtil

--// Types //--
type Component = any
type Signal = Signal.ScriptSignal<any>

export type Extension = {

    RegisterSignal: (self: Extension, SignalName: string) -> Signal;
	GetSignal: (self: Extension, SignalName: string) -> Signal;

    IsDestroyed: (self: Extension) -> boolean;

} & ComponentJanitorUtil.Extension & ComponentAttributeUtil.Extension & ComponentPropertyUtil.Extension

--// Constants //--
local KEY_IS_DESTROYED = Symbol("IsDestroyed")
local KEY_SIGNALS = Symbol("Signals")

--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

--[=[
    @within BaseComponent
    @method RegisterSignal

    Registers a signal to the component.

    @param signalName string -- The name of the signal to register.
    @return Signal -- The signal that was registered.
]=]
local function RegisterSignal(self, signalName: string): Signal
	local Signals = self[KEY_SIGNALS]
    if Signals[signalName] then
        warn("Signal "..signalName.." already exists")
    else
        Signals[signalName] = Signal.new()
    end
    return Signals[signalName]
end

--[=[
    @within BaseComponent
    @method GetSignal

    Gets a signal from the component.

    @param signalName string -- The name of the signal to get.
    @return Signal -- The signal that was retrieved.
]=]
local function GetSignal(self, signalName: string): Signal
	local Signals = self[KEY_SIGNALS]
	if Signals[signalName] then
		return Signals[signalName]
	else
		error("Signal "..signalName.." does not exist")
	end
end


--[=[
    @within BaseComponent
    @method FireSignal

    Fires a signal from the component.

    @param signalName string -- The name of the signal to fire.
    @param ... any -- The arguments to pass to the signal.
]=]
local function FireSignal(self, signalName: string, ...)
    local signal = self:GetSignal(signalName)
    signal:Fire(...)
end


local function IsDestroyed(self): boolean
    return self[KEY_IS_DESTROYED] == true
end

local UtilMethods = {
    RegisterSignal = RegisterSignal,
	GetSignal = GetSignal,
    FireSignal = FireSignal,
    --IsDestroyed = IsDestroyed,

}

--------------------------------------------------------------------------------
    --// Extension //--
--------------------------------------------------------------------------------

local ComponentUtilExtension = {}
ComponentUtilExtension.ClassName = "BaseComponent"
ComponentUtilExtension.Methods = UtilMethods

-- I include these extensions to provide the component with the functionality of multiple extensions in one.
-- This is also for backwards compatability with the old BaseComponent.
ComponentUtilExtension.Extensions = {
    ComponentJanitorUtil :: any;
    ComponentAttributeUtil;
    ComponentPropertyUtil;
    ComponentFusionUtil;
};

--[=[
    @within BaseComponent
    @ignore
    @param component any
]=]
function ComponentUtilExtension.Constructing(component: Component)
    component[KEY_SIGNALS] = {}

    component:RegisterSignal("Destroyed")

    -- Setup an IsDestroyed method that is readable after the metatable is unset.
    if not component.IsDestroyed then
        component.IsDestroyed = IsDestroyed
    end
end

--[=[
    @within BaseComponent
    @ignore
    @param component any
]=]
function ComponentUtilExtension.Stopped(component: Component)
    component[KEY_IS_DESTROYED] = true
    component[KEY_SIGNALS].Destroyed:Fire()

    for _, signal in pairs(component[KEY_SIGNALS]) do
        signal:Destroy()
    end

    setmetatable(component, nil)
end

return ComponentUtilExtension