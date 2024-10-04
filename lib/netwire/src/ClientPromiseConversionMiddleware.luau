-- Logan Hunt [Raildex]
-- Sep 29, 2023
--[=[
    @class ClientPromiseConversionMiddleware
    @ignore
]=]

-- type ClientMiddlewareFn = (args: {any}) → (
-- shouldContinue: boolean,
-- ...: any
-- )

local Packages = script.Parent.Parent
local PromInstance = Packages.Promise
local Promise = require(PromInstance) ---@module Promise

return function (args: {any}): (boolean, ...any)
    local potentialPromise = args[1]
    if PromInstance == potentialPromise then
        local didServerResolve = args[2]
        local prom
        if not didServerResolve then
            prom = Promise.reject(table.unpack(args, 3, #args))
        else
            prom = Promise.resolve(table.unpack(args, 3, #args))
        end
        table.clear(args)
        args[1] = prom
    end
    return true
end
