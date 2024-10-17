--[=[
    @class ServerPromiseConversionMiddleware
    @ignore
]=]
-- type ServerMiddlewareFn = (
--     player: Player,
--     args: {any}
--     ) → (
--     shouldContinue: boolean,
--     ...: any
-- )


local Packages = script.Parent.Parent
local PromInstance = Packages.Promise
local Promise = require(PromInstance) ---@module Promise

return function (player: Player, args: {any}): (boolean, ...any)
    local potentialPromise = args[1]
    if Promise.is(potentialPromise) then
        if args[2] then
            warn("Detected multiple return values with a Promise. This is not supported.")
        end
        local promise = potentialPromise
        local results = table.pack(promise:await())
        local success = results[1]

        table.clear(args)
        args[1] = PromInstance
        args[2] = success
        args[3] = table.pack(table.unpack(results, 2, #results))
    end
    return true
end