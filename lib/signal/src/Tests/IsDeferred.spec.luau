--!strict
--[[
	Unit tests for IsDeferred: result type, caching, and the expected outcome when run
	outside the Roblox engine (this test suite always runs under Lune).
]]

return function(t: tiniest)
	local IsDeferred = require("../IsDeferred")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("IsDeferred", function()
		test("returns a boolean", function()
			expect(IsDeferred()).is_a("boolean")
		end)

		test("caches its result across calls", function()
			local first = IsDeferred()
			local second = IsDeferred()

			expect(first).is(second)
		end)

		test("reports deferred when Instance.new is unavailable (this Lune environment)", function()
			-- `Instance.new("BindableEvent")` doesn't exist outside the Roblox engine, so the
			-- pcall guard in IsDeferred.luau fails, `handlerRun` stays false, and the result
			-- defaults to "deferred" (the safer assumption for non-Roblox hosts).
			expect(IsDeferred()).is_true()
		end)
	end)
end
