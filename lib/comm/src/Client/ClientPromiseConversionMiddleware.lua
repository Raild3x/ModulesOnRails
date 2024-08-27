-- Logan Hunt [Raildex]
-- Sep 29, 2023
--[=[
    @class PromiseConversionMiddleware
    @ignore
]=]

-- type ClientMiddlewareFn = (args: {any}) → (
-- shouldContinue: boolean,
-- ...: any
-- )

local Packages = script.Parent.Parent.Parent
local PromInstance = Packages.Promise
local Promise = require(PromInstance) ---@module Promise

return function (args: {any}): (boolean, ...any)
    local potentialPromise = args[1]
    if PromInstance == potentialPromise then
        local resolved = args[2]
        if not resolved then
            return false, Promise.reject(table.unpack(args, 3, #args))
        end
        return false, Promise.resolve(table.unpack(args, 3, #args))
    end
    return true, table.unpack(args)
end
