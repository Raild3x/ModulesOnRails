--!strict
--[[
	Unit tests for the ProxyManager proxy metamethods (__len, __tostring, __iter)
	and the graph-maintenance methods (GetPath, CreateProxy identity/scalar
	handling, ReparentProxy, RetargetRoot, ShiftKeys, PruneOriginal) that the
	main ProxyManager suite and TableManager integration tests do not exercise
	directly.
]]

return function(t: tiniest)
	local ProxyManager = require("../ProxyManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("__len metamethod", function()
		test("returns the length of the underlying array", function()
			local data = { 10, 20, 30 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(#proxy).is(3)

			manager:Destroy()
		end)

		test("reflects a nested array proxy's length", function()
			local data = { items = { "a", "b" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(#proxy.items).is(2)

			manager:Destroy()
		end)
	end)

	describe("__tostring metamethod", function()
		test("the root proxy renders without a path", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(tostring(proxy)).is("TableManager.Data")

			manager:Destroy()
		end)

		test("a nested proxy renders its dot-joined live path", function()
			local data = { player = { stats = { level = 5 } } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(tostring(proxy.player.stats)).is("TableManager.Data(player.stats)")

			manager:Destroy()
		end)

		test("a destroyed proxy renders the unknown-path form", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			manager:Destroy()

			expect(tostring(proxy)).is("TableManager.Data(?)")
		end)
	end)

	describe("__iter metamethod", function()
		test("wraps nested table values in proxies and passes scalars through", function()
			local data = { child = { x = 1 }, scalar = 7 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local childProxy: any = nil
			local scalarValue: any = nil
			for key, value in proxy do
				if key == "child" then
					childProxy = value
				elseif key == "scalar" then
					scalarValue = value
				end
			end

			expect(manager:GetMetadata(childProxy)).exists() -- child came back as a proxy
			expect(scalarValue).is(7)

			manager:Destroy()
		end)

		test("reuses an already-created nested proxy during iteration", function()
			local data = { child = { x = 1 } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local preCreated = proxy.child -- forces the nested proxy to exist first

			local seen: any = nil
			for key, value in proxy do
				if key == "child" then
					seen = value
				end
			end

			expect(seen).is(preCreated)

			manager:Destroy()
		end)
	end)

	describe("GetPath", function()
		test("returns the live path of a nested proxy", function()
			local data = { player = { health = 100 } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local path = manager:GetPath(proxy.player)
			expect(path).exists()
			expect(#(path :: any)).is(1)
			expect((path :: any)[1]).is("player")

			manager:Destroy()
		end)

		test("returns nil for a destroyed proxy", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			manager:Destroy()

			expect(manager:GetPath(proxy)).is(nil)
		end)
	end)

	describe("CreateProxy", function()
		test("returns scalars unchanged", function()
			local manager = ProxyManager.new({})
			expect(manager:CreateProxy(42 :: any)).is(42)
			manager:Destroy()
		end)

		test("returns the same proxy for the same table", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local first = manager:CreateProxy(data)
			local second = manager:CreateProxy(data)
			expect(first).is(second)
			manager:Destroy()
		end)
	end)

	describe("ReparentProxy", function()
		test("errors when the proxy metadata is gone (destroyed)", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)
			manager:Destroy()

			expect(function()
				manager:ReparentProxy(proxy, nil, nil)
			end).fails()
		end)

		test("moves a proxy's tracked key/parent", function()
			local data = { list = { { id = 1 } }, other = {} }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)
			local child = proxy.list[1]

			manager:ReparentProxy(child, data.other, "moved")
			local meta = manager:GetMetadata(child)
			expect(meta.Key).is("moved")
			expect(meta.Parent).is(data.other)

			manager:Destroy()
		end)
	end)

	describe("RetargetRoot", function()
		test("rejects a non-table newRoot", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			manager:CreateProxy(data)

			expect(function()
				manager:RetargetRoot(data, 5 :: any)
			end).fails()

			manager:Destroy()
		end)

		test("rejects an oldRoot that is not the current root original", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			manager:CreateProxy(data)

			expect(function()
				manager:RetargetRoot({ not_the_root = true }, { a = 2 })
			end).fails()

			manager:Destroy()
		end)

		test("retargets the root proxy onto a new table, preserving identity", function()
			local data = { a = 1 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local newRoot = { a = 2, b = 3 }
			manager:RetargetRoot(data, newRoot)

			expect(proxy.a).is(2)
			expect(proxy.b).is(3)
			expect(manager:GetProxyFromOriginal(newRoot)).is(proxy)

			manager:Destroy()
		end)
	end)

	describe("ShiftKeys", function()
		test("shifts child keys at or past fromIndex by delta", function()
			local data = { { id = 1 }, { id = 2 }, { id = 3 } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local c1 = proxy[1]
			local c2 = proxy[2]
			local c3 = proxy[3]

			manager:ShiftKeys(data, 2, 1) -- as after inserting before index 2

			expect(manager:GetMetadata(c1).Key).is(1) -- below fromIndex, untouched
			expect(manager:GetMetadata(c2).Key).is(3)
			expect(manager:GetMetadata(c3).Key).is(4)

			manager:Destroy()
		end)

		test("is a no-op for a parent with no tracked children", function()
			local manager = ProxyManager.new({})
			manager:ShiftKeys({ untracked = true }, 1, 1) -- must not error
			expect(true).is_true()
			manager:Destroy()
		end)
	end)

	describe("PruneOriginal", function()
		test("ignores a non-table value", function()
			local manager = ProxyManager.new({})
			manager:PruneOriginal(42) -- must not error
			expect(true).is_true()
			manager:Destroy()
		end)
	end)
end
