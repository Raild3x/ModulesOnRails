--!strict
--[[
	Specs for `TableManager:GetLastEmitted(path)` (CONTRACT.md §5 "Reads").

	`GetLastEmitted` returns the value listeners LAST SAW at `path` — the internal
	"last-emitted" baseline — which lags the live `Get` value while a flush is
	pending (a `Suspend`/`Batch` window, or `FlushMode = "coalesced"`). Under
	immediate flush with no pending changes it equals `Get`, and for a path that was
	never observed (no baseline recorded) it falls back to a live `Get`.
]]

return function(tiniest)
	local TableManager = require("../../TableManager")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("GetLastEmitted", function()
		test("equals Get under immediate flush with no pending changes", function()
			local manager = TableManager.new({ player = { health = 100 } })
			manager:OnValueChange("player.health", function() end)

			expect(manager:GetLastEmitted("player.health")).is(manager:Get("player.health"))

			manager:Set("player.health", 60)
			-- Immediate flush already emitted 60, so both agree.
			expect(manager:Get("player.health")).is(60)
			expect(manager:GetLastEmitted("player.health")).is(60)

			manager:Destroy()
		end)

		test("falls back to the live value for a never-observed path", function()
			local manager = TableManager.new({ coins = 0 })
			-- No listener/signal covers "coins": no baseline is ever recorded.
			manager:Set("coins", 42)

			-- Falls back to a live Get rather than returning nil.
			expect(manager:GetLastEmitted("coins")).is(42)
			expect(manager:GetLastEmitted("coins")).is(manager:Get("coins"))

			manager:Destroy()
		end)

		test("lags the live value while a coalesced flush is pending, then converges", function()
			local manager = TableManager.new({ Score = 0 }, { FlushMode = "coalesced" })
			-- Observe so a baseline is kept for "Score".
			manager:OnValueChange("Score", function() end)

			manager:Set("Score", 10) -- schedules a frame-end flush; not drained yet

			-- Live value moved ahead; listeners have not been told yet.
			expect(manager:Get("Score")).is(10)
			expect(manager:GetLastEmitted("Score")).is(0)

			task.wait() -- let the deferred flush run

			expect(manager:GetLastEmitted("Score")).is(10)
			expect(manager:GetLastEmitted("Score")).is(manager:Get("Score"))

			manager:Destroy()
		end)

		test("holds the pre-batch value inside a Suspend window, then converges on Resume", function()
			local manager = TableManager.new({ x = 0 })
			manager:OnValueChange("x", function() end)

			-- Establish the baseline via an immediate write (emits 1).
			manager:Set("x", 1)
			expect(manager:GetLastEmitted("x")).is(1)

			manager:Suspend()
			manager:Set("x", 2) -- batched: nothing emitted yet

			expect(manager:Get("x")).is(2)          -- live
			expect(manager:GetLastEmitted("x")).is(1) -- last emitted

			manager:Resume()

			expect(manager:GetLastEmitted("x")).is(2)
			expect(manager:GetLastEmitted("x")).is(manager:Get("x"))

			manager:Destroy()
		end)

		test("returns nil once an observed path's last-emitted value is a deletion", function()
			local manager = TableManager.new({ buff = "speed" })
			manager:OnValueChange("buff", function() end)

			manager:Set("buff", nil) -- emitted removal

			expect(manager:GetLastEmitted("buff")).never_exists()
			expect(manager:Get("buff")).never_exists()

			manager:Destroy()
		end)

		test("known limitation: last-emitted nil reads the pending live value inside a window", function()
			-- Documents a KNOWN LIMITATION, not the ideal contract (CONTRACT.md §5):
			-- the baseline cannot distinguish "never observed" from "observed, last
			-- emitted value was nil" -- an absent key and a nil-valued key are the same
			-- in the store -- so both fall back to a live Get. When the last emit was a
			-- deletion AND the live value has since moved ahead inside a pending flush,
			-- GetLastEmitted returns that pending live value rather than the emitted nil.
			local manager = TableManager.new({ buff = "speed" })
			manager:OnValueChange("buff", function() end)

			manager:Set("buff", nil) -- emitted removal: last-emitted value is now nil
			expect(manager:GetLastEmitted("buff")).never_exists() -- exact while live is also nil

			manager:Suspend()
			manager:Set("buff", "shield") -- batched: nothing emitted yet; last emit is still nil

			expect(manager:Get("buff")).is("shield") -- live has moved ahead
			-- IDEAL contract would be nil (the emitted deletion); current behavior falls
			-- back to the pending live value because the nil baseline is indistinguishable
			-- from "never observed".
			expect(manager:GetLastEmitted("buff")).is("shield")

			manager:Resume() -- flush drains; baseline catches up to the live value

			expect(manager:GetLastEmitted("buff")).is("shield")
			expect(manager:GetLastEmitted("buff")).is(manager:Get("buff"))

			manager:Destroy()
		end)

		test("accepts array paths equivalently to string paths", function()
			local manager = TableManager.new({ player = { mana = 30 } })
			manager:OnValueChange("player.mana", function() end)

			manager:Set("player.mana", 15)

			expect(manager:GetLastEmitted({ "player", "mana" })).is(15)
			expect(manager:GetLastEmitted({ "player", "mana" })).is(manager:GetLastEmitted("player.mana"))

			manager:Destroy()
		end)
	end)
end
