-- Authors: Logan Hunt (Raildex)
-- September 26, 2026

return function(t: tiniest)
	local OpenList = require("../OpenList")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- Deterministic LCG (Lune has no Random), high bits.
	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + math.floor(state / 2147483648 * (hi - lo + 1))
		end
	end

	-- A reference priority queue: an array kept sorted by key, ties in insertion order.
	local function reference()
		local items: { { number } } = {}
		return {
			push = function(node: number, key: number)
				local i = #items + 1
				while i > 1 and items[i - 1][2] > key do
					i -= 1
				end
				table.insert(items, i, { node, key })
			end,
			popKey = function(): number?
				local first = table.remove(items, 1)
				return first and first[2]
			end,
			size = function(): number
				return #items
			end,
		}
	end

	describe("OpenList (4-ary min-heap)", function()
		test("an empty list pops (0, 0) and has size 0", function()
			local o = OpenList.new()
			expect(OpenList.Size(o)).is(0)
			local node, key = OpenList.Pop(o)
			expect(node).is(0)
			expect(key).is(0)
		end)

		test("pops every entry in key order, matching a sorted reference", function()
			for seed = 1, 60 do
				local rng = makeRng(seed)
				local o, ref = OpenList.new(), reference()
				local pushed: { [number]: number } = {}
				-- Interleaved pushes and pops, with duplicate keys and a node pushed more than
				-- once (the search's stale entries).
				for step = 1, 400 do
					if rng(0, 2) > 0 or OpenList.Size(o) == 0 then
						local node, key = rng(1, 50), rng(0, 30)
						OpenList.Push(o, node, key)
						ref.push(node, key)
						pushed[node] = (pushed[node] or 0) + 1
					else
						local node, key = OpenList.Pop(o)
						expect(key).with_context(`seed {seed} step {step}`).is(ref.popKey())
						expect(pushed[node] ~= nil).is_true()
					end
					expect(OpenList.Size(o)).is(ref.size())
				end
				while OpenList.Size(o) > 0 do
					local _, key = OpenList.Pop(o)
					expect(key).with_context(`seed {seed} drain`).is(ref.popKey())
				end
				expect(OpenList.Pop(o)).is(0)
			end
		end)

		test("keeps every node it was given, including repeats", function()
			local o = OpenList.new()
			local counts: { [number]: number } = {}
			local rng = makeRng(7)
			for _ = 1, 200 do
				local node = rng(1, 20)
				OpenList.Push(o, node, rng(0, 1000) / 7)
				counts[node] = (counts[node] or 0) + 1
			end
			while OpenList.Size(o) > 0 do
				local node = OpenList.Pop(o)
				counts[node] -= 1
			end
			for node, remaining in counts do
				expect(remaining).with_context(`node {node}`).is(0)
			end
		end)

		test("fills and drains every heap depth (1 to 4 children at the last level)", function()
			for n = 1, 90 do
				local o = OpenList.new()
				for i = n, 1, -1 do
					OpenList.Push(o, i, i)
				end
				for i = 1, n do
					local node, key = OpenList.Pop(o)
					expect(node).with_context(`n {n}`).is(i)
					expect(key).is(i)
				end
			end
		end)

		test("Clear empties the list and it works again afterwards", function()
			local o = OpenList.new()
			for i = 1, 10 do
				OpenList.Push(o, i, 10 - i)
			end
			OpenList.Clear(o)
			expect(OpenList.Size(o)).is(0)
			expect(OpenList.Pop(o)).is(0)
			OpenList.Push(o, 3, 2.5)
			OpenList.Push(o, 4, 1.5)
			expect(OpenList.Pop(o)).is(4)
			expect(OpenList.Pop(o)).is(3)
		end)
	end)
end
