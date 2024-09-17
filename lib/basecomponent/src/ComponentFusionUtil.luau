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

local ComponentJanitorUtilExtension = {}
ComponentJanitorUtilExtension.ClassName = "ComponentFusionUtil"
ComponentJanitorUtilExtension.Methods = UtilMethods

--[=[
    @within ComponentFusionUtil
    @ignore
    @param component any
]=]
function ComponentJanitorUtilExtension.Constructing(component)
    component[KEY_SCOPE] = RailUtil.Fusion.scoped()
    component.Scope = component[KEY_SCOPE]
end

--[=[
    @within ComponentFusionUtil
    @ignore
    @param component any
]=]
function ComponentJanitorUtilExtension.Stopped(component)
    component[KEY_SCOPE]:doCleanup()
    component[KEY_SCOPE] = nil
end



return ComponentJanitorUtilExtension