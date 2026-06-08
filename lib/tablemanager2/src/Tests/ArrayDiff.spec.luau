--!strict
--[[
	Tests for ArrayDiff.emitDiff — verifies that the LCS-based differ emits
	replay-faithful events for all combinations of insertions, removals, and sets.
]]

return function(t: tiniest)
	local ArrayDiff = require("../ArrayDiff")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- Helper: run emitDiff and collect events as a list of tagged records.
	local function diff(old: { any }, new: { any }, setMode: boolean?)
		local events: { { kind: string, index: number, value: any, oldValue: any? } } = {}
		local emit: ArrayDiff.Emit = {
			removed = function(i, ov)
				table.insert(events, { kind = "remove", index = i, value = ov, oldValue = nil })
			end,
			inserted = function(i, nv)
				table.insert(events, { kind = "insert", index = i, value = nv, oldValue = nil })
			end,
			set = function(i, nv, ov)
				table.insert(events, { kind = "set", index = i, value = nv, oldValue = ov })
			end,
		}
		ArrayDiff.emitDiff(old, new, emit, if setMode == nil then true else setMode)
		return events
	end

	-- Helper: apply a list of events to a copy of `old` and return the result.
	-- This verifies replay-faithfulness.
	local function replay(old: { any }, events: { any }): { any }
		local result: { any } = table.create(#old)
		for i = 1, #old do
			result[i] = old[i]
		end
		for _, ev in events do
			if ev.kind == "remove" then
				table.remove(result, ev.index)
			elseif ev.kind == "insert" then
				table.insert(result, ev.index, ev.value)
			elseif ev.kind == "set" then
				result[ev.index] = ev.value
			end
		end
		return result
	end

	local function arrayEq(a: { any }, b: { any }): boolean
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end

	describe("no-op", function()
		test("identical arrays emit nothing", function()
			local events = diff({ 1, 2, 3 }, { 1, 2, 3 })
			expect(#events).is(0)
		end)

		test("both empty emits nothing", function()
			local events = diff({}, {})
			expect(#events).is(0)
		end)
	end)

	describe("pure insertions", function()
		test("append one element", function()
			local old = { 1, 2 }
			local new = { 1, 2, 3 }
			local events = diff(old, new)
			expect(#events).is(1)
			expect(events[1].kind).is("insert")
			expect(events[1].index).is(3)
			expect(events[1].value).is(3)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("prepend one element", function()
			local old = { 2, 3 }
			local new = { 1, 2, 3 }
			local events = diff(old, new)
			expect(#events).is(1)
			expect(events[1].kind).is("insert")
			expect(events[1].index).is(1)
			expect(events[1].value).is(1)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("insert in the middle", function()
			local old = { 1, 3 }
			local new = { 1, 2, 3 }
			local events = diff(old, new)
			expect(#events).is(1)
			expect(events[1].kind).is("insert")
			expect(events[1].index).is(2)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("insert into empty array", function()
			local old: { any } = {}
			local new = { "a", "b" }
			local events = diff(old, new)
			expect(#events).is(2)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)
	end)

	describe("pure removals", function()
		test("remove last element", function()
			local old = { 1, 2, 3 }
			local new = { 1, 2 }
			local events = diff(old, new)
			expect(#events).is(1)
			expect(events[1].kind).is("remove")
			expect(events[1].value).is(3)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("remove first element — cursor does not advance", function()
			local old = { 1, 2, 3 }
			local new = { 2, 3 }
			local events = diff(old, new)
			expect(#events).is(1)
			expect(events[1].kind).is("remove")
			expect(events[1].index).is(1)
			expect(events[1].value).is(1)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("two consecutive front removals both report index 1", function()
			local old = { "a", "b", "c" }
			local new = { "c" }
			local events = diff(old, new)
			-- Both removals should land at index 1 (replay-faithful: remove(1) remove(1))
			local removes = {}
			for _, ev in events do
				if ev.kind == "remove" then
					table.insert(removes, ev)
				end
			end
			expect(#removes).is(2)
			expect(removes[1].index).is(1)
			expect(removes[2].index).is(1)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("remove all elements", function()
			local old = { 10, 20, 30 }
			local new: { any } = {}
			local events = diff(old, new)
			expect(#events).is(3)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)
	end)

	describe("sets (setMode = true)", function()
		test("single in-place replacement fuses into set", function()
			local old = { 1, 2, 3 }
			local new = { 1, 99, 3 }
			local events = diff(old, new, true)
			expect(#events).is(1)
			expect(events[1].kind).is("set")
			expect(events[1].index).is(2)
			expect(events[1].value).is(99)
			expect(events[1].oldValue).is(2)
		end)

		test("same-value replacement does NOT fuse into set (values equal)", function()
			-- remove+insert where old == new should NOT fuse (values are the same LCS)
			-- In practice the LCS diff would keep those elements, so no event at all.
			local old = { 1, 2, 3 }
			local new = { 1, 2, 3 }
			local events = diff(old, new, true)
			expect(#events).is(0)
		end)

		test("setMode=false emits remove+insert instead of set", function()
			local old = { 1, 2, 3 }
			local new = { 1, 99, 3 }
			local events = diff(old, new, false)
			-- Should be remove then insert, not a set
			expect(#events).is(2)
			local hasRemove = false
			local hasInsert = false
			for _, ev in events do
				if ev.kind == "remove" then
					hasRemove = true
				end
				if ev.kind == "insert" then
					hasInsert = true
				end
			end
			expect(hasRemove).is_true()
			expect(hasInsert).is_true()
		end)
	end)

	describe("mixed operations", function()
		test("insert and remove at different positions", function()
			local old = { "a", "b", "c" }
			local new = { "x", "b", "c", "y" }
			local events = diff(old, new)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("reorder elements (remove + insert)", function()
			local old = { 1, 2, 3 }
			local new = { 3, 1, 2 }
			local events = diff(old, new)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("interleaved inserts and removes", function()
			local old = { "a", "b", "c", "d" }
			local new = { "b", "x", "d", "y" }
			local events = diff(old, new)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)

		test("completely different arrays", function()
			local old = { 1, 2, 3 }
			local new = { 4, 5, 6 }
			local events = diff(old, new)
			expect(arrayEq(replay(old, events), new)).is_true()
		end)
	end)

	describe("replay faithfulness", function()
		-- These tests verify that applying events to `old` in order always yields `new`.
		local cases: { { old: { any }, new: { any } } } = {
			{ old = {}, new = { 1 } },
			{ old = { 1 }, new = {} },
			{ old = { 1, 2, 3 }, new = { 1, 3 } },
			{ old = { 1, 3 }, new = { 1, 2, 3 } },
			{ old = { "a", "b", "c" }, new = { "c", "b", "a" } },
			{ old = { 1, 2, 3, 4, 5 }, new = { 2, 4, 6 } },
		}

		for _, case in cases do
			local oldStr = table.concat(case.old :: { string }, ",")
			local newStr = table.concat(case.new :: { string }, ",")
			test(`replay {oldStr} -> {newStr}`, function()
				local events = diff(case.old, case.new)
				expect(arrayEq(replay(case.old, events), case.new)).is_true()
			end)
		end
	end)
end
