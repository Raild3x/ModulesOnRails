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

		test("an array append onto an ignored path updates state without firing", function()
			-- applyWrite's append fast path (Mutator.luau:386, `not ignored`): the
			-- appended value still lands but no ArrayInserted event fires.
			local manager = TableManager.new({ log = {} }, { IgnoredPaths = { { "log" } } })

			local inserted = 0
			manager:OnArrayInsert("log", function()
				inserted += 1
			end)

			-- key == #log + 1 makes this the append fast path.
			manager:Set({ "log", 1 }, "entry")

			expect(inserted).is(0)
			expect(manager:Get({ "log", 1 })).is("entry")

			manager:Destroy()
		end)

		test("ignoring the root (empty) path suppresses every write", function()
			-- IgnoreTrie's root short-circuit (IgnoreTrie.luau:50): marking the empty
			-- path ignored makes IsPathIgnored return true for every query.
			local manager = TableManager.new({ a = 1, b = { c = 2 } }, { IgnoredPaths = { {} } })

			local fired = 0
			manager:OnChange({}, function()
				fired += 1
			end)
			local signalFired = 0
			manager.ValueChanged:Connect(function()
				signalFired += 1
			end)

			manager:Set("a", 99)
			manager:Set({ "b", "c" }, 88)

			expect(fired).is(0)
			expect(signalFired).is(0)
			expect(manager:Get("a")).is(99)
			expect(manager:Get({ "b", "c" })).is(88)

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
