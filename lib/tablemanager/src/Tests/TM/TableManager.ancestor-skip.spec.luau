--!strict
--[[
	Specs for the ancestor-notification level skip (Phase B / spine resolution):
	`EmitAncestorNotifications` consults `ListenerRegistry.PrimeAncestorSpine` to
	skip ancestor levels that have no listener registered exactly there — every fire
	on such a level is a no-op today (an ancestor notification carries `Diff == nil`,
	so it never fires the public Signals, only exact-node listeners). The same
	priming lets the surviving levels fire by node index rather than re-walking the
	registry tree from the root (`FireListenersExact`'s fire-by-node fast path).

	These pin OBSERVABLE EQUIVALENCE with the pre-skip behavior: every real
	ancestor listener (ValueChanged AND the parent-level KeyChanged delivery) still
	fires exactly as before, at every spot around the manager, including the
	re-entrancy-sensitive case where a listener connects a NEW ancestor listener
	mid-dispatch (the spine is resolved at fire time, so the new one is still seen).
]]

return function(tiniest)
	local TableManager = require("../../TableManager")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Ancestor notification level skip", function()
		test("root and intermediate ancestor OnChange both fire once for a deep write", function()
			local manager = TableManager.new { a = { b = { c = { v = 1 } } } }

			local rootFires = 0
			local midFires = 0
			manager:OnChange({}, function()
				rootFires += 1
			end)
			manager:OnChange("a.b", function()
				midFires += 1
			end)

			manager:Set("a.b.c.v", 2)

			-- Both are ancestors of the change; the empty levels between them
			-- ({"a"}, {"a","b","c"}) are skipped, but neither real listener is dropped.
			expect(rootFires).is(1)
			expect(midFires).is(1)

			manager:Destroy()
		end)

		test("an unrelated sibling-branch listener never fires for the write", function()
			local manager = TableManager.new { a = { b = { v = 1 } }, other = { z = 0 } }

			local otherFires = 0
			manager:OnChange("other", function()
				otherFires += 1
			end)
			-- A covering ancestor so the write is tracked and the ancestor walk runs.
			local rootFires = 0
			manager:OnChange({}, function()
				rootFires += 1
			end)

			manager:Set("a.b.v", 2)

			expect(rootFires).is(1)
			expect(otherFires).is(0)

			manager:Destroy()
		end)

		test("OnKeyChange at an intermediate ancestor still fires for a deep write", function()
			local manager = TableManager.new { a = { b = { c = 1 } } }

			local keys: { any } = {}
			manager:OnKeyChange("a", function(key)
				table.insert(keys, key)
			end)

			manager:Set("a.b.c", 2)

			-- The parent-level KeyChanged delivery fires at {"a"} with key "b"
			-- (b's subtree changed). The skip must keep {"a"} alive because its
			-- node carries a listener, even though the ValueChanged at {"a"} itself
			-- has no listener.
			expect(table.find(keys, "b")).exists()

			manager:Destroy()
		end)

		test("a listener connected mid-dispatch still hears the current write's ancestor walk", function()
			-- Immediate fire mode so the leaf listener runs synchronously DURING the
			-- DFS, before the ancestor walk — the spine is resolved at fire time, so
			-- the just-connected ancestor listener must still be picked up.
			local manager = TableManager.new({ a = { b = { v = 1 } } }, { ListenerFireMode = "immediate" })

			local ancestorFired = 0
			local connected = false
			manager:OnValueChange("a.b.v", function()
				if not connected then
					connected = true
					manager:OnChange("a", function()
						ancestorFired += 1
					end)
				end
			end)

			manager:Set("a.b.v", 2)

			-- The ancestor OnChange was connected from inside the leaf fire, before
			-- _fireAncestorCallbacks ran; fire-time spine resolution sees it.
			expect(ancestorFired).is(1)

			manager:Destroy()
		end)

		test("leaf-only listener: ancestor walk fully skipped, leaf still fires", function()
			local manager = TableManager.new { a = { b = { v = 1 } } }

			local leafFires = 0
			manager:OnValueChange("a.b.v", function()
				leafFires += 1
			end)

			-- No ancestor listener anywhere; every ancestor level is skipped, but the
			-- exact-path leaf delivery is untouched.
			manager:Set("a.b.v", 2)

			expect(leafFires).is(1)
			expect(manager:Get("a.b.v")).is(2)

			manager:Destroy()
		end)

		test("listeners at several ancestor depths all fire once (fire-by-node path)", function()
			local manager = TableManager.new { a = { b = { c = { d = { v = 1 } } } } }

			-- Non-empty nodes at multiple spine levels: the primed fire-by-node path
			-- must index each of them correctly (not just root).
			local fires: { [string]: number } = { root = 0, a = 0, ab = 0, abc = 0 }
			manager:OnChange({}, function()
				fires.root += 1
			end)
			manager:OnChange("a", function()
				fires.a += 1
			end)
			manager:OnChange("a.b", function()
				fires.ab += 1
			end)
			manager:OnChange("a.b.c", function()
				fires.abc += 1
			end)

			manager:Set("a.b.c.d.v", 2)

			expect(fires.root).is(1)
			expect(fires.a).is(1)
			expect(fires.ab).is(1)
			expect(fires.abc).is(1)

			manager:Destroy()
		end)

		test("re-entrant write from an ancestor listener still converges (priming is per-walk)", function()
			local manager = TableManager.new({ a = { b = { v = 1 }, flag = 0 } }, { ListenerFireMode = "immediate" })

			-- An ancestor listener that writes back on the first notification. The
			-- re-entrant write is queued (drains after this walk), and its own
			-- ancestor walk re-primes independently — the outer walk's primed spine
			-- must not corrupt it.
			local flagWrites = 0
			manager:OnChange("a", function()
				if flagWrites == 0 then
					flagWrites += 1
					manager:Set("a.flag", 1)
				end
			end)

			local flagSeen = 0
			manager:OnValueChange("a.flag", function(newValue)
				if newValue == 1 then
					flagSeen += 1
				end
			end)

			manager:Set("a.b.v", 2)

			expect(manager:Get("a.b.v")).is(2)
			expect(manager:Get("a.flag")).is(1)
			expect(flagSeen).is(1)

			manager:Destroy()
		end)

		test("replacing a nested table still notifies every ancestor spot (general diff path)", function()
			local manager = TableManager.new { a = { b = { c = { v = 1 } } } }

			local rootFires = 0
			local midFires = 0
			manager:OnChange({}, function()
				rootFires += 1
			end)
			manager:OnChange("a", function()
				midFires += 1
			end)

			-- Non-scalar write: exercises the general Diff.diff ancestor walk (not the
			-- scalar fast lane). {"a"} and {} are ancestors of {"a","b"}.
			manager:Set("a.b", { c = { v = 2 } })

			expect(rootFires).is(1)
			expect(midFires).is(1)

			manager:Destroy()
		end)
	end)
end
