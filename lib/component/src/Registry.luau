--!strict
-- Global cross-class component registry.
-- Authors: Logan Hunt [Raildex]
--[=[
	@class ComponentRegistry
	@ignore

	A module-level map of `Roblox Instance -> { [ComponentClass]: componentInstance }`
	spanning every component class. The original Component only tracked instances
	per-class, so a cross-class question like "what components does this instance
	have?" was unanswerable. This registry backs `Component.GetComponents(instance)`
	and the world-level query engine.

	A component is registered the moment its construction completes (before it
	starts) and unregistered during teardown, mirroring the per-class tracking in
	`init.luau`.
]=]

type ComponentClass = any
type Component = any

local instanceToClasses: { [Instance]: { [ComponentClass]: Component } } = {}

local Registry = {}

--[=[
	@within ComponentRegistry
	Registers a constructed component under its instance and class.
]=]
function Registry.Register(instance: Instance, class: ComponentClass, component: Component)
	local classes = instanceToClasses[instance]
	if not classes then
		classes = {}
		instanceToClasses[instance] = classes
	end
	classes[class] = component
end

--[=[
	@within ComponentRegistry
	Removes a component's registration. Cleans up the instance entry entirely
	once it has no remaining components, so the registry never retains destroyed
	instances.
]=]
function Registry.Unregister(instance: Instance, class: ComponentClass)
	local classes = instanceToClasses[instance]
	if not classes then
		return
	end
	classes[class] = nil
	if next(classes) == nil then
		instanceToClasses[instance] = nil
	end
end

--[=[
	@within ComponentRegistry
	Returns the component of `class` bound to `instance`, or `nil`.
]=]
function Registry.Get(instance: Instance, class: ComponentClass): Component?
	local classes = instanceToClasses[instance]
	return if classes then classes[class] else nil
end

--[=[
	@within ComponentRegistry
	Returns a fresh array of every component bound to `instance`, across all
	classes.
]=]
function Registry.GetAll(instance: Instance): { Component }
	local out = {}
	local classes = instanceToClasses[instance]
	if classes then
		for _, component in classes do
			table.insert(out, component)
		end
	end
	return out
end

return Registry
