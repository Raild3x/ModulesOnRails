--!strict

export type ReplicationToken = {
	__NAME__: string,
    Name: string,
}

const tokenMT = {
    __tostring = function(self: ReplicationToken)
        return "ReplicationToken<"..self.__NAME__..">"
    end,
}

const UsedNames: { [string]: ReplicationToken } = setmetatable({}, {__mode = "v"}) :: any

const function getExistingToken(name: string): ReplicationToken?
    return UsedNames[name]
end

const function isTokenInUse(name: string | ReplicationToken): boolean
    if typeof(name) == "table" then
        name = name.__NAME__
    end
    return UsedNames[name :: string] ~= nil
end

const function registerNewToken(name: string): ReplicationToken
    if UsedNames[name] then
        error(`ServerReplicator.Token: token name {name} is already in use`)
    end
    local token = { 
        __NAME__ = name,
        Name = name,
    } :: ReplicationToken
    setmetatable(token, tokenMT)
    UsedNames[name] = token
    return token
end

const function getOrCreateToken(name: string): ReplicationToken
    if UsedNames[name] then
        return UsedNames[name]
    end
    return registerNewToken(name)
end

const function isToken(value: any): boolean
    return typeof(value) == "table" and value.__NAME__ ~= nil
end

const function getTokenName(token: ReplicationToken): string
    return token.__NAME__
end

return table.freeze({
    isTokenInUse = isTokenInUse,
    registerNewToken = registerNewToken,
    getOrCreateToken = getOrCreateToken,
    getExistingToken = getExistingToken,
    isToken = isToken,
    getTokenName = getTokenName,
})