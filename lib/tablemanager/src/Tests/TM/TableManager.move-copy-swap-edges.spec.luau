--!strict
--[[
	Edge coverage for MoveTo / CopyTo / Swap: the source == target short-circuit
	(a self-move/copy/swap is a no-op that returns before any mutation). These
	early returns are otherwise never exercised by the mutation suites.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("MoveTo (self path)", function()
		test("moving a path onto itself is a no-op", function()
			local manager = TableManager.new { a = { x = 1 } }
			local before = manager:Get("a")

			manager:MoveTo("a", "a")

			expect(manager:Get("a")).is(before) -- same table, untouched
			expect(manager:Get("a").x).is(1)

			manager:Destroy()
		end)
	end)

	describe("CopyTo (self path)", function()
		test("copying a path onto itself is a no-op", function()
			local manager = TableManager.new { a = { x = 1 } }
			local before = manager:Get("a")

			manager:CopyTo("a", "a")

			-- No clone was made and no write happened; the reference is unchanged.
			expect(manager:Get("a")).is(before)
			expect(manager:Get("a").x).is(1)

			manager:Destroy()
		end)
	end)

	describe("Swap (self path)", function()
		test("swapping a path with itself is a no-op", function()
			local manager = TableManager.new { a = 1, b = 2 }

			manager:Swap("a", "a")

			expect(manager:Get("a")).is(1)
			expect(manager:Get("b")).is(2)

			manager:Destroy()
		end)
	end)
end
