--!strict
--[[
	Tests for the observation gate (Phase 1 of the coverage-tree plan):
	- ListenerRegistry:CoversChangesAt, the O(depth) conservative coverage check
	  built on the unified tree's Count/Subtree counters.
	- Mutator's shouldTrackChangesAt gate, which skips the snapshot/diff cost for
	  writes nobody could observe (no covering listener, no connected global
	  Signal, no active link group).
]]

return function(t: tiniest)
	local TableManager = require("../TableManager")
	local ListenerRegistry = require("../Listening/ListenerRegistry")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("ListenerRegistry:CoversChangesAt", function()
		test("returns false when nothing is registered", function()
			local registry = ListenerRegistry.new()

			expect(registry:CoversChangesAt({ "a" })).never_is_true()

			registry:Destroy()
		end)

		test("root-only listener covers a deep change", function()
			local registry = ListenerRegistry.new()
			registry:RegisterListener("ValueChanged", {}, function() end)

			expect(registry:CoversChangesAt({ "a", "b", "c" })).is_true()

			registry:Destroy()
		end)

		test("sibling-only listener does not cover an unrelated path", function()
			local registry = ListenerRegistry.new()
			registry:RegisterListener("ValueChanged", { "a", "x" }, function() end)

			expect(registry:CoversChangesAt({ "a", "y" })).never_is_true()

			registry:Destroy()
		end)

		test("descendant-only listener forces an ancestor write to be tracked", function()
			local registry = ListenerRegistry.new()
			registry:RegisterListener("ValueChanged", { "a", "b", "c" }, function() end)

			-- A write at "a" could replace/restructure the subtree containing
			-- the descendant listener's path, so the ancestor must be covered.
			expect(registry:CoversChangesAt({ "a" })).is_true()
			-- The exact descendant path is, of course, also covered.
			expect(registry:CoversChangesAt({ "a", "b", "c" })).is_true()
			-- A disjoint sibling of the ancestor is still uncovered.
			expect(registry:CoversChangesAt({ "z" })).never_is_true()

			registry:Destroy()
		end)

		test("disconnecting the only covering listener drops coverage", function()
			local registry = ListenerRegistry.new()
			local connection = registry:RegisterListener("ValueChanged", { "x", "y" }, function() end)

			expect(registry:CoversChangesAt({ "x", "y" })).is_true()

			connection:Disconnect()

			expect(registry:CoversChangesAt({ "x", "y" })).never_is_true()

			registry:Destroy()
		end)

		test("a wildcard listener forces full coverage everywhere", function()
			local registry = ListenerRegistry.new()
			registry:RegisterListener("ValueChanged", { "players", "*", "hp" }, function() end)

			expect(registry:CoversChangesAt({ "totally", "unrelated", "path" })).is_true()

			registry:Destroy()
		end)
	end)

	describe("Observation gate integration (TableManager)", function()
		test("an unobserved write still updates live state", function()
			local manager = TableManager.new {
				a = { b = 1 },
				z = 1,
			}

			manager:Set("z", 2)
			expect(manager:Get("z")).is(2)

			-- Late registration after the unobserved write still works correctly
			-- going forward; skipping the diff never corrupts later writes.
			local newValue
			manager:OnValueChange("z", function(value)
				newValue = value
			end)
			manager:Set("z", 3)
			expect(newValue).is(3)
			expect(manager:Get("z")).is(3)

			manager:Destroy()
		end)

		test("root listener still observes a deep, otherwise-unobserved write", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local fireCount = 0
			manager:OnChange({}, function()
				fireCount += 1
			end)

			manager:Set("player.stats.health", 50)

			expect(fireCount).is(1)
			expect(manager:Get("player.stats.health")).is(50)

			manager:Destroy()
		end)

		test("sibling-only listener does not fire for an unrelated write", function()
			local manager = TableManager.new {
				a = { x = 1 },
				b = { y = 1 },
			}

			local fireCount = 0
			manager:OnValueChange("a.x", function()
				fireCount += 1
			end)

			manager:Set("b.y", 2)

			expect(fireCount).is(0)
			expect(manager:Get("b.y")).is(2)

			manager:Destroy()
		end)

		test("a connected global Signal forces tracking even with no registry listener", function()
			local manager = TableManager.new {
				a = { x = 1 },
			}

			local fired = false
			manager.ValueChanged:Connect(function()
				fired = true
			end)

			manager:Set("a.x", 2)

			expect(fired).is_true()
			expect(manager:Get("a.x")).is(2)

			manager:Destroy()
		end)

		test("co-observing a shared identity fans out a write with no direct listener on the source", function()
			local shared = { health = 100 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			-- Implicit sharing: `a` and `b` both root at `shared`, so they co-observe
			-- it automatically (no explicit link).

			-- `a` has no direct OnChange/OnValueChange listener and no connected
			-- global Signal: without the shared-observer bypass, `a`'s write would be
			-- gated out, its OnValueChanged dispatch (which FanOutSet rides
			-- inside of) would never run, and `b`'s listener would never fire.
			local bNew, bOld
			b:OnValueChange("health", function(newValue, oldValue)
				bNew, bOld = newValue, oldValue
			end)

			a:Set("health", 50)

			expect(bNew).is(50)
			expect(bOld).is(100)

			a:Destroy()
			b:Destroy()
		end)

		test("array append with no listeners still updates live state", function()
			local manager = TableManager.new {
				items = { "a" },
			}

			manager:ArrayInsert("items", "b")

			expect(manager:Get("items")).is_shallow_equal { "a", "b" }

			manager:Destroy()
		end)

		test("array append fires a listener registered before the write", function()
			local manager = TableManager.new {
				items = { "a" },
			}

			local insertedValue
			manager:OnArrayInsert("items", function(_index, newValue)
				insertedValue = newValue
			end)

			manager:ArrayInsert("items", "b")

			expect(insertedValue).is("b")

			manager:Destroy()
		end)

		test("listener registered mid-batch still observes an append made earlier in the batch", function()
			local manager = TableManager.new {
				items = { "a" },
			}

			local insertedValue
			manager:Suspend()
			manager:ArrayInsert("items", "b")
			-- No listener existed yet when the append happened; the batch's
			-- unconditional dirty-marking (not the observation gate) is what
			-- must keep this change live until flush.
			manager:OnArrayInsert("items", function(_index, newValue)
				insertedValue = newValue
			end)
			manager:Resume()

			expect(insertedValue).is("b")
			expect(manager:Get("items")).is_shallow_equal { "a", "b" }

			manager:Destroy()
		end)
	end)

	describe("Transparent diff depth bound (deferred re-resolution)", function()
		-- These drive `Coverage.ResolveDiffMaxDepth`, which is only consulted on the
		-- DEFERRED flush path (`_doFlush` with no precomputed bound). `FlushMode =
		-- "coalesced"` routes every write through that path, and NO global Signal is
		-- connected (a signal would force full depth before the interesting branches).

		test("a wildcard listener forces a full-depth diff on the deferred flush", function()
			-- ResolveDiffMaxDepth's `registry._hasWildcards` branch (Coverage.luau:124).
			local manager = TableManager.new({
				Players = { p1 = { Health = 100 } },
			}, { FlushMode = "coalesced" })

			local fired = 0
			manager:OnValueChange({ "Players", "*", "Health" }, function()
				fired += 1
			end)

			manager:Set({ "Players", "p1", "Health" }, 90)
			task.wait()

			expect(fired).is(1) -- the deep change was diffed despite the depth bound
			expect(manager:Get({ "Players", "p1", "Health" })).is(90)

			manager:Destroy()
		end)

		test("a covering ProvideDiff listener forces a full-depth diff on the deferred flush", function()
			-- ResolveDiffMaxDepth's `registry:WantsFullDiff(path)` branch (Coverage.luau:127).
			local manager = TableManager.new({
				a = { b = { c = 1 } },
			}, { FlushMode = "coalesced" })

			local fired = 0
			manager:OnChange({ "a", "b" }, function()
				fired += 1
			end, { ProvideDiff = true })

			-- Replace the whole `a` subtree so the flush root is `a` (an ancestor of
			-- the ProvideDiff listener), exercising WantsFullDiff at `a`.
			manager:Set("a", { b = { c = 2 } })
			task.wait()

			expect(fired).is(1)
			expect(manager:Get({ "a", "b", "c" })).is(2)

			manager:Destroy()
		end)

		test("an unbounded descendant listener resolves to full depth (MaxObservedDepth == huge)", function()
			-- ResolveDiffMaxDepth's `depth == math.huge` branch (Coverage.luau:131):
			-- an OnChange descendant with no ListenDepth cap reaches unbounded depth.
			local manager = TableManager.new({
				a = { b = { c = 1 } },
			}, { FlushMode = "coalesced" })

			local fired = 0
			manager:OnChange({ "a", "b", "c" }, function()
				fired += 1
			end)

			manager:Set("a", { b = { c = 2 } }) -- flush root `a`, listener unbounded below it
			task.wait()

			expect(fired).is(1)
			expect(manager:Get({ "a", "b", "c" })).is(2)

			manager:Destroy()
		end)

		test("a depth-bounded listener stops the diff below its reach (nested cutoff)", function()
			-- Diff.diff_tables' nested depth cutoff (Diff.luau:312): a ListenDepth=0
			-- listener at `a.b` bounds MaxObservedDepth("a") to a finite value, so the
			-- diff of a deeper change under it stops at the bound instead of recursing.
			local manager = TableManager.new({
				a = { b = { c = { d = 1 } } },
			}, { FlushMode = "coalesced" })

			local abFired = 0
			manager:OnChange({ "a", "b" }, function()
				abFired += 1
			end, { ListenDepth = 0 })

			manager:Set("a", { b = { c = { d = 2 } } })
			task.wait()

			-- The bounded listener still learns its subtree changed (fired once),
			-- but the diff didn't need to walk all the way to `d`.
			expect(abFired).is(1)
			expect(manager:Get({ "a", "b", "c", "d" })).is(2)

			manager:Destroy()
		end)
	end)
end
