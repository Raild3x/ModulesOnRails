--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class DepTracker

	Shared dependency-tracking context stack for Computed and Effect nodes.
	When a Computed or Effect evaluates its function, it pushes a context onto
	the stack first. Any state access that calls `trackAccess()` during that
	window registers itself as a dependency of the currently-evaluating node.

	After evaluation, the collected context set is diffed against the node's
	previous dep set to add/remove signal connections with minimal churn.
]=]

local DepTracker = {}

-- Sentinel value shared with Computed so that DepTracker can identify Computed
-- objects without importing Computed.luau (which would create a circular dep).
DepTracker.COMPUTED_SENTINEL = {}

-- Stack of dep-collection contexts; each context maps state → true.
local _stack: { { [any]: true } } = {}

--[=[
	Pushes a new dep-collection context onto the stack and returns it.
	The caller must call `pop()` when the tracked evaluation completes
	(whether it succeeds or throws).
]=]
function DepTracker.push(): { [any]: true }
	local ctx: { [any]: true } = {}
	table.insert(_stack, ctx)
	return ctx
end

--[=[
	Pops the top dep-collection context from the stack.
]=]
function DepTracker.pop()
	table.remove(_stack)
end

--[=[
	Records `state` as a dependency of the currently-evaluating node.
	Safe to call outside any tracking context — it is a no-op in that case.
]=]
function DepTracker.trackAccess(state: any)
	local ctx = _stack[#_stack]
	if ctx ~= nil then
		ctx[state] = true
	end
end

--[=[
	Returns true when `v` is a Computed state object (identified by the shared
	sentinel set at construction time).
]=]
function DepTracker.isState(v: any): boolean
	return type(v) == "table" and rawget(v, "_isState") == DepTracker.COMPUTED_SENTINEL
end

return DepTracker
