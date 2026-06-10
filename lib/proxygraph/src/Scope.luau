--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Scope

	Manages the lifetime of reactive objects created within a context.
	Destructors run in reverse-insertion order when `Destroy()` is called.
	Child scopes are destroyed before the parent's own destructors run.

	Usage:
	```lua
	local scope = Scope.new()
	scope:addTask(function() print("cleaned up") end)
	scope:Destroy()  -- prints "cleaned up"

	local child = scope:derive()  -- auto-destroyed when scope is destroyed
	```
]=]

local Types = require("./Types")
export type Scope<T> = Types.Scope<T>

-- Shorthand for a plain scope (no merged provider methods).
type PlainScope = Scope<{}>

-- ─── Class table ─────────────────────────────────────────────────────────────

local ScopeClass = {}
ScopeClass.__index = ScopeClass

--[=[
	Creates a new empty Scope.
]=]
function ScopeClass.new(): PlainScope
	return setmetatable({
		_destructors = {} :: { () -> () },
		_children = {} :: { PlainScope },
		_destroyed = false,
	}, ScopeClass) :: any
end

--[=[
	Destroys the scope: destroys all child scopes first, then runs destructors
	in reverse-insertion order. Safe to call multiple times (idempotent).
]=]
function ScopeClass.Destroy(self: PlainScope)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, child in self._children do
		child:Destroy()
	end
	table.clear(self._children)
	local dtors = self._destructors
	for i = #dtors, 1, -1 do
		dtors[i]()
	end
	table.clear(dtors)
end

--[=[
	Creates a child Scope added to this scope's children list so it is
	automatically destroyed when this scope is destroyed. The child may also
	be destroyed independently before the parent.
]=]
function ScopeClass.derive(self: PlainScope): PlainScope
	local child = ScopeClass.new()
	table.insert(self._children, child)
	return child
end

--[=[
	Registers `fn` as a destructor to be called (in reverse insertion order
	with all other destructors) when `Destroy()` is invoked on this scope.
]=]
function ScopeClass.addTask(self: PlainScope, fn: () -> ())
	table.insert(self._destructors, fn)
end

return ScopeClass
