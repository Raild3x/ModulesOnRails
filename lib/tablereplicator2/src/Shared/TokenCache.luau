--!strict

--[=[
	A `ReplicationToken` is a lightweight handle that identifies a replicator's
	namespace. It carries the name as both `.Name` and `.__NAME__` (legacy alias).

	Tokens created by `getOrCreateToken` are plain handles with no ownership
	semantics. Tokens created by `registerToken` (exposed as
	`ServerReplicator.TOKEN()`) exclusively own their namespace name and can be
	released via `destroyToken` (`ServerReplicator.TOKEN.destroy(token)`). The
	ownership ledger backing that exclusivity lives entirely in this module.
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
-- replicators using it are gone). The ownership ledger below uses strong
-- references (`tokenOwner`) and is the authoritative lifetime for owned tokens.
const UsedNames: { [string]: ReplicationToken } = setmetatable({}, { __mode = "v" }) :: any

-- Creates or returns the cached handle for `name`. Claim-free: does NOT touch
-- the ownership ledger below.
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

--------------------------------------------------------------------------------
--// Namespace ownership ledger //--
--------------------------------------------------------------------------------

-- Namespace ownership ledger (server-only, never sent to the client).
-- `tokenOwner[name]` holds the ReplicationToken that exclusively claimed `name`
-- via `registerToken`; raw-string replicators cannot use that name while an
-- owner exists.
-- `liveCount[name]` tracks live ServerReplicators using each named namespace so
-- `destroyToken` can refuse to unregister while replicators still exist.
-- `tokenDestroyers[name]` holds the zero-argument cleanup function for each
-- registered token, looked up by name in `destroyToken(token)`.
const tokenOwner: { [string]: ReplicationToken } = {}
const liveCount: { [string]: number } = {}
const tokenDestroyers: { [string]: () -> () } = {}

-- Registers `name` in the ledger and returns a token handle exclusively
-- owning it. The corresponding destroyer is stored in `tokenDestroyers` and
-- called via `destroyToken(token)`.
const function registerToken(name: string): ReplicationToken
	assert(
		tokenOwner[name] == nil,
		`ServerReplicator.TOKEN: namespace "{name}" is already owned by a token`
	)
	assert(
		(liveCount[name] or 0) == 0,
		`ServerReplicator.TOKEN: namespace "{name}" is currently used by raw-string replicators; claim it with TOKEN() before creating any replicators with that name`
	)
	local token = getOrCreateToken(name)
	tokenOwner[name] = token
	tokenDestroyers[name] = function()
		assert(
			tokenOwner[name] == token,
			`ReplicationToken: token "{name}" is not the registered owner or was already destroyed`
		)
		assert(
			(liveCount[name] or 0) == 0,
			`ReplicationToken: cannot destroy token "{name}" — {liveCount[name] or 0} replicator(s) still use this namespace; destroy them first`
		)
		tokenOwner[name] = nil
		tokenDestroyers[name] = nil
	end
	return token
end

-- Destroys a token that was created with `registerToken`, releasing its name.
-- Errors if the token is not the registered owner or any live replicators
-- still use this namespace.
const function destroyToken(token: ReplicationToken)
	local fn = tokenDestroyers[token.Name]
	assert(
		fn ~= nil,
		`ReplicationToken: token "{token.Name}" is not a registered namespace owner or was already destroyed`
	)
	fn()
end

-- Validates that `ns` may be claimed by a new replicator given whether it was
-- passed as an explicit token (`rawNs`) or a raw string, then increments its
-- live count. Called from `ServerReplicator.new`; the matching decrement
-- happens in `releaseNamespace`, called from `Destroy`.
const function acquireNamespace(ns: string, rawNs: string | ReplicationToken, wasExplicitToken: boolean)
	if wasExplicitToken then
		assert(
			tokenOwner[ns] == rawNs,
			`ServerReplicator.new: token for namespace "{ns}" was destroyed or is not the registered owner`
		)
	else
		assert(
			tokenOwner[ns] == nil,
			`ServerReplicator.new: namespace "{ns}" is reserved by a ReplicationToken; pass the token instead of a raw string`
		)
	end
	liveCount[ns] = (liveCount[ns] or 0) + 1
end

-- Decrements `ns`'s live count. Called from `ServerReplicator.Destroy`.
const function releaseNamespace(ns: string)
	const count = (liveCount[ns] or 1) - 1
	if count <= 0 then
		liveCount[ns] = nil
	else
		liveCount[ns] = count
	end
end

return table.freeze({
	getOrCreateToken = getOrCreateToken,
	getExistingToken = getExistingToken,
	isTokenInUse = isTokenInUse,
	isToken = isToken,
	getTokenName = getTokenName,
	registerToken = registerToken,
	destroyToken = destroyToken,
	acquireNamespace = acquireNamespace,
	releaseNamespace = releaseNamespace,
})
