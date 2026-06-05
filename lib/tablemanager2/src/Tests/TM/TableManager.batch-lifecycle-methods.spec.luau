--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: Batch", function()
		test("suppresses intermediate signals and fires at flush", function()
			local manager = TableManager.new {
				player = { health = 100, mana = 50 },
			}

			local valueChangedCount = 0
			local keyChangedCount = 0
			manager.ValueChanged:Connect(function()
				valueChangedCount += 1
			end)
			manager.KeyChanged:Connect(function()
				keyChangedCount += 1
			end)

			manager:Batch(function()
				manager.Proxy.player.health = 80
				manager.Proxy.player.health = 60
				manager.Proxy.player.mana = 30
			end)

			expect(valueChangedCount).is(2)
			expect(keyChangedCount).is(2)

			manager:Destroy()
		end)

		test("with no net change fires nothing", function()
			local manager = TableManager.new {
				x = 1,
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Batch(function()
				manager.Proxy.x = 99
				manager.Proxy.x = 1
			end)

			expect(fired).is(0)

			manager:Destroy()
		end)

		test("nested Batch call is a no-op for inner window", function()
			local manager = TableManager.new {
				a = 1,
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Batch(function()
				manager:Batch(function()
					manager.Proxy.a = 2
				end)
			end)

			expect(fired).is(1)
			expect(manager.Proxy.a).is(2)

			manager:Destroy()
		end)

		test("array insert events are deferred until flush", function()
			local manager = TableManager.new {
				items = { "a", "b" },
			}

			local firedDuringBatchFn = false
			local batchFnRunning = false
			manager.ArrayInserted:Connect(function()
				if batchFnRunning then
					firedDuringBatchFn = true
				end
			end)

			local insertedEvents: { { index: number, value: any } } = {}
			manager.ArrayInserted:Connect(function(_path, index, value)
				table.insert(insertedEvents, { index = index, value = value })
			end)

			manager:Batch(function()
				batchFnRunning = true
				manager:ArrayInsert({ "items" }, "c")
				manager:ArrayInsert({ "items" }, "d")
				batchFnRunning = false
			end)

			expect(firedDuringBatchFn).is(false)
			expect(#insertedEvents).is(2)
			expect(manager.Proxy.items[3]).is("c")
			expect(manager.Proxy.items[4]).is("d")

			manager:Destroy()
		end)
	end)

	describe("Method: Suspend", function()
		test("suppresses immediate events until resume", function()
			local manager = TableManager.new {
				v = 1,
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Suspend()
			manager.Proxy.v = 2
			manager.Proxy.v = 3
			expect(fired).is(0)

			manager:Resume()
			expect(fired).is(1)
			expect(manager.Proxy.v).is(3)

			manager:Destroy()
		end)

		test("nested Suspend is a no-op", function()
			local manager = TableManager.new {
				x = 1,
			}

			local fired = 0
			manager.ValueChanged:Connect(function(path)
				if path[1] == "x" then
					fired += 1
				end
			end)

			manager:Suspend()
			manager:Suspend()
			manager.Proxy.x = 2
			expect(fired).is(0)

			manager:Resume()
			expect(manager.Proxy.x).is(2)
			expect(fired).is(1)

			manager:Destroy()
		end)

		test("defers array inserted signals while suspended", function()
			local manager = TableManager.new {
				items = { "a" },
			}

			local inserted = 0
			manager.ArrayInserted:Connect(function()
				inserted += 1
			end)

			manager:Suspend()
			manager:ArrayInsert({ "items" }, "b")
			expect(inserted).is(0)

			manager:Resume()
			expect(inserted).is(1)

			manager:Destroy()
		end)
	end)

	describe("Method: Resume", function()
		test("without Suspend is a no-op", function()
			local manager = TableManager.new { x = 1 }

			manager:Resume()
			manager:Resume()
			expect(manager.Proxy.x).is(1)
			manager:Destroy()
		end)

		test("second Resume after flush remains a no-op", function()
			local manager = TableManager.new { x = 1 }

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Suspend()
			manager.Proxy.x = 2
			manager:Resume()
			manager:Resume()

			expect(fired).is(1)
			expect(manager.Proxy.x).is(2)
			manager:Destroy()
		end)

		test("flushes deferred changes after suspend", function()
			local manager = TableManager.new { score = 0 }

			local fired = 0
			manager.ValueChanged:Connect(function(path)
				if path[1] == "score" then
					fired += 1
				end
			end)

			manager:Suspend()
			manager.Proxy.score = 10
			expect(fired).is(0)
			manager:Resume()

			expect(fired).is(1)
			expect(manager.Proxy.score).is(10)
			manager:Destroy()
		end)
	end)
end
