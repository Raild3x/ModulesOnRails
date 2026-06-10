-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class ProxyGraph.spec
	@ignore

	Phase 1-4 test suite: proxy construction, scalar/table reads+writes,
	child caching, propagation, batch coalescing, and Observer API.
]=]

return function(t: tiniest)
	const ProxyGraph = require("../ProxyGraph")
	const Observer = ProxyGraph.Observer

	const describe = t.describe
	const expect = t.expect
	const test = t.test

	-- ─── Phase 2: ProxyNode core — scalar ────────────────────────────────────────

	describe("ProxyNode scalar", function()
		test("creates and reads a scalar proxy", function()
			const p = ProxyGraph.new(42)
			expect(p:Get()).is(42)
		end)

		test(":Set() updates the value", function()
			const p = ProxyGraph.new(10)
			p:Set(20)
			expect(p:Get()).is(20)
		end)

		test(":Set() no-op when value unchanged does not fire signal", function()
			const p = ProxyGraph.new(5)
			local fired = 0
			Observer(p).OnValueChange:Connect(function()
				fired += 1
			end)
			p:Set(5)
			expect(fired).is(0)
		end)
	end)

	-- ─── Phase 2: ProxyNode core — table ─────────────────────────────────────────

	describe("ProxyNode table", function()
		test("creates a table proxy and reads nested scalars", function()
			local p = ProxyGraph.new { health = 100, power = 10 }
			expect(p.health:Get()).is(100)
			expect(p.power:Get()).is(10)
		end)

		test("child proxy identity is stable (cached)", function()
			local p = ProxyGraph.new { health = 100 }
			local ref1 = p.health
			local ref2 = p.health
			expect(ref1).is(ref2)
		end)

		test(":Get() returns a deep copy independent of future writes", function()
			local p = ProxyGraph.new { x = 1 }
			local snap = p:Get()
			p.x:Set(99)
			expect(snap.x).is(1)
			expect(p.x:Get()).is(99)
		end)

		test("__index returns nil for missing keys", function()
			local p = ProxyGraph.new { a = 1 }
			expect(p.missing).is(nil)
		end)

		test("__newindex creates a new child proxy for new key", function()
			local p = ProxyGraph.new {}
			p.x = 7
			expect(p.x:Get()).is(7)
		end)

		test("__newindex updates existing child via :Set()", function()
			local p = ProxyGraph.new { x = 1 }
			p.x = 2
			expect(p.x:Get()).is(2)
		end)

		test(":Get() includes nested table data", function()
			local p = ProxyGraph.new { stats = { power = 10 } }
			local snap = p:Get()
			expect(type(snap)).is("table")
			expect(snap.stats.power).is(10)
		end)

		test("__iter produces raw key-value pairs", function()
			local p = ProxyGraph.new { a = 1, b = 2 }
			local keys: { string } = {}
			for k in p do
				table.insert(keys, k)
			end
			table.sort(keys)
			expect(#keys).is(2)
			expect(keys[1]).is("a")
			expect(keys[2]).is("b")
		end)

		test(":Remove() detaches a key", function()
			local p = ProxyGraph.new { x = 1, y = 2 }
			p:Remove("x")
			expect(p.x).is(nil)
			expect(p:Get().x).is(nil)
		end)
	end)

	-- ─── Phase 2: multi-parent ────────────────────────────────────────────────────

	describe("ProxyNode multi-parent", function()
		test("shared child notifies both parents via OnChange", function()
			local shared = ProxyGraph.new { power = 20 }
			local p1 = ProxyGraph.new {}
			local p2 = ProxyGraph.new {}
			p1.activeBuff = shared
			p2.activeBuff = shared

			local p1Fired = 0
			local p2Fired = 0
			Observer(p1).OnChange:Connect(function()
				p1Fired += 1
			end)
			Observer(p2).OnChange:Connect(function()
				p2Fired += 1
			end)

			shared.power:Set(30)

			expect(p1Fired).is(1)
			expect(p2Fired).is(1)
		end)
	end)

	-- ─── Phase 3: Propagation engine ─────────────────────────────────────────────

	describe("Propagation parent walk", function()
		test("scalar write propagates OnChange to direct parent", function()
			local p = ProxyGraph.new { health = 100 }
			local fired = 0
			Observer(p).OnChange:Connect(function()
				fired += 1
			end)
			p.health:Set(75)
			expect(fired).is(1)
		end)

		test("diamond graph fires parent OnChange exactly once", function()
			local child = ProxyGraph.new(1)
			local p = ProxyGraph.new {}
			p.a = child
			p.b = child

			local fired = 0
			Observer(p).OnChange:Connect(function()
				fired += 1
			end)

			child:Set(2)
			expect(fired).is(1)
		end)

		test("grandparent OnChange fires when grandchild changes", function()
			local p = ProxyGraph.new { stats = { power = 10 } }
			local fired = 0
			Observer(p).OnChange:Connect(function()
				fired += 1
			end)
			p.stats.power:Set(20)
			expect(fired).is(1)
		end)
	end)

	describe("Propagation batch", function()
		test("Batch defers signal firing until fn returns", function()
			local p = ProxyGraph.new(0)
			local order: { string } = {}

			Observer(p).OnValueChange:Connect(function()
				table.insert(order, "signal")
			end)

			ProxyGraph.Batch(function()
				p:Set(1)
				table.insert(order, "inside")
			end)
			table.insert(order, "after")

			expect(order[1]).is("inside")
			expect(order[2]).is("signal")
			expect(order[3]).is("after")
		end)

		test("Batch coalesces multiple writes to same node into one notification", function()
			local p = ProxyGraph.new(0)
			local fired = 0
			Observer(p).OnValueChange:Connect(function()
				fired += 1
			end)

			ProxyGraph.Batch(function()
				p:Set(1)
				p:Set(2)
				p:Set(3)
			end)

			expect(fired).is(1)
			expect(p:Get()).is(3)
		end)

		test("Batch preserves original old value and latest new value", function()
			local p = ProxyGraph.new(0)
			local capturedNew = nil
			local capturedOld = nil

			Observer(p).OnValueChange:Connect(function(new, old)
				capturedNew = new
				capturedOld = old
			end)

			ProxyGraph.Batch(function()
				p:Set(10)
				p:Set(20)
			end)

			expect(capturedNew).is(20)
			expect(capturedOld).is(0)
		end)

		test("nested Batch only flushes at outermost end", function()
			local p = ProxyGraph.new(0)
			local fired = 0
			Observer(p).OnValueChange:Connect(function()
				fired += 1
			end)

			ProxyGraph.Batch(function()
				p:Set(1)
				ProxyGraph.Batch(function()
					p:Set(2)
				end)
				expect(fired).is(0)
			end)

			expect(fired).is(1)
		end)
	end)

	-- ─── Phase 4: Observer API ────────────────────────────────────────────────────

	describe("Observer", function()
		test("OnValueChange fires with correct (new, old) on scalar write", function()
			local p = ProxyGraph.new(5)
			local capturedNew = nil
			local capturedOld = nil
			Observer(p).OnValueChange:Connect(function(new, old)
				capturedNew = new
				capturedOld = old
			end)
			p:Set(10)
			expect(capturedNew).is(10)
			expect(capturedOld).is(5)
		end)

		test("OnChange fires on descendant write", function()
			local p = ProxyGraph.new { x = 1 }
			local fired = 0
			Observer(p).OnChange:Connect(function()
				fired += 1
			end)
			p.x:Set(2)
			expect(fired).is(1)
		end)

		test("OnChange does NOT fire for an unrelated proxy write", function()
			local p1 = ProxyGraph.new(1)
			local p2 = ProxyGraph.new(2)
			local fired = 0
			Observer(p1).OnChange:Connect(function()
				fired += 1
			end)
			p2:Set(99)
			expect(fired).is(0)
		end)

		test("Once auto-disconnects after first fire", function()
			local p = ProxyGraph.new(0)
			local fired = 0
			Observer(p).OnValueChange:Once(function()
				fired += 1
			end)
			p:Set(1)
			p:Set(2)
			expect(fired).is(1)
		end)

		test("Disconnect stops future fires", function()
			local p = ProxyGraph.new(0)
			local fired = 0
			local conn = Observer(p).OnValueChange:Connect(function()
				fired += 1
			end)
			conn:Disconnect()
			p:Set(1)
			expect(fired).is(0)
		end)

		test("OnKeyAdded fires when a new key is assigned", function()
			local p = ProxyGraph.new {}
			local addedKey = nil
			Observer(p).OnKeyAdded:Connect(function(key)
				addedKey = key
			end)
			p.newField = 42
			expect(addedKey).is("newField")
		end)

		test("OnKeyRemoved fires when a key is removed", function()
			local p = ProxyGraph.new { x = 1 }
			local removedKey = nil
			Observer(p).OnKeyRemoved:Connect(function(key)
				removedKey = key
			end)
			p:Remove("x")
			expect(removedKey).is("x")
		end)

		test("isProxy identifies proxies correctly", function()
			local p = ProxyGraph.new(1)
			expect(ProxyGraph.isProxy(p)).is(true)
			expect(ProxyGraph.isProxy(1)).is(false)
			expect(ProxyGraph.isProxy {}).is(false)
			expect(ProxyGraph.isProxy(nil)).is(false)
		end)

		test("peek returns raw value for proxy, passthrough for non-proxy", function()
			local p = ProxyGraph.new(42)
			expect(ProxyGraph.peek(p)).is(42)
			expect(ProxyGraph.peek(99)).is(99)
		end)
	end)

	-- ─── Structural reconciliation via :Set() ─────────────────────────────────────

	describe("Structural Set()", function()
		test(":Set() on table proxy updates child and fires OnValueChange", function()
			local p = ProxyGraph.new { health = 100 }
			local fired = 0
			Observer(p.health).OnValueChange:Connect(function()
				fired += 1
			end)
			p:Set { health = 75 }
			expect(fired).is(1)
			expect(p.health:Get()).is(75)
		end)

		test(":Set() fires OnKeyAdded for new keys", function()
			local p = ProxyGraph.new {}
			local added = nil
			Observer(p).OnKeyAdded:Connect(function(key)
				added = key
			end)
			p:Set { newKey = 1 }
			expect(added).is("newKey")
		end)

		test(":Set() fires OnKeyRemoved for removed keys", function()
			local p = ProxyGraph.new { x = 1 }
			local removed = nil
			Observer(p).OnKeyRemoved:Connect(function(key)
				removed = key
			end)
			p:Set {}
			expect(removed).is("x")
		end)

		test(":Set() with structurally identical table is no-op", function()
			local p = ProxyGraph.new { x = 1 }
			local fired = 0
			Observer(p.x).OnValueChange:Connect(function()
				fired += 1
			end)
			p:Set { x = 1 }
			expect(fired).is(0)
		end)
	end)
end
