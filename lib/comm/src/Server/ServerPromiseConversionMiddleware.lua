
-- type ServerMiddlewareFn = (
--     player: Player,
--     args: {any}
--     ) → (
--     shouldContinue: boolean,
--     ...: any
-- )


local Packages = script.Parent.Parent.Parent
local PromInstance = Packages.Promise
local Promise = require(PromInstance) ---@module Promise

return function (player: Player, args: {any}): (boolean, ...any)
    local potentialPromise = args[1]
    if Promise.is(potentialPromise) then
        local promise = potentialPromise
        local results = table.pack(promise:await())
        local success = results[1]
        if not success then
            return false, PromInstance, false, table.unpack(results, 2, #results)
        end
        return false, PromInstance, true, table.unpack(results, 2, #results)
    end
    return true, table.unpack(args)
    
end