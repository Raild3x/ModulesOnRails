--!strict
--[[
	Unit tests for FastDefer: deferred execution, argument passthrough, and the
	thread-pool reuse that's the whole point of this module over plain `task.defer`.
]]

return function(t: tiniest)
	local FastDefer = require("../FastDefer")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- Polls `condition` instead of a single `task.wait()`: deferred work always
	-- eventually runs, but bounding the loop turns a wrong assumption about
	-- scheduler ordering into a clear test failure instead of a hung test run.
	local function waitUntil(condition: () -> boolean, maxTicks: number?)
		local ticksLeft = maxTicks or 100
		while not condition() and ticksLeft > 0 do
			task.wait()
			ticksLeft -= 1
		end
	end

	describe("FastDefer", function()
		test("runs the callback deferred, not synchronously", function()
			local ran = false
			FastDefer(function()
				ran = true
			end)

			expect(ran).never_is_true()

			waitUntil(function()
				return ran
			end)
			expect(ran).is_true()
		end)

		test("passes arguments through to the callback", function()
			local received: { any }? = nil
			FastDefer(function(a, b)
				received = { a, b }
			end, "x", 42)

			waitUntil(function()
				return received ~= nil
			end)

			expect(received).exists()
			local values = received :: { any }
			expect(values[1]).is("x")
			expect(values[2]).is(42)
		end)

		test("reuses the same thread across sequential synchronous calls", function()
			local seenThreads: { [thread]: true } = {}
			local distinctThreadCount = 0

			for _ = 1, 5 do
				local done = false
				FastDefer(function()
					local thread = coroutine.running()
					if not seenThreads[thread] then
						seenThreads[thread] = true
						distinctThreadCount += 1
					end
					done = true
				end)

				-- Flush this deferred call before scheduling the next one so each
				-- callback returns synchronously and its thread rejoins the pool.
				waitUntil(function()
					return done
				end)
				expect(done).is_true()
			end

			expect(distinctThreadCount).is(1)
		end)
	end)
end
