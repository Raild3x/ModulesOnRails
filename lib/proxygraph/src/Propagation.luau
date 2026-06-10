--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Propagation

	Manages the global write-generation counter used to deduplicate ancestor
	notifications in diamond-shaped graphs. Two helpers — beginWrite /
	endWrite — implement a nesting depth so that recursive _set calls
	(triggered during structural reconciliation) share the same generation
	as the top-level write that started the operation.
]=]

local Propagation = {}

-- Monotonically increasing counter bumped once per top-level write (or at
-- batch flush). Stored on each visited ProxyNode as _nodeGeneration[node] so
-- walkParents can skip nodes that were already notified this generation.
Propagation._generation = 0

-- Nesting depth. When > 0 we are inside a recursive _set call originated by
-- a top-level write; the generation must NOT be bumped again.
Propagation._depth = 0

-- Per-node last-notified generation, keyed by proxy userdata.
-- Shared with ProxyNode via this exported table reference.
Propagation._nodeGeneration = {} :: { [any]: number }

--[=[
	Call at the start of every _set path. Returns the current generation,
	bumping it only when depth is zero (i.e. this is a new top-level write).
]=]
function Propagation.beginWrite(): number
	if Propagation._depth == 0 then
		Propagation._generation += 1
	end
	Propagation._depth += 1
	return Propagation._generation
end

--[=[
	Call after a _set path completes (must be paired with beginWrite).
]=]
function Propagation.endWrite()
	Propagation._depth -= 1
end

--[=[
	Returns the current generation without modifying state.
	Used by the Batch flush to stamp all deferred changes with a consistent
	generation.
]=]
function Propagation.currentGeneration(): number
	return Propagation._generation
end

return Propagation
