--!strict
-- Compile-time regression tests for Component's exported types. This module is
-- never required at runtime — `luau-lsp analyze` coming back clean IS the test.
--
-- NEW TYPE SOLVER ONLY: init.luau uses user-defined type functions to merge
-- extension methods into the class type, which the old solver cannot parse.
-- Run from the repo root (see rokit.toml for luau-lsp):
--   luau-lsp analyze --flag:LuauSolverV2=true --sourcemap=sourcemap.json --base-luaurc=.luaurc --definitions=<globalTypes.d.luau> lib/component/src/Tests/Component.types.luau

local Component = require(script.Parent.Parent)
local Types = require(script.Parent.Parent.Types)

--------------------------------------------------------------------------------
-- Classic path: lifecycle methods defined post-hoc on the returned class.
-- `self` inside them is fully typed, and extension methods are merged in as
-- CHECKED props by the extensionMethods type function. Custom methods must go
-- through the config's `Methods` table — the class type has no `[string]: any`
-- indexer, so assigning a brand-new name post-hoc is a type error by design.
--------------------------------------------------------------------------------

local depExtension = {}
depExtension.Methods = {}

function depExtension.Methods:HelloDependency(flag: boolean)
	print("Hello from depExtension!", flag)
end

local myExtension = {}
myExtension.Extensions = { depExtension }
myExtension.Methods = {}

function myExtension.Methods:HelloExtension(num: number): number
	print("Hello from myExtension!", num)
	return num * 2
end

local otherExtension = {}
otherExtension.Methods = {}

function otherExtension.Methods:HelloOther(msg: string)
	print("Hello from otherExtension!", msg)
end

local ClassicMethods = {}

local myComponent = Component.new {
	Tag = "TypeSpecComponent",
	Ancestors = { workspace },
	Extensions = { myExtension, otherExtension },
	Methods = ClassicMethods,
}

-- `self: any` keeps this callable from a post-hoc `function myComponent:Start()`
-- whose own `self` the solver infers structurally (an annotated `self` would
-- close the circular type instead — see the typed path below).
function ClassicMethods.HelloComponent(_self: any, str: string)
	print("Hello from myComponent!", str)
end

function myComponent:Start()
	local inst: Instance = self.Instance -- typed via the rebound lifecycle self
	local doubled: number = self:HelloExtension(123) -- CHECKED extension method
	self:HelloOther("heterogeneous") -- CHECKED (second extension in the array)
	self:HelloDependency(true) -- CHECKED (dependency extension's method)
	self:HelloComponent("test") -- CHECKED (config Methods)
	print(inst, doubled)
end

function myComponent:Stop(reason)
	local r: Component.StopReason = reason
	print(r)
end

function myComponent:HeartbeatUpdate(dt)
	local n: number = dt
	print(n)
end

-- Checked extension method directly on the class object too.
myComponent:HelloExtension(7)

-- Self-generic class API returns the receiver's own (merged) type.
local found = myComponent:FromInstance(workspace)
if found then
	local inst: Instance = found.Instance
	local doubled: number = found:HelloExtension(9)
	found:HelloComponent("again")
	print(inst, doubled)
end

local phase: Component.LifecyclePhase = myComponent:GetLifecycleStatus(workspace)
print(phase)

--------------------------------------------------------------------------------
-- Typed path: fully checked methods + fields via the config's Methods/Fields.
-- The `self: MyTyped` annotations close the circular type; composing
-- Component.extensionMethods<> into the alias makes extension methods checked
-- on `self` inside method bodies as well.
--------------------------------------------------------------------------------

local Methods = {}
local TypedComponent = Component.new {
	Tag = "TypeSpecTyped",
	Extensions = { myExtension, otherExtension },
	Methods = Methods,
	Fields = {
		Foo = 5,
	},
	InitFields = function()
		return { Hello = "World" }
	end,
}

type tc = typeof(TypedComponent)
type ti = typeof(TypedComponent:__ComponentInstanceTypeExport())

-- Config `Fields` and `InitFields` both land on the INSTANCE type.
local sampleInstance: ti = nil :: any
local foo: number = sampleInstance.Foo -- from Fields
local hello: string = sampleInstance.Hello -- from InitFields
print(foo, hello, sampleInstance.Instance)

type Extensions = Component.extensionMethods<typeof(myExtension)>
type MyTypedClass = Types.TypedClass<typeof(Methods) & Extensions>
type MyTypedInstance = Types.TypedInstance<typeof(Methods) & Extensions>

function Methods:Greet(msg: string): number
	print(self.Instance, msg)
	return #msg
end

function Methods.Start(self)
	local n: number = self:Greet("hello") -- fully checked
	local doubled: number = self:HelloExtension(4) -- checked extension method
	local inst: Instance = self.Instance
	local th: thread = self:AddTask(task.spawn(function() end))
	print(n, doubled, inst, th)
end

function Methods.UseSibling(self: ti)
	self:CreateFromInstance(Instance.new("Model"))

	local sibling = self:GetComponent(myComponent)
	if sibling then
		local inst: Instance = sibling.Instance
		sibling:HelloExtension(11) -- checked on the sibling's merged type
		print(inst)
	end
end

function Methods:Test(num: number): string
	return `Test: {num}`
end

local typedFound = TypedComponent:FromInstance(workspace)
if typedFound then
	print(typedFound.Hello)
	local n: number = typedFound:Greet("hi") -- checked on the derived type
	local doubled: number = typedFound:HelloExtension(2) -- merged via extensionMethods<E>
	print(n, doubled)
end

TypedComponent.Started:Connect(function(comp)
	local n: number = comp:Greet("started")
	print(n)
end)

for _, c in TypedComponent:GetAll() do
	c:Greet("each")
end

return nil
