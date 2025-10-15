--!strict
-- Authors: Logan Hunt [Raildex]
-- April 19, 2023
--[=[
    @class ComponentFusionUtil
    @ignore

    This component extension provides a fusion scope to a component
]=]

--[[ API
    :GetTask(index: any) -> any
    :AddTask<T>(task: T, cleanupMethod: string?, index: any?) -> T
    :AddPromise(promise: Types.Promise) -> Types.Promise
    :RemoveTask(index: any, dontClean: boolean?)
    :RemoveTaskNoClean(index: any)
]]

--// Requires //--
local Packages = script.Parent.Parent
local RailUtil = require(Packages.RailUtil)
local Symbol = require(Packages.Symbol)
local Fusion = require(Packages.Fusion)
local ComponentJanitorUtil = require(script.Parent.ComponentJanitorUtil); ---@module ComponentJanitorUtil

--// Constants //--
local KEY_SCOPE = Symbol("Fusion Scope")

--// Types //--
export type Extension = {
    GetScope: (self: Extension) -> Fusion.Scope<any>,
}

--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

--[=[
    @within BaseComponent
    @method GetScope

    Returns a scope associated with the lifecycle of the component.
    Inherits methods from RailUtil.Fusion and Fusion.

    @return Scope<any>
]=]
local function GetScope(self): Fusion.Scope<any>
    return self[KEY_SCOPE]
end


local UtilMethods = {
    GetScope = GetScope
}

--------------------------------------------------------------------------------
    --// Extension //--
--------------------------------------------------------------------------------

local ComponentFusionUtilExtension = {}
ComponentFusionUtilExtension.ClassName = "ComponentFusionUtil"
ComponentFusionUtilExtension.Methods = UtilMethods
ComponentFusionUtilExtension.Extensions = {}

--[=[
    @within ComponentFusionUtil
    @ignore
    @param component any
]=]
function ComponentFusionUtilExtension.Constructing(component)
    component[KEY_SCOPE] = RailUtil.Fusion.scoped()
    component.Scope = component[KEY_SCOPE]
end

--[=[
    @within ComponentFusionUtil
    @ignore
    @param component any
]=]
function ComponentFusionUtilExtension.Stopped(component)
    ComponentJanitorUtil.Stopped(component) -- Ensure janitor cleans first
    component[KEY_SCOPE]:doCleanup()
    component[KEY_SCOPE] = nil
end



return ComponentFusionUtilExtension