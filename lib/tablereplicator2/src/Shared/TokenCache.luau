--!strict

--[=[
	A `ReplicationToken` is a lightweight handle that identifies a replicator's
	namespace. It carries the name as both `.Name` and `.__NAME__` (legacy alias).

	Tokens created by `getOrCreateToken` are plain handles with no ownership
	semantics — the ownership ledger lives in `ServerReplicator`. Tokens created
	by `ServerReplicator.TOKEN()` exclusively own their namespace name and can be
	released via `ServerReplicator.TOKEN.destroy(token)`.
]=]
export type ReplicationToken = {
	__NAME__: string,
	Name: string,
}

const tokenMT = {
	__tostring = function(self: ReplicationToken)
		return "ReplicationToken<" .. self.__NAME__ .. ">"
	end,
}

-- Weak-valued handle cache: name -> token object. Allows GC of tokens that no
-- longer have strong references (e.g. after a server TOKEN is destroyed and all
-- replicators using it are gone). The ownership ledger in ServerReplicator uses
-- strong references and is the authoritative lifetime for owned tokens.
const UsedNames: { [string]: ReplicationToken } = setmetatable({}, { __mode = "v" }) :: any

-- Creates or returns the cached handle for `name`. Claim-free: does NOT touch
-- the ownership ledger (that is ServerReplicator's concern).
const function getOrCreateToken(name: string): ReplicationToken
	if UsedNames[name] then
		return UsedNames[name]
	end
	local token = {
		__NAME__ = name,
		Name = name,
	} :: ReplicationToken
	setmetatable(token, tokenMT)
	UsedNames[name] = token
	return token
end

const function getExistingToken(name: string): ReplicationToken?
	return UsedNames[name]
end

const function isTokenInUse(name: string | ReplicationToken): boolean
	if typeof(name) == "table" then
		name = name.__NAME__
	end
	return UsedNames[name :: string] ~= nil
end

const function isToken(value: any): boolean
	return typeof(value) == "table" and value.__NAME__ ~= nil
end

const function getTokenName(token: ReplicationToken): string
	return token.__NAME__
end

return table.freeze({
	getOrCreateToken = getOrCreateToken,
	getExistingToken = getExistingToken,
	isTokenInUse = isTokenInUse,
	isToken = isToken,
	getTokenName = getTokenName,
})
