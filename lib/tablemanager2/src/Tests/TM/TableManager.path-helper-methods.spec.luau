--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: Get", function()
		test("returns nested values by table path", function()
			local manager = TableManager.new {
				game = { world = { region = { zone = 1 } } },
			}

			local zone = manager:Get { "game", "world", "region", "zone" }
			expect(zone).is(1)

			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local health = manager:Get("player.stats.health")
			expect(health).is(100)

			manager:Destroy()
		end)

		test("errors for non-table intermediate segment", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:Get { "player", "health", "x" }
			end).fails_with("Path segment x is not a table")

			manager:Destroy()
		end)

		test("returns nil when suppressNilPartialPaths is true", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local result = manager:Get({ "player", "health", "x" }, true)
			expect(result).is(nil)

			manager:Destroy()
		end)

		test("allows nil values at the end of the path", function()
			local manager = TableManager.new {
				player = { health = nil },
			}

			local result = manager:Get { "player", "health" }
			expect(result).is(nil)

			manager:Destroy()
		end)
	end)

	describe("Method: GetProxy", function()
		test("returns a proxy for table paths and scalar for value paths", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local playerProxy = manager:GetProxy { "player" }
			local healthValue = manager:GetProxy { "player", "health" }

			expect(playerProxy).exists()
			expect(healthValue).is(100)

			manager:Destroy()
		end)

		test("supports dot-string path input via ParsePath", function()
			local manager = TableManager.new {
				player = { inventory = { slots = 12 } },
			}

			local value = manager:GetProxy("player.inventory.slots")
			expect(value).is(12)

			manager:Destroy()
		end)

		test("errors for non-table intermediate segment", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:GetProxy { "player", "mana", "x" }
			end).fails_with("Path segment mana is not a table")

			manager:Destroy()
		end)

		test("returns nil when suppressNilPartialPaths is true", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local result = manager:GetProxy({ "player", "mana", "x" }, true)
			expect(result).is(nil)

			manager:Destroy()
		end)

		test("allows nil values at the end of the path", function()
			local manager = TableManager.new {
				player = { health = nil },
			}

			local result = manager:GetProxy { "player", "health" }
			expect(result).is(nil)

			manager:Destroy()
		end)
	end)

	describe("Method: Set", function()
		test("sets nested values by path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			manager:Set({ "player", "health" }, 75)
			expect(manager.Proxy.player.health).is(75)

			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}
			manager:Set("player.stats.health", 60)
			expect(manager.Proxy.player.stats.health).is(60)

			manager:Destroy()
		end)

		test("triggers ValueChanged and KeyChanged signals once", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local valueCount = 0
			local keyCount = 0
			local valuePath = nil
			local keyPath = nil
			local keyName = nil

			local vConn = manager.ValueChanged:Connect(function(path)
				valueCount += 1
				valuePath = path
			end)
			local kConn = manager.KeyChanged:Connect(function(path, key)
				keyCount += 1
				keyPath = path
				keyName = key
			end)

			manager:Set({ "player", "health" }, 50)

			expect(valueCount).is(1)
			expect(keyCount).is(1)
			expect(valuePath).is_shallow_equal { "player", "health" }
			expect(keyPath).is_shallow_equal { "player" }
			expect(keyName).is("health")

			vConn:Disconnect()
			kConn:Disconnect()
			manager:Destroy()
		end)

		test("errors when attempting to set root path", function()
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Set({}, 2)
			end).fails_with("Cannot set root path")

			manager:Destroy()
		end)

		test("errors for non-table intermediate segments", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:Set({ "player", "health", "value" }, 10)
			end).fails_with("Path segment health is not a table")

			manager:Destroy()
		end)

		test("nil write through a non-table segment silently succeeds", function()
			-- A nil write is a removal, and a scalar segment means the target
			-- path holds nothing - there is nothing to remove, so this must be
			-- a silent no-op (replication consumers can receive a redundant
			-- child removal after the parent was replaced by a scalar).
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set({ "player", "health", "buff" }, nil)

			expect(fired).is(0)
			expect(manager:Get { "player", "health" }).is(100)

			manager:Destroy()
		end)

		test("nil write through a missing segment silently succeeds", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set({ "player", "gear", "slot" }, nil)

			expect(fired).is(0)
			expect(manager:Get({ "player", "gear" }, true)).is(nil)

			manager:Destroy()
		end)
	end)
end
