-- Authors: Logan Hunt (Raildex)
-- June 05, 2024
--[=[
    @class PromValue

    A PromValue is a class that is used to store a value that may not be set yet.
    This is useful when you need to run something only after the value has been set atleast once.
]=]

--// Imports //--
local Packages = script.Parent
local SuperClass = require(Packages.BaseObject)
local Promise = require(Packages.Promise)
local Symbol = require(Packages.Symbol)

type Promise = typeof(Promise.new())

local KEY_IS_SET = Symbol("IsSet")

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local PromValue = setmetatable({}, SuperClass)
PromValue.ClassName = "PromValue"
PromValue.__index = PromValue

--[=[
    @within PromValue
    @prop ClassName "PromValue"
    The name of the class.
]=]

--[=[
    @within PromValue
    @prop Changed Signal<new: any, old: any>
    A signal that fires when the value of the PromValue changes.
]=]

--[=[
    @tag Static
    @param initialValue any? -- an optional initial value to set the PromValue to.
    @return PromValue
    Creates a new PromValue
]=]

function PromValue.new(initialValue: any?): PromValue
    local self = setmetatable(SuperClass.new(), PromValue)

    self:RegisterSignal("Changed")
    self.Changed = self:GetSignal("Changed")
    
    self[KEY_IS_SET] = false
    self._value = initialValue
    self._prom = self:AddPromise(Promise.fromEvent(self.Changed))

    return self
end
PromValue.__call = PromValue.new

--[=[
    Sets the value of the PromValue and fires the Changed signal.

]=]
function PromValue:Set(newValue: any)
    local oldValue = self._value
    if self:IsReady() and oldValue == newValue then return end
    self._value = newValue
    self[KEY_IS_SET] = true
    self:FireSignal("Changed", newValue, oldValue)
end

--[=[
    Immediately returns the stored value.
]=]
function PromValue:Get(): any
    if not self:IsReady() then
        warn("PromValue:Get() called before value was set")
    end
    return self._value
end

--[=[
    Returns whether or not the value has been set yet
]=]
function PromValue:IsReady(): boolean
    return self[KEY_IS_SET]
end

--[=[
    @within PromValue
    @method OnReady
    @param fn ((value: any) -> ...any)? -- an optional function to call when the value is set.
    @return Promise<any>
    Returns a promise that resolves with the value when it has been set atleast once.
    If given a function then it will run it the first time it is set, this is equivalent to just chaining :andThen().
    Alias for :Promise()
]=]
function PromValue:OnReady(fn: ((value: any) -> ...any)?): Promise
    return if fn then self._prom:andThen(fn) else self._prom
end

--[=[
    @within PromValue
    @method Promise
    @param fn ((value: any) -> ...any)? -- an optional function to call when the value is set.
    @return Promise<any>
    Alias for :OnReady()
]=]
PromValue.Promise = PromValue.OnReady

--[=[
    @within PromValue
    @private
    @method _peek
    This method allows for PromValues to be used with Fusion's peek function.
]=]
PromValue._peek = PromValue.Get


export type PromValue = typeof(PromValue.new())

return PromValue