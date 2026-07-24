--!nonstrict
-- Shared test utilities for the Component specs (not a spec itself).
local CollectionService = game:GetService("CollectionService")

local Component = require(script.Parent.Parent :: any) :: any

local Helpers = {}

local counter = 0
function Helpers.uniqueTag(): string
	counter += 1
	return `CmpSpec_{counter}_{math.floor(os.clock() * 1e6)}`
end

-- Spin the scheduler until predicate() is truthy or timeout elapses.
function Helpers.waitUntil(predicate, timeout: number?): boolean
	local deadline = os.clock() + (timeout or 2)
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait()
	end
	return predicate() == true or predicate() ~= nil and predicate() ~= false
end

-- Create a component class with a fresh tag. `def` is a table of methods/fields
-- copied onto the class; `config` overrides the ComponentConfig.
function Helpers.makeClass(def, config)
	local tag = Helpers.uniqueTag()
	local cfg = { Tag = tag, Ancestors = { workspace } }
	if config then
		for k, v in config do
			cfg[k] = v
		end
	end
	local class = Component.new(cfg)
	if def then
		for k, v in def do
			class[k] = v
		end
	end
	return class, tag
end

-- Create an anchored, tagged Part parented under workspace.
function Helpers.taggedPart(tag: string, parent: Instance?): Instance
	local part = Instance.new("Part")
	part.Anchored = true
	for _, singleTag in { tag } do
		CollectionService:AddTag(part, singleTag)
	end
	part.Parent = parent or workspace
	return part
end

-- Convenience: wait until a component of `class` is started on `instance`.
function Helpers.waitStarted(class, instance, timeout: number?): boolean
	return Helpers.waitUntil(function()
		return class:Has(instance)
	end, timeout)
end

return Helpers
