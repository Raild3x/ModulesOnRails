--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Root

	Thread-local owner-scope stack. Reactive constructors (Computed, Effect)
	automatically register their cleanup with the current owner when one
	exists. Each coroutine maintains its own stack so concurrent coroutines
	do not interfere. Implicit scope does NOT propagate across `task.spawn`.

	Usage:
	```lua
	local cleanup = Root.root(function()
		-- Computed / Effect calls here auto-register with the scope.
	end)
	cleanup()  -- destroys everything created inside root()
	```
]=]

local ScopeModule = require("./Scope")
local Types = require("./Types")
type Scope = Types.Scope<{}>

local Root = {}

-- Sentinel for the host main thread when coroutine.running() returns nil.
local _mainThreadKey = {}

-- Weak-keyed by thread so dead coroutines are GC'd cleanly.
local _threadStacks: { [thread | {}]: { Scope } } = setmetatable({}, { __mode = "k" })

local function currentKey(): thread | {}
	return coroutine.running() or _mainThreadKey
end

local function getStack(): { Scope }
	local key = currentKey()
	local stack = _threadStacks[key]
	if stack == nil then
		stack = {}
		_threadStacks[key] = stack
	end
	return stack
end

--[=[
	Pushes `scope` onto the current thread's owner stack.
]=]
function Root.pushOwner(scope: Scope)
	table.insert(getStack(), scope)
end

--[=[
	Pops the innermost owner from the current thread's owner stack.
]=]
function Root.popOwner()
	local stack = getStack()
	table.remove(stack)
end

--[=[
	Returns the current thread's innermost owner Scope, or nil if none.
]=]
function Root.currentOwner(): Scope?
	local stack = _threadStacks[currentKey()]
	if stack == nil or #stack == 0 then
		return nil
	end
	return stack[#stack]
end

--[=[
	Runs `fn` inside a new root Scope. Returns a cleanup function that
	destroys the scope (and all reactive objects registered with it) when
	called. If `fn` throws, the scope is destroyed immediately and the error
	is re-raised.

	```lua
	local cleanup = Root.root(function()
		-- all Computed/Effect calls auto-register cleanup here
	end)
	-- later:
	cleanup()
	```
]=]
function Root.root(fn: () -> ()): () -> ()
	local scope = ScopeModule.new()
	Root.pushOwner(scope)
	local ok, err = pcall(fn)
	Root.popOwner()
	if not ok then
		scope:Destroy()
		error(err, 2)
	end
	return function()
		scope:Destroy()
	end
end

--[=[
	Returns the current owner Scope for the running coroutine, or nil when
	called outside any `root()` or `withScope()` context.
]=]
function Root.getScope(): Scope?
	return Root.currentOwner()
end

--[=[
	Runs `fn` with `scope` as the current owner. Restores the previous owner
	when `fn` returns or throws.
]=]
function Root.withScope(scope: Scope, fn: () -> ())
	Root.pushOwner(scope)
	local ok, err = pcall(fn)
	Root.popOwner()
	if not ok then
		error(err, 2)
	end
end

--[=[
	Registers `destroy` to run when `explicitScope` (if given) or the current
	implicit owner (Root.currentOwner()) is destroyed. No-op if neither is
	available. Shared by Computed.new and Effect.new for consistent
	owner-registration behavior.
]=]
function Root.registerWithOwner(explicitScope: Scope?, destroy: () -> ())
	local owner = explicitScope or Root.currentOwner()
	if owner ~= nil then
		owner:addTask(destroy)
	end
end

--[=[
	Destroys `previous` (if any), creates a fresh Scope, pushes it as the
	current owner, runs `fn` inside it, pops it, and returns
	(newScope, ok, err) — `ok`/`err` are pcall's results for `fn`. Used by
	Computed/Effect to implement their per-evaluation `_innerScope`
	(Types.InternalScopedRunner).
]=]
function Root.renewInnerScope(previous: Scope?, fn: () -> ()): (Scope, boolean, any)
	if previous ~= nil then
		previous:Destroy()
	end
	local scope = ScopeModule.new()
	Root.pushOwner(scope)
	local ok, err = pcall(fn)
	Root.popOwner()
	return scope, ok, err
end

return Root
