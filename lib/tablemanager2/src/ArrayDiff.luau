--!strict
--[=[
	@ignore
	@class ArrayDiff

	Emits `ArrayRemoved` / `ArrayInserted` / `ArraySet` events from an old array to a new one.

	## Index Contract

	Emitted indices are **replay-faithful**: applying events in order to a copy of `old`
	reconstructs `new`. The index reported is the element's position *at the moment that
	event is applied*, accounting for prior shifts.

	Consequence: two consecutive removals of the first two elements report `Remove(1) Remove(1)`
	— the cursor does not advance on removal.

	## Usage

	```lua
	local emit: ArrayDiff.Emit = {
		removed  = function(index, oldValue) ... end,
		inserted = function(index, newValue) ... end,
		set      = function(index, newValue, oldValue) ... end,
	}

	ArrayDiff.emitDiff(oldArray, newArray, emit, true)
	```

	## `setMode` (fuse gate)

	When `setMode = true`, an adjacent remove+insert at the same live index where
	`oldValue ~= newValue` collapses into a single `set` call instead of separate
	`removed` + `inserted` calls. Pass `false` to always emit them separately.
]=]

--// Types //--

export type Emit = {
	removed: (index: number, oldValue: any) -> (),
	inserted: (index: number, newValue: any) -> (),
	set: (index: number, newValue: any, oldValue: any) -> (),
}

-- Op kinds collected during LCS backtrack, in forward order.
type Op = {
	kind: string, -- "keep" | "remove" | "insert"
	value: any,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ArrayDiff = {}

--[=[
	@within ArrayDiff
	@function buildLCS

	Builds the LCS (Longest Common Subsequence) DP table for `old` and `new`.
]=]
const function buildLCS(old: { any }, new: { any }): { { number } }
	const n, m = #old, #new
	const dp = table.create(n + 1)

	for i = 0, n do
		dp[i + 1] = table.create(m + 1, 0)
	end

	for i = 1, n do
		const oldVal = old[i]
		const rowAbove = dp[i]
		const rowHere = dp[i + 1]

		for j = 1, m do
			if oldVal == new[j] then
				rowHere[j + 1] = rowAbove[j] + 1
			else
				const up = rowAbove[j + 1]
				const left = rowHere[j]
				rowHere[j + 1] = if up >= left then up else left
			end
		end
	end

	return dp
end

--[=[
	@within ArrayDiff
	@function backtrack

	Backtracks through the LCS DP table and returns ops in **forward** order.
]=]
const function backtrack(old: { any }, new: { any }, dp: { { number } }): { Op }
	-- Walk backward; collect in reverse, then flip.
	const reversed: { Op } = {}
	local i, j = #old, #new

	while i > 0 or j > 0 do
		if i > 0 and j > 0 and old[i] == new[j] then
			table.insert(reversed, { kind = "keep", value = old[i] })
			i -= 1
			j -= 1
		elseif j > 0 and (i == 0 or dp[i + 1][j] >= dp[i][j + 1]) then
			-- new[j] is an insertion
			table.insert(reversed, { kind = "insert", value = new[j] })
			j -= 1
		else
			-- old[i] is a removal
			table.insert(reversed, { kind = "remove", value = old[i] })
			i -= 1
		end
	end

	const fwd: { Op } = table.create(#reversed)
	for k = #reversed, 1, -1 do
		fwd[#fwd + 1] = reversed[k]
	end

	return fwd
end

--[=[
	@within ArrayDiff
	@function emitDiff

	Diffs `old` against `new` and fires `emit` callbacks with replay-faithful indices.

	@param old {any} -- The array before changes.
	@param new {any} -- The array after changes.
	@param emit Emit -- Callback table: `removed`, `inserted`, `set`.
	@param setMode boolean -- When true, fuses adjacent remove+insert at the same live index
	               (with differing values) into a single `set` call.
]=]
function ArrayDiff.emitDiff(old: { any }, new: { any }, emit: Emit, setMode: boolean)
	const dp = buildLCS(old, new)
	const ops = backtrack(old, new, dp)

	-- Replay cursor: tracks the live index of the next slot as events are applied.
	local cursor = 1
	local k = 1
	const count = #ops

	while k <= count do
		const op = ops[k]

		if op.kind == "keep" then
			cursor += 1
			k += 1
		elseif op.kind == "remove" then
			const nextOp = ops[k + 1]

			-- Fuse gate: remove immediately followed by insert at the SAME live index,
			-- with a genuinely different value → collapse into a single ArraySet.
			if setMode and nextOp ~= nil and nextOp.kind == "insert" and op.value ~= nextOp.value then
				emit.set(cursor, nextOp.value, op.value)
				cursor += 1 -- slot stays occupied; advance past it
				k += 2 -- consumed both ops
			else
				emit.removed(cursor, op.value)
				-- Cursor does NOT advance: the slot collapsed, the next element
				-- shifts down into `cursor`.
				k += 1
			end
		else -- "insert"
			emit.inserted(cursor, op.value)
			cursor += 1
			k += 1
		end
	end
end

return ArrayDiff
