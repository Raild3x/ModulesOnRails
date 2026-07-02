--!strict
--[[
	Integration coverage for `TableManagerConfig.IgnoredPaths` and the runtime
	`tm:SetPathIgnored(path, ignored)`: a write under an ignored prefix still
	happens (Get/Raw reflect it) but skips all diff/snapshot/event work.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("IgnoredPaths / SetPathIgnored", function()
		test("IgnoredPaths config suppresses writes under that prefix; sibling paths fire normally", function()
			local manager = TableManager.new(
				{ debug = { counter = 0 }, score = 0 },
				{ IgnoredPaths = { { "debug" } } }
			)

			local debugFired = 0
			local scoreFired = 0
			manager:OnChange({ "debug" }, function()
				debugFired += 1
			end)
			manager:OnChange({ "score" }, function()
				scoreFired += 1
			end)

			manager:Set({ "debug", "counter" }, 1)
			manager:Set("score", 10)

			expect(manager:Get { "debug", "counter" }).is(1) -- still written
			expect(debugFired).is(0)
			expect(scoreFired).is(1)

			manager:Destroy()
		end)

		test("SetPathIgnored(path, true) suppresses writes at runtime", function()
			local manager = TableManager.new { debug = { counter = 0 } }

			local fired = 0
			manager:OnChange({ "debug" }, function()
				fired += 1
			end)

			manager:Set({ "debug", "counter" }, 1)
			expect(fired).is(1) -- not yet ignored

			manager:SetPathIgnored({ "debug" }, true)
			manager:Set({ "debug", "counter" }, 2)

			expect(fired).is(1) -- unchanged: second write suppressed
			expect(manager:Get { "debug", "counter" }).is(2) -- still written

			manager:Destroy()
		end)

		test("an ignored descendant inside a larger write is pruned; sibling branches still fire", function()
			local manager = TableManager.new { player = { hp = 100, debugCounter = 0 }, score = 0 }
			manager:SetPathIgnored({ "player", "debugCounter" }, true)

			local hpFired = 0
			local debugFired = 0
			local scoreFired = 0
			manager:OnChange({ "player", "hp" }, function()
				hpFired += 1
			end)
			manager:OnChange({ "player", "debugCounter" }, function()
				debugFired += 1
			end)
			manager:OnChange({ "score" }, function()
				scoreFired += 1
			end)

			-- Root replacement: a single write that touches every branch at once.
			manager:Set({}, { player = { hp = 50, debugCounter = 999 }, score = 5 })

			expect(hpFired).is(1)
			expect(debugFired).is(0)
			expect(scoreFired).is(1)
			expect(manager:Get { "player", "debugCounter" }).is(999) -- still written

			manager:Destroy()
		end)

		test("SetPathIgnored(path, false) re-enables firing", function()
			local manager = TableManager.new { debug = { counter = 0 } }
			manager:SetPathIgnored({ "debug" }, true)

			local fired = 0
			manager:OnChange({ "debug" }, function()
				fired += 1
			end)

			manager:Set({ "debug", "counter" }, 1)
			expect(fired).is(0)

			manager:SetPathIgnored({ "debug" }, false)
			manager:Set({ "debug", "counter" }, 2)

			expect(fired).is(1)
			expect(manager:Get { "debug", "counter" }).is(2)

			manager:Destroy()
		end)

		test("ignoring the exact path of a value still allows reads to see writes", function()
			local manager = TableManager.new { x = 1 }
			manager:SetPathIgnored({ "x" }, true)

			local fired = 0
			manager:OnChange({ "x" }, function()
				fired += 1
			end)

			manager:Set("x", 2)
			manager:Set("x", 3)

			expect(fired).is(0)
			expect(manager:Get("x")).is(3)

			manager:Destroy()
		end)
	end)
end
