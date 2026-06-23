--!strict
--[[
	Memory-leak regression tests for TableManager2.

	Layer 1 (deterministic): asserts the library releases its internal STRONG
	references (proxy-graph maps, listener trees, batch state, dispatch queue).
	If no strong references remain, the values are GC-eligible by construction.

	Layer 2 (best-effort): weak-probe collectability checks driven by allocation
	pressure (Luau has no forced GC; see Helpers/GcHelpers.luau).
]]

return function(t: tiniest)
	local TableManager = require("../TableManager")
	local ListenerRegistry = require("../ListenerRegistry")
	local GcHelpers = require("./Helpers/GcHelpers")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("ProxyManager bookkeeping eviction", function()
		test("Set(path, nil) evicts proxy bookkeeping for the removed subtree", function()
			local data = { a = { b = { c = 1 } } }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local aTable = data.a
			local bTable = data.a.b
			local _touch = tm.Proxy.a.b.c -- force proxy creation for `a` and `a.b`

			expect(pm._originalToProxy[aTable]).exists()
			expect(pm._originalToProxy[bTable]).exists()
			expect(pm._proxiesByParent[aTable]).exists()

			tm:Set("a", nil)

			expect(pm._originalToProxy[aTable]).never_exists()
			expect(pm._originalToProxy[bTable]).never_exists()
			expect(pm._proxiesByParent[aTable]).never_exists()
			expect(pm._proxiesByParent[bTable]).never_exists()
			expect(pm._proxiesByParent[data]).never_exists()

			tm:Destroy()
		end)

		test("overwriting a table evicts the old subtree and tracks the new one", function()
			local data = { a = { old = true } }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local oldTable = data.a
			local _touchOld = tm.Proxy.a

			tm.Proxy.a = { new = true }
			local newTable = tm:Get("a")
			local _touchNew = tm.Proxy.a

			expect(pm._originalToProxy[oldTable]).never_exists()
			expect(pm._originalToProxy[newTable]).exists()

			tm:Destroy()
		end)

		test("ArrayRemove and ArraySwapRemove evict removed element tables", function()
			local e1 = { id = 1 }
			local e2 = { id = 2 }
			local e3 = { id = 3 }
			local data = { items = { e1, e2, e3 } }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local itemsArray = data.items
			-- Touch all elements through the proxy so each gets tracked.
			for _index, _element in tm.Proxy.items do
			end
			expect(pm._originalToProxy[e1]).exists()
			expect(pm._proxiesByParent[itemsArray]).exists()

			tm:ArrayRemove("items", 1)
			expect(pm._originalToProxy[e1]).never_exists()
			expect(pm._originalToProxy[e2]).exists() -- shifted left, still live

			tm:ArraySwapRemove("items", 1) -- removes e2, backfills with e3
			expect(pm._originalToProxy[e2]).never_exists()
			expect(pm._originalToProxy[e3]).exists()

			tm:Destroy()
		end)

		test("add/read/remove churn does not grow the strong proxy maps", function()
			local data = { items = {} }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local _touch = tm.Proxy.items
			local baselineOriginals = GcHelpers.CountKeys(pm._originalToProxy)
			local baselineParents = GcHelpers.CountKeys(pm._proxiesByParent)

			for i = 1, 100 do
				tm:ArrayInsert("items", { id = i })
				local _element = tm.Proxy.items[1]
				tm:ArrayRemove("items", 1)
			end

			expect(GcHelpers.CountKeys(pm._originalToProxy))
				.with_context(`baseline={baselineOriginals}`)
				.is(baselineOriginals)
			expect(GcHelpers.CountKeys(pm._proxiesByParent))
				.with_context(`baseline={baselineParents}`)
				.is(baselineParents)

			tm:Destroy()
		end)

		test("MoveTo keeps the moved table tracked (liveness guard)", function()
			local data = { a = { v = 1 } }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local aTable = data.a
			local heldProxy = tm.Proxy.a

			tm:MoveTo("a", "b")

			expect(pm._originalToProxy[aTable]).exists()
			-- The held proxy resolves to the new location; writes land there.
			heldProxy.v = 2
			expect(tm:Get("b").v).is(2)

			tm:Destroy()
		end)

		test("Swap keeps both tables tracked (deferred prune + liveness guard)", function()
			local data = { a = { id = "a" }, b = { id = "b" } }
			local tm = TableManager.new(data) :: any
			local pm = tm._proxyManager

			local aTable = data.a
			local bTable = data.b
			local _touchA = tm.Proxy.a
			local _touchB = tm.Proxy.b

			tm:Swap("a", "b")

			expect(tm:Get("a")).is(bTable)
			expect(tm:Get("b")).is(aTable)
			expect(pm._originalToProxy[aTable]).exists()
			expect(pm._originalToProxy[bTable]).exists()

			tm:Destroy()
		end)

		test("held orphan proxies keep working after their subtree is removed", function()
			local data = { a = { v = 1 } }
			local tm = TableManager.new(data) :: any

			local aTable = data.a
			local orphan = tm.Proxy.a
			tm:Set("a", nil)

			-- The write lands on the detached table without erroring.
			orphan.v = 99
			expect(aTable.v).is(99)
			expect(tm:Get("a", true)).never_exists()

			tm:Destroy()
		end)
	end)

	describe("ListenerRegistry cleanup", function()
		test("Destroy marks every connection disconnected", function()
			local registry = ListenerRegistry.new()
			local noop = function() end
			local connections = {}
			for _i = 1, 4 do
				table.insert(connections, registry:RegisterListener("ValueChanged", { "a" }, noop))
			end
			table.insert(connections, registry:RegisterListener("ValueChanged", { "a", "b" }, noop))
			table.insert(connections, registry:RegisterListener("ValueChanged", { "players", "*", "hp" }, noop))

			registry:Destroy()

			for index, connection in connections do
				expect(connection.Connected).with_context(`connection #{index}`).never_is_true()
			end
		end)

		test("Disconnect and Once-fires prune empty tree nodes", function()
			local registry = ListenerRegistry.new() :: any
			local connA = registry:RegisterListener("ValueChanged", { "a", "b", "c" }, function() end)
			local connB = registry:RegisterListener("ValueChanged", { "x", "*", "y" }, function() end)

			connA:Disconnect()
			connB:Disconnect()
			expect(next(registry._root.Children)).never_exists()

			local fired = 0
			registry:RegisterListener("KeyAdded", { "deep", "path" }, function()
				fired += 1
			end, { Once = true })
			registry:FireListenersExact("KeyAdded", { "deep", "path" }, { Key = "k", NewValue = 1 })
			expect(fired).is(1)
			expect(next(registry._root.Children)).never_exists()

			registry:Destroy()
		end)

		test("registering on a destroyed registry is inert", function()
			local registry = ListenerRegistry.new() :: any
			registry:Destroy()

			local connection = registry:RegisterListener("ValueChanged", { "a" }, function() end)
			expect(connection.Connected).never_is_true()
			expect(function()
				connection:Disconnect()
			end).never_fails()
			expect(next(registry._root.Children)).never_exists()
			expect(registry._root.Count).is(0)
		end)
	end)

	describe("TableManager lifecycle", function()
		test("Destroy mid-batch releases batch state", function()
			local tm = TableManager.new({ a = 1 }) :: any
			tm:Suspend()
			tm:Set("a", 2)
			expect(tm._batch).exists()

			tm:Destroy()
			expect(tm._batch).never_exists()
			expect(tm._batchDepth).is(0)
		end)

		test("re-entrant writes drain the ChangeDetector dispatch queue", function()
			local tm = TableManager.new({ v = 1, w = 1 }) :: any
			tm:OnValueChange("v", function(newValue)
				if newValue < 10 then
					tm:Set("w", newValue * 2)
				end
			end)

			tm:Set("v", 5)
			expect(tm:Get("w")).is(10)
			expect(#tm._changeDetector._dispatchQueue).is(0)

			tm:Destroy()
		end)

		test("registering on a destroyed TableManager returns a dead connection", function()
			local tm = TableManager.new({ a = 1 }) :: any
			tm:Destroy()

			local connection = tm:OnChange("a", function() end)
			expect(connection.Connected).never_is_true()
			expect(next(tm._listenerRegistry._root.Children)).never_exists()
			expect(tm._listenerRegistry._root.Count).is(0)
		end)

		-- Phase 0 golden (Docs/CONTRACT.md §8): severing a shared region must
		-- release the link/observer bookkeeping on the survivor. Under the
		-- refcounted-observer model this is the last-observer-release path; today
		-- it is the group dissolving below two members.
		test("destroying a linked member releases link bookkeeping on the survivor", function()
			local shared = { hp = 100 }
			local a = TableManager.new({ Stats = shared }) :: any
			local b = TableManager.new({ Stats = shared }) :: any
			TableManager.Link({ { a, "Stats" }, { b, "Stats" } })

			expect(a._linkGroups).exists()
			expect(b._linkGroups).exists()

			a:Destroy()

			-- Group drops below two members and dissolves; the survivor keeps no
			-- dangling link/observer bookkeeping for the shared region.
			expect(b._linkGroups == nil or next(b._linkGroups) == nil).is_true()

			b:Destroy()
		end)
	end)

	describe("GC collectability (best-effort, pressure-driven)", function()
		-- Fires one small unrelated event so the shared listener runner thread's
		-- stack slots cannot pin payloads from a previous fire.
		local function recycleRunnerThread()
			local recycler = TableManager.new({ x = 0 })
			recycler:OnValueChange("x", function() end)
			recycler:Set("x", 1)
			recycler:Destroy()
		end

		test("a removed subtree becomes garbage collectable", function()
			local tm = TableManager.new({ a = { b = { payload = 1 } } }) :: any

			local isAlive = (function()
				local _touch = tm.Proxy.a.b -- force proxy creation
				local probe = GcHelpers.WeakProbe(tm:Get("a"))
				tm:Set("a", nil)
				return probe
			end)()

			expect(GcHelpers.WaitForCollection(isAlive)).is_true()
			tm:Destroy()
		end)

		test("a destroyed TableManager becomes garbage collectable", function()
			local isAlive = (function()
				local tm = TableManager.new({ a = { b = 1 } }) :: any
				tm:OnChange("a", function() end)
				local _touch = tm.Proxy.a
				tm:Set("a.b", 2)
				local probe = GcHelpers.WeakProbe(tm)
				tm:Destroy()
				return probe
			end)()

			recycleRunnerThread()
			expect(GcHelpers.WaitForCollection(isAlive)).is_true()
		end)

		test("the listener runner thread does not pin event payloads", function()
			local isAlive = (function()
				local tm = TableManager.new({ v = 0 :: any }) :: any
				tm:OnValueChange("v", function(_newValue) end)

				local payload = table.create(64, "payload")
				tm:Set("v", payload)
				local probe = GcHelpers.WeakProbe(payload)
				tm:Set("v", 0)
				tm:Destroy()
				return probe
			end)()

			recycleRunnerThread()
			expect(GcHelpers.WaitForCollection(isAlive)).is_true()
		end)

		-- Phase 0 golden (Docs/CONTRACT.md §8): a region shared by linked managers
		-- must not be pinned alive by the link/shadow registry once every member is
		-- gone. The re-architecture (identity-keyed, refcounted ShadowNodes) must
		-- keep this property.
		test("a shared linked region is collectable once all members are gone", function()
			local isAlive = (function()
				local shared = { hp = 100 }
				local a = TableManager.new({ Stats = shared }) :: any
				local b = TableManager.new({ Stats = shared }) :: any
				TableManager.Link({ { a, "Stats" }, { b, "Stats" } })
				a:Set("Stats.hp", 50) -- exercise the shared baseline before teardown
				local probe = GcHelpers.WeakProbe(shared)
				a:Destroy()
				b:Destroy()
				return probe
			end)()

			recycleRunnerThread()
			expect(GcHelpers.WaitForCollection(isAlive)).is_true()
		end)
	end)
end
