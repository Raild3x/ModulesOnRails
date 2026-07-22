--!strict
--[=[
	@ignore
	@class RemoteComponentNamespacing

	Pure helpers for prefixing extension-contributed remote names into the single
	Comm namespace folder shared by a component, and for reversing that prefixing
	on the client (which has no registration data and must recover the structure
	from the flat built object's remote names alone).
]=]

local Namespacing = {}

Namespacing.DELIMITER = "/"

--[=[
	@within RemoteComponentNamespacing
	Joins an extension namespace and a remote key into a prefixed remote name.
]=]
function Namespacing.join(namespace: string, key: string): string
	return namespace .. Namespacing.DELIMITER .. key
end

--[=[
	@within RemoteComponentNamespacing
	Returns true if the name belongs to an extension namespace (contains the delimiter).
]=]
function Namespacing.isNamespaced(name: string): boolean
	return string.find(name, Namespacing.DELIMITER, 1, true) ~= nil
end

--[=[
	@within RemoteComponentNamespacing
	Splits a flat built object (the shape returned by `ClientComm:BuildObject`)
	into its flat entries (author + exposed remotes, keys without a delimiter) and
	its namespaced entries grouped by extension namespace. Splits at the FIRST
	delimiter only. Does not mutate the input.
]=]
function Namespacing.splitBuiltObject(obj: { [string]: any }): ({ [string]: any }, { [string]: { [string]: any } })
	local flat: { [string]: any } = {}
	local byNamespace: { [string]: { [string]: any } } = {}

	for name, value in obj do
		local delimiterAt = string.find(name, Namespacing.DELIMITER, 1, true)
		if delimiterAt then
			local namespace = string.sub(name, 1, delimiterAt - 1)
			local key = string.sub(name, delimiterAt + #Namespacing.DELIMITER)
			local sub = byNamespace[namespace]
			if not sub then
				sub = {}
				byNamespace[namespace] = sub
			end
			sub[key] = value
		else
			flat[name] = value
		end
	end

	return flat, byNamespace
end

return Namespacing
