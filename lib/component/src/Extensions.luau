--!strict
-- Component extension resolution & method binding.
-- Authors: Stephen Leitnick, Logan Hunt [Raildex]
--[=[
	@class ComponentExtensions
	@ignore

	Resolves which extensions apply to a component and in what order, and binds
	extension `Methods` onto a component class.

	Ordering is a **topological sort**: an extension listed in another extension's
	`Extensions` array is a dependency edge, so dependencies are always resolved
	before the extension that depends on them (deterministic DFS post-order, with
	declared order as the tiebreak). `ShouldExtend` is evaluated exactly once per
	extension per instance. A dependency cycle is an error.
]=]

local Keys = require(script.Parent.Keys)

type Extension = any
type Component = any

local Extensions = {}

--[=[
	@within ComponentExtensions
	Resolves the active, ordered extension list for a component.

	@param component -- the component (or class) the extensions apply to
	@param rootList -- the class's configured `Extensions` array
	@param isClass boolean -- when true, `ShouldExtend` is not evaluated (every
		extension is included; used to compute the class-level active set)
	@return { Extension } -- dependencies first, declared order otherwise
]=]
function Extensions.Resolve(component: Component, rootList: { Extension }?, isClass: boolean): { Extension }
	local result: { Extension } = {}
	local added: { [Extension]: boolean } = {}
	local inProgress: { [Extension]: boolean } = {}
	local includeCache: { [Extension]: boolean } = {}

	local function isIncluded(ext: Extension): boolean
		local cached = includeCache[ext]
		if cached ~= nil then
			return cached
		end
		local include: boolean
		if isClass then
			include = true
		else
			-- Annotated: the new solver refines a bare `any` here to the top
			-- `function` type, which it refuses to call.
			local fn: ((Component) -> boolean)? = ext.ShouldExtend
			include = if type(fn) == "function" then fn(component) == true else true
		end
		includeCache[ext] = include
		return include
	end

	local function visit(ext: Extension)
		if added[ext] then
			return
		end
		if not isIncluded(ext) then
			return
		end
		if inProgress[ext] then
			error("[Component] Extension dependency cycle detected", 0)
		end
		inProgress[ext] = true
		if type(ext.Extensions) == "table" then
			for _, dep in ext.Extensions do
				visit(dep)
			end
		end
		inProgress[ext] = nil
		if not added[ext] then
			added[ext] = true
			table.insert(result, ext)
		end
	end

	if rootList then
		for _, ext in rootList do
			visit(ext)
		end
	end
	return result
end

--[=[
	@within ComponentExtensions
	Binds every extension's `Methods` onto `target` (the component class).

	Collisions are an error, not a silent overwrite: if two extensions define the
	same method name, or an extension's method name is already an own field of the
	class, binding fails loudly.
]=]
function Extensions.BindMethods(target: Component, extensionList: { Extension })
	local boundBy: { [string]: Extension } = {}
	for _, extension in extensionList do
		if type(extension.Methods) ~= "table" then
			continue
		end
		for key, value in extension.Methods do
			if type(key) == "string" and string.match(key, "^On%u") and not Keys.ReservedHookNames[key] then
				-- A hook in Methods would claim the class's single-assignment
				-- hook slot; extension hooks are independent connections.
				error(
					`[Component] Extension method '{key}' looks like a member hook — declare it in the extension's Hooks table, not Methods`,
					0
				)
			end
			if type(value) ~= "function" then
				error(`[Component] Invalid extension method '{tostring(key)}': expected a function`, 0)
			end
			local prior = boundBy[key]
			if prior and prior ~= extension then
				error(`[Component] Extension method collision: two extensions both define '{key}'`, 0)
			end
			if prior == nil and rawget(target, key) ~= nil then
				error(`[Component] Extension method '{key}' collides with an existing class member`, 0)
			end
			target[key] = value
			boundBy[key] = extension
		end
	end
end

--[=[
	@within ComponentExtensions
	Validates and flattens every extension's declarative `Hooks` table into
	connect-ready entries (`Keys.ExtensionHookEntry`). Called once per class at
	`_setup`. Unlike `Methods`, hooks are ADDITIVE connections — no collision
	checks between extensions or with class hooks, because each entry is its
	own independent connection (as if the extension had `Connect`ed manually in
	construct and disconnected in stop).

	Accepted shapes: `Hooks.OnTouched = fn` (instance-event wrapper) and
	`Hooks.OnAttributeChanged / OnPropertyChanged = { Name = fn, ... }`.
	`kind`/`name` are pre-split so the per-instance connect loop does zero
	string work.
]=]
function Extensions.CollectHooks(extensionList: { Extension }): { Keys.ExtensionHookEntry }
	local out: { Keys.ExtensionHookEntry } = {}
	local function add(ext: any, kind: "event" | "attr" | "prop", name: string, fn: (...any) -> any)
		local entry: Keys.ExtensionHookEntry = { ext = ext, kind = kind, name = name, fn = fn }
		table.insert(out, entry)
	end
	for _, extension in extensionList do
		local hooks: { [any]: any }? = (extension :: any).Hooks
		if hooks == nil then
			continue
		end
		if type(hooks) ~= "table" then
			error(`[Component] Extension 'Hooks' must be a table, got {typeof(hooks)}`, 0)
		end
		for key, value in hooks do
			if key == "OnAttributeChanged" or key == "OnPropertyChanged" then
				local kind: "attr" | "prop" = if key == "OnAttributeChanged" then "attr" else "prop"
				if type(value) ~= "table" then
					error(`[Component] Extension hook '{key}' must be a table of functions`, 0)
				end
				for name, fn in value :: { [any]: any } do
					if type(name) ~= "string" or type(fn) ~= "function" then
						error(`[Component] Extension hook '{key}.{tostring(name)}': expected a function`, 0)
					end
					add(extension, kind, name, fn)
				end
			else
				local eventName = if type(key) == "string" then string.match(key, "^On(%u%w*)$") else nil
				if eventName == nil or Keys.ReservedHookNames[key] then
					error(`[Component] Extension hook '{tostring(key)}' is not a valid hook name`, 0)
				end
				if type(value) ~= "function" then
					error(`[Component] Extension hook '{key}': expected a function, got {typeof(value)}`, 0)
				end
				add(extension, "event", eventName, value)
			end
		end
	end
	return out
end

--[=[
	@within ComponentExtensions
	Returns false if any extension's `ShouldConstruct` vetoes construction.
	Called before any component state is created, so a false result needs no
	cleanup.
]=]
function Extensions.ShouldConstruct(activeExtensions: { Extension }, component: Component): boolean
	for _, extension in activeExtensions do
		local fn: ((Component) -> boolean)? = extension.ShouldConstruct
		if type(fn) == "function" and not fn(component) then
			return false
		end
	end
	return true
end

return Extensions
