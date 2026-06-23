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
	propagation, no explicit Link call). That behavior does not exist until
	Phase 3, so the implicit-propagation assertions are gated behind
	`IMPLICIT_SHARING_ENABLED`. The explicit-`Link` tests below exercise the
	same propagation guarantees against today's implementation and become the
	regression watch the implicit model must keep satisfying.

	When Phase 3 lands: flip `IMPLICIT_SHARING_ENABLED` to true. The
	"current behavior: unlinked sharing does NOT propagate" test is inverted by
	the flag (it documents the pre-Phase-3 reality and turns off once implicit
	propagation is the contract).
]]

-- Phase 3 gate. Flip to `true` when implicit shared-identity propagation lands.
-- Typed `boolean` (not inferred `false`) so both branches stay type-checked and
-- the analyzer does not flag the Phase-3 branch as unreachable.
local IMPLICIT_SHARING_ENABLED: boolean = false

return function(t: tiniest)
	local TableManager = require("../../TableManager")
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

	describe("Shared interior region — implicit (Phase 3 target)", function()
		if IMPLICIT_SHARING_ENABLED then
			test("two managers sharing a table propagate to each other WITHOUT an explicit Link", function()
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
		else
			-- Pre-Phase-3 reality: a shared reference mutates BOTH raw tables (pass
			-- by reference) but does NOT fire events on the non-writing manager
			-- without a Link. This documents the starting point; it is removed once
			-- IMPLICIT_SHARING_ENABLED flips.
			test("current behavior: unlinked shared region does NOT propagate events", function()
				local _stats, playerTM, tycoonTM = makeSharedScenario()

				local tycoonFires = 0
				tycoonTM:OnChange({ "Stats" }, function()
					tycoonFires += 1
				end)

				playerTM:Set({ "Stats", "health" }, 50)

				expect(tycoonFires).is(0)
				-- Raw IS shared by reference, so the value is present even though no
				-- event fired on tycoon.
				expect(tycoonTM.Raw.Stats.health).is(50)

				playerTM:Destroy()
				tycoonTM:Destroy()
			end)
		end
	end)
end
