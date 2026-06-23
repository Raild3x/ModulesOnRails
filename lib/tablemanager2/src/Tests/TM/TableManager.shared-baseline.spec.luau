--!strict
--[[
	Phase 0 golden specs for the shadow/linking/opacity re-architecture
	(see ~/.claude/plans/evaluate-if-starting-from-elegant-lagoon.md and
	Docs/CONTRACT.md §8).

	These lock the OBSERVABLE behavior of shared regions and cross-manager
	propagation so the rewrite is held to it:

	  * Tasks 0.3 / 0.5 — a region shared by two managers (interior, e.g.
	    Player.Stats and Tycoon.Stats) propagates a single change to BOTH
	    observers, exactly once each, with a defined order and no missed event.

	The TARGET model is "sharing a table identity = being linked" (implicit
	propagation, no explicit Link call), implemented in Phase 3 behind a runtime
	flag (`LinkGroup.SetImplicitSharing`). The implicit tests below enable that
	flag for their duration; the explicit-`Link` tests exercise the same
	propagation guarantees against the always-on path and are the regression watch
	the implicit model must keep satisfying.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local LinkGroup = require("../../LinkGroup")
	local ReplicationHarness = require("../Helpers/ReplicationHarness")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- Builds a Player manager and a Tycoon manager that SHARE one `stats` table
	-- at an interior path on each (Player.Stats and Tycoon.Stats).
	local function makeSharedScenario()
		local stats = { health = 100, mana = 50 }
		local playerTM = TableManager.new { Stats = stats, Name = "Bob" }
		local tycoonTM = TableManager.new { Stats = stats, Owner = "Bob" }
		return stats, playerTM, tycoonTM
	end

	-- Returns the recorded entries for (manager label, signal) in order.
	local function entriesFor(stream: { any }, manager: string, signal: string): { any }
		local out = {}
		for _, entry in stream do
			if entry.Manager == manager and entry.Signal == signal then
				table.insert(out, entry)
			end
		end
		return out
	end

	-- Index of the first stream entry matching (manager, signal), or nil.
	local function firstIndexOf(stream: { any }, manager: string, signal: string): number?
		for i, entry in stream do
			if entry.Manager == manager and entry.Signal == signal then
				return i
			end
		end
		return nil
	end

	describe("Shared interior region — explicit Link (current behavior, must keep passing)", function()
		test("a single write propagates ValueChanged to BOTH observers exactly once", function()
			local _stats, playerTM, tycoonTM = makeSharedScenario()
			TableManager.Link({ { playerTM, "Stats" }, { tycoonTM, "Stats" } })

			local stream: { any } = {}
			local recP = ReplicationHarness.RecordEvents(playerTM, "player", stream)
			local recT = ReplicationHarness.RecordEvents(tycoonTM, "tycoon", stream)

			playerTM:Set({ "Stats", "health" }, 50)

			local playerVC = entriesFor(stream, "player", "ValueChanged")
			local tycoonVC = entriesFor(stream, "tycoon", "ValueChanged")

			-- Each observer saw the change exactly once, at its OWN path, with the
			-- same old/new (the shared baseline must not drop or duplicate it).
			expect(#playerVC).is(1)
			expect(#tycoonVC).is(1)
			expect(playerVC[1].Path).is_shallow_equal { "Stats", "health" }
			expect(tycoonVC[1].Path).is_shallow_equal { "Stats", "health" }
			expect(playerVC[1].New).is(50)
			expect(playerVC[1].Old).is(100)
			expect(tycoonVC[1].New).is(50)
			expect(tycoonVC[1].Old).is(100)

			recP.Disconnect()
			recT.Disconnect()
			playerTM:Destroy()
			tycoonTM:Destroy()
		end)

		test("propagation order is defined: the originating manager fires before the propagated one", function()
			local _stats, playerTM, tycoonTM = makeSharedScenario()
			TableManager.Link({ { playerTM, "Stats" }, { tycoonTM, "Stats" } })

			local stream: { any } = {}
			local recP = ReplicationHarness.RecordEvents(playerTM, "player", stream)
			local recT = ReplicationHarness.RecordEvents(tycoonTM, "tycoon", stream)

			playerTM:Set({ "Stats", "mana" }, 10)

			-- LOCKED ORDER (Phase 0 decision): origin first, then propagated members.
			local originIndex = firstIndexOf(stream, "player", "ValueChanged")
			local propagatedIndex = firstIndexOf(stream, "tycoon", "ValueChanged")
			expect(originIndex).exists()
			expect(propagatedIndex).exists()
			expect((originIndex :: number) < (propagatedIndex :: number)).is_true()

			recP.Disconnect()
			recT.Disconnect()
			playerTM:Destroy()
			tycoonTM:Destroy()
		end)

		test("no missed event regardless of which side originates the write", function()
			local _stats, playerTM, tycoonTM = makeSharedScenario()
			TableManager.Link({ { playerTM, "Stats" }, { tycoonTM, "Stats" } })

			local playerFires, tycoonFires = 0, 0
			playerTM:OnChange({ "Stats" }, function()
				playerFires += 1
			end)
			tycoonTM:OnChange({ "Stats" }, function()
				tycoonFires += 1
			end)

			playerTM:Set({ "Stats", "health" }, 75) -- originate on player
			tycoonTM:Set({ "Stats", "mana" }, 5) -- originate on tycoon

			expect(playerFires).is(2)
			expect(tycoonFires).is(2)
			expect(playerTM.Raw.Stats.health).is(75)
			expect(tycoonTM.Raw.Stats.health).is(75)
			expect(playerTM.Raw.Stats.mana).is(5)
			expect(tycoonTM.Raw.Stats.mana).is(5)

			playerTM:Destroy()
			tycoonTM:Destroy()
		end)
	end)

	-- Runs `body` with implicit sharing enabled, restoring the flag afterward even
	-- if an assertion throws (the flag is module-global, so leaking it on would
	-- affect other specs).
	local function withImplicitSharing(body: () -> ())
		LinkGroup.SetImplicitSharing(true)
		local ok, err = pcall(body)
		LinkGroup.SetImplicitSharing(false)
		if not ok then
			error(err, 0)
		end
	end

	describe("Shared interior region — implicit (no explicit Link)", function()
		test("two managers sharing a table propagate to each other WITHOUT an explicit Link", function()
			withImplicitSharing(function()
				local _stats, playerTM, tycoonTM = makeSharedScenario()
				-- NOTE: no TableManager.Link call — sharing the identity is enough.

				local stream: { any } = {}
				local recP = ReplicationHarness.RecordEvents(playerTM, "player", stream)
				local recT = ReplicationHarness.RecordEvents(tycoonTM, "tycoon", stream)

				playerTM:Set({ "Stats", "health" }, 50)

				expect(#entriesFor(stream, "player", "ValueChanged")).is(1)
				expect(#entriesFor(stream, "tycoon", "ValueChanged")).is(1)
				expect(tycoonTM.Raw.Stats.health).is(50)

				recP.Disconnect()
				recT.Disconnect()
				playerTM:Destroy()
				tycoonTM:Destroy()
			end)
		end)
	end)

	describe("Shared interior region — implicit OFF (default)", function()
		test("with implicit sharing disabled, an unlinked shared region does NOT propagate events", function()
			-- Default behavior: a shared reference mutates BOTH raw tables (pass by
			-- reference) but fires events only on the writing manager.
			local _stats, playerTM, tycoonTM = makeSharedScenario()

			local tycoonFires = 0
			tycoonTM:OnChange({ "Stats" }, function()
				tycoonFires += 1
			end)

			playerTM:Set({ "Stats", "health" }, 50)

			expect(tycoonFires).is(0)
			expect(tycoonTM.Raw.Stats.health).is(50)

			playerTM:Destroy()
			tycoonTM:Destroy()
		end)
	end)
end
