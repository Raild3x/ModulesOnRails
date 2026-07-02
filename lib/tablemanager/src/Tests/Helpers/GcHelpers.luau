--!strict
--[[
	Test helpers for memory-leak specs.

	Luau supports weak tables but NOT forced garbage collection (`collectgarbage`
	only accepts "count") and has no __gc metamethod. Collectability is therefore
	probed by holding the target in a weak-valued table and driving the
	incremental collector with allocation pressure until the weak reference
	clears or an iteration cap is reached.
]]

--[=[
	@class GcHelpers
	@ignore

	Test helpers for memory-leak specs.
]=]
const GcHelpers = {}

-- Elements per throwaway allocation in WaitForCollection. Large enough that the
-- cap'd loop allocates tens of MB total, which spans several full GC cycles.
const PRESSURE_ALLOCATION_SIZE = 4096
const DEFAULT_MAX_STEPS = 10000

--[[
	Holds `value` in a weak-valued table and returns a probe function reporting
	whether the value is still uncollected. Callers must drop every strong
	reference to `value` (including local variables) before polling the probe.
]]
function GcHelpers.WeakProbe(value: any): () -> boolean
	const holder = setmetatable({ value }, { __mode = "v" })
	return function(): boolean
		return holder[1] ~= nil
	end
end

--[[
	Allocates throwaway garbage (which advances Luau's incremental collector,
	stepping proportionally to allocation volume) until `isAlive` reports
	collection or `maxSteps` allocations have been made.
	Returns true if the probed value was collected.
]]
function GcHelpers.WaitForCollection(isAlive: () -> boolean, maxSteps: number?): boolean
	const steps = maxSteps or DEFAULT_MAX_STEPS
	for i = 1, steps do
		if not isAlive() then
			return true
		end
		const garbage = table.create(PRESSURE_ALLOCATION_SIZE, i)
		garbage[1] = i
	end
	return not isAlive()
end

--- Counts the keys currently present in a (possibly weak) map.
function GcHelpers.CountKeys(map: { [any]: any }): number
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

return GcHelpers
