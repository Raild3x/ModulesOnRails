--!strict
--[[
	Golden specs for shared-region cross-manager propagation (see
	~/.claude/plans/evaluate-if-starting-from-elegant-lagoon.md and
	Docs/CONTRACT.md §8).

	The model is "sharing a table identity = being linked": a region shared by two
	managers (interior, e.g. Player.Stats and Tycoon.Stats) propagates a single
	change to BOTH observers, exactly once each, with a defined order and no missed
	event — with NO explicit link call. Propagation rides the identity-keyed
	observer registry (see `Propagation`); opacity is the opt-out.
]]

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

	describe("Shared interior region — implicit (no explicit link)", function()
		test("a single write propagates ValueChanged to BOTH observers exactly once", function()
			local _stats, playerTM, tycoonTM = makeSharedScenario()

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

			local stream: { any } = {}
			local recP = ReplicationHarness.RecordEvents(playerTM, "player", stream)
			local recT = ReplicationHarness.RecordEvents(tycoonTM, "tycoon", stream)

			playerTM:Set({ "Stats", "mana" }, 10)

			-- LOCKED ORDER: origin first, then propagated observers.
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

	describe("Shared interior region — opacity is the boundary", function()
		test("a manager that marks a shared region opaque is not a co-observer of it", function()
			-- `playerTM` marks its `Stats` opaque (via Set, the supported way — the
			-- bare `stats` is stored and marked opaque); the opaque value is never
			-- registered, so it does not participate in implicit sharing even though
			-- `tycoonTM` references the same live table transparently.
			local stats = { health = 100, mana = 50 }
			local tycoonTM = TableManager.new { Stats = stats }
			-- Construct WITHOUT `stats` so it is never registered transparently first,
			-- then attach it as an opaque leaf.
			local playerTM = TableManager.new { Owner = "Bob" }
			playerTM:Set("Stats", TableManager.Opaque(stats))

			expect(playerTM.Linker:IsLinkedWith(tycoonTM)).never_is_true()
			expect(tycoonTM.Linker:IsLinkedWith(playerTM)).never_is_true()

			local playerFires = 0
			playerTM:OnChange({ "Stats" }, function()
				playerFires += 1
			end)

			-- `tycoon` writes the shared table transparently; `player` was never
			-- registered as an observer of it, so it receives no cross-manager event
			-- (the shared raw still updates by reference).
			tycoonTM:Set({ "Stats", "health" }, 50)

			expect(playerFires).is(0)
			expect(playerTM.Raw.Stats.health).is(50)

			playerTM:Destroy()
			tycoonTM:Destroy()
		end)
	end)
end
