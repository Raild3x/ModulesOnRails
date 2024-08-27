--!strict
-- Authors: Logan Hunt [Raildex]
-- April 19, 2023
--[=[
    @class ComponentJanitorUtil
    @ignore

    This component extension provides a janitor to a component and provides easy access to the janitor's methods.
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
local Symbol = require(Packages.Symbol)
local Janitor = require(Packages.Janitor)

--// Constants //--
local JANITOR = Symbol("Janitor")

--// Types //--
type Promise = any
export type Extension = {
    GetTask: (self: Extension, index: any) -> any,
    AddTask: <T>(self: Extension, task: T, cleanupMethod: string?, index: any?) -> T,
    RemoveTask: (self: Extension, index: any, dontClean: boolean?) -> (),
    RemoveTaskNoClean: (self: Extension, index: any) -> (),
    AddPromise: (self: Extension, promise: Promise) -> Promise,
}

--------------------------------------------------------------------------------
    --// Private Functions //--
--------------------------------------------------------------------------------

--[=[
    @within BaseComponent
    @method AddPromise

    Adds a promise to the component's janitor. Returns the same promise that was given.

    @param promise Promise<T>
    @return Promise<T>
]=]
local function AddPromise(self, promise: Promise): Promise
    return self[JANITOR]:AddPromise(promise)
end

--[=[
    @within BaseComponent
    @method AddTask

    Adds a task to the component's janitor.

    @param task T
    @param cleanupMethod (string | true)?
    @param index any?
    @return T -- The same task that was given
]=]
local function AddTask<T>(self, task: T, cleanupMethod: (string | true)?, index: any?): T
    return self[JANITOR]:Add(task, cleanupMethod, index)
end

--[=[
    @within BaseComponent
    @method RemoveTaskNoClean

    Removes a task from the component's janitor without cleaning it.

    @param index any -- The index of the task to remove.
]=]
local function RemoveTaskNoClean(self, index: any)
    self[JANITOR]:RemoveNoClean(index)
end

--[=[
    @within BaseComponent
    @method RemoveTask

    Removes a task from the component's janitor.

    @param index any -- The id of the task to remove.
    @param dontClean boolean? -- Optional flag to not clean the task.
]=]
local function RemoveTask(self, index: any, dontClean: boolean)
    if dontClean then
        RemoveTaskNoClean(self, index)
    end
    self[JANITOR]:Remove(index)
end

--[=[
    @within BaseComponent
    @method GetTask

    Gets a task from the janitor.

    @param index any -- The id of the task to get.
    @return any -- The task that was retrieved.
]=]
local function GetTask(self, index: any): any
    return self[JANITOR]:Get(index)
end


local UtilMethods = {
    AddPromise = AddPromise,
    AddTask = AddTask,
    RemoveTask = RemoveTask,
    RemoveTaskNoClean = RemoveTaskNoClean,
    GetTask = GetTask,
}

--------------------------------------------------------------------------------
    --// Extension //--
--------------------------------------------------------------------------------

local ComponentJanitorUtilExtension = {}
ComponentJanitorUtilExtension.ClassName = "ComponentJanitorUtil"
ComponentJanitorUtilExtension.Methods = UtilMethods

--[=[
    @within ComponentJanitorUtil
    @ignore
    @param component any
]=]
function ComponentJanitorUtilExtension.Constructing(component)
    component[JANITOR] = Janitor.new()
end

--[=[
    @within ComponentJanitorUtil
    @ignore
    @param component any
]=]
function ComponentJanitorUtilExtension.Stopped(component)
    component[JANITOR]:Destroy()
    component[JANITOR] = nil
end



return ComponentJanitorUtilExtension