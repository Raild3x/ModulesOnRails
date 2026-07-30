--!strict
-- User-defined type functions backing Component's public types (NEW type
-- solver only — the old solver cannot parse `type function`).
--
-- Nonstrict on purpose: strict mode produces spurious nil-safety/refinement
-- errors against the `types` runtime API inside type function bodies.

--[[
	Collects every method from the given extension type (a single extension
	table type, or a union of them for heterogeneous `Extensions` arrays) into
	one flat table type, recursing into dependency extensions (`ext.Extensions`)
	the same way the runtime's Extensions.Resolve + BindMethods do. Each
	method's `self` parameter is erased to `any` so the merged methods are
	callable on any receiver; argument and return types stay checked.

	Compose into a typed-path self alias:

	```lua
	type MyComponent = Component.TypedClass<typeof(Methods) & Component.extensionMethods<typeof(myExtension)>>
	```
]]
export type function extensionMethods(extensions: type)
	local result = types.newtable(nil)
	local seen = {}

	const function copyMethods(methods: type)
		for key, prop in methods:properties() do
			local read = prop.read or prop.write
			if read and read:is("function") and #read:generics() == 0 then
				local fn = types.copy(read)
				local params = fn:parameters()
				local head = params.head
				if head and #head > 0 then
					local newHead = table.clone(head)
					newHead[1] = types.any
					-- Drop the solver-inferred `...any` tail; keep genuine typed variadics.
					fn:setparameters(newHead, if params.tail and not params.tail:is("any") then params.tail else nil)
				end
				read = fn
			end
			result:setproperty(key, read)
		end
	end

	local visitAll

	const function visit(ext: type)
		if not ext:is("table") or seen[ext] then
			return
		end
		seen[ext] = true
		const methods = ext:readproperty(types.singleton("Methods"))
		if methods and methods:is("table") then
			copyMethods(methods)
		end
		const deps = ext:readproperty(types.singleton("Extensions"))
		if deps and deps:is("table") then
			const indexer = deps:indexer()
			if indexer then
				visitAll(indexer.readresult or indexer.value)
			end
		end
	end

	function visitAll(t: type)
		if t == nil then
			return
		end
		for _, e in if t:is("union") then t:components() else { t } do
			visit(e)
		end
	end

	visitAll(extensions)
	return result
end

return {}
