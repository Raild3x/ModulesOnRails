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

--[[
	Builds the type returned by `Component.new`. Both arities route here:

	- One-arg (`Component.new(config)`): pass no `methods`. Result is a copy of
	  `base` (ComponentClass) with extension methods merged in as checked props,
	  plus the `[string]: any` indexer for post-hoc methods.
	- Two-arg (`Component.new(config, methods)`): pass `methods`. Same merge plus
	  the user's methods as checked props, and NO indexer — adding methods after
	  `new` is a type error on this path by design.

	Lifecycle props (Construct/Start/Stop and the update loops) plus every user
	method get their `self` rebound to the merged type — that is what makes
	extension methods checked on `self` inside `function MyComponent:Start()`
	bodies and calls like `class:Greet("hi")` check against the class's own type.
	Rebinding EVERY inherited method's self makes the recursive type too complex
	for the solver ("Code is too complex to typecheck"), so only lifecycle +
	user methods are rebound. Built flat instead of as
	`TypedClass<M & extensionMethods<E>>` because that intersection makes
	overload resolution at the `new` call site exceed the solver's limit.
]]
export type function classWith(base: type, extensions: type, methods: type)
	if not base:is("table") then
		print("classWith: base is not a table")
		return base
	end

	const typed = methods and methods:is("table")
	const result = if typed
		then types.newtable(nil)
		else types.newtable(nil, { index = types.string, readresult = types.any, writeresult = types.any })

	for key, prop in base:properties() do
		result:setproperty(key, prop.read or prop.write)
	end

	-- Rebinds a function's self parameter to the merged type so calls on the
	-- returned class check against the class's own type.
	const function rebound(fn: type)
		const copy = types.copy(fn)
		const params = copy:parameters()
		local head = params.head
		if head and #head > 0 then
			local newHead = table.clone(head)
			newHead[1] = result
			-- Drop the solver-inferred `...any` tail; keep genuine typed variadics.
			if params.tail and not params.tail:is("any") then
				copy:setparameters(newHead, params.tail)
			else
				copy:setparameters(newHead)
			end
		end
		return copy
	end

	for _, name in { "Construct", "Start", "Stop", "HeartbeatUpdate", "SteppedUpdate", "RenderSteppedUpdate" } do
		const key = types.singleton(name)
		const read = base:readproperty(key)
		if read and read:is("function") then
			-- print("Rebinding lifecycle method:", name)
			result:setproperty(key, rebound(read))
		end
	end

	-- Attach extension methods as checked props, with self erased to any so they are callable on any receiver.
	for key, prop in extensionMethods(extensions):properties() do
		result:setproperty(key, prop.read or prop.write)
	end

	if typed then
		for key, prop in methods:properties() do
			const read = prop.read or prop.write
			if read and read:is("function") and #read:generics() == 0 then
				-- print("Rebinding method:", key:value())
				result:setproperty(key, rebound(read))
			else
				result:setproperty(key, read)
			end
		end
	end

	return result
end

return {}
