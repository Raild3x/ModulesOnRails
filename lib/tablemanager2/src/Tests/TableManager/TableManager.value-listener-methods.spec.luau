--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: OnValueChange", function()
		test("fires for direct leaf change with Diff metadata", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local hasDiff = false
			local originPath = nil

			local conn = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				fireCount += 1
				hasDiff = metadata.Diff ~= nil
				originPath = metadata.OriginPath
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(1)
			expect(hasDiff).is_true()
			expect(originPath).is_shallow_equal { "player", "health" }

			conn:Disconnect()
			manager:Destroy()
		end)

		test("fires for ancestor notification with Diff=nil", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local diffWasNil = false

			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				fireCount += 1
				diffWasNil = (metadata.Diff == nil)
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(1)
			expect(diffWasNil).is_true()

			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}
			local managerAny: any = manager

			local fireCount = 0
			managerAny:OnValueChange("player.stats.health", function(newValue, oldValue, metadata)
				fireCount += 1
				expect(newValue).is(75)
				expect(oldValue).is(100)
				expect(metadata.Diff).exists()
			end)

			manager.Proxy.player.stats.health = 75

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("respects ListenDepth=0 for descendant changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end, { ListenDepth = 0 })

			manager.Proxy.player.health = 50

			expect(fireCount).is(0)
			manager:Destroy()
		end)

		test("Once option auto-disconnects after first invocation", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:OnValueChange({ "player", "health" }, function()
				fireCount += 1
			end, { Once = true })

			manager.Proxy.player.health = 50
			manager.Proxy.player.health = 25

			expect(fireCount).is(1)
			expect(conn.Connected).never_is_true()

			manager:Destroy()
		end)

		test("pairs with ValueChanged signal exactly once per leaf change", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil

			manager:OnValueChange({ "player", "health" }, function()
				listenerCount += 1
			end)

			local conn = manager.ValueChanged:Connect(function(path, newValue, oldValue)
				signalCount += 1
				signalPath = path
				expect(newValue).is(50)
				expect(oldValue).is(100)
			end)

			manager.Proxy.player.health = 50

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "player", "health" }

			conn:Disconnect()
			manager:Destroy()
		end)

		test("provides full metadata for direct changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedMetadata = nil
			local conn = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			expect(capturedMetadata).exists()
			expect(capturedMetadata.Diff).exists()
			expect(capturedMetadata.OriginPath).is_shallow_equal { "player", "health" }
			expect(capturedMetadata.OriginDiff).exists()

			conn:Disconnect()
			manager:Destroy()
		end)

		test("uses Diff=nil plus OriginDiff for ancestor notifications", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local ancestorMetadata = nil
			local conn = manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				if metadata.Diff == nil then
					ancestorMetadata = metadata
				end
			end)

			manager.Proxy.player.health = 50

			expect(ancestorMetadata).exists()
			expect(ancestorMetadata.Diff).is(nil)
			expect(ancestorMetadata.OriginPath).is_shallow_equal { "player", "health" }
			expect(ancestorMetadata.OriginDiff).exists()

			conn:Disconnect()
			manager:Destroy()
		end)

		test("leaf listener has Diff equal to OriginDiff", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedMetadata = nil
			local conn = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			expect(capturedMetadata).exists()
			expect(capturedMetadata.Diff).is(capturedMetadata.OriginDiff)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("supports root path listeners", function()
			local manager = TableManager.new {
				player = { health = 100 },
				settings = nil :: any,
			}

			local fireCount = 0
			local conn = manager:OnValueChange({}, function(_newValue, _oldValue, metadata)
				fireCount += 1
				expect(metadata.OriginPath).is_shallow_equal { "settings" }
			end)

			manager.Proxy.settings = { volume = 80 }

			expect(fireCount).is(1)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("supports multiple listeners on the same path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local count1 = 0
			local count2 = 0

			local conn1 = manager:OnValueChange({ "player", "health" }, function()
				count1 += 1
			end)
			local conn2 = manager:OnValueChange({ "player", "health" }, function()
				count2 += 1
			end)

			manager.Proxy.player.health = 50

			expect(count1).is(1)
			expect(count2).is(1)

			conn1:Disconnect()
			conn2:Disconnect()
			manager:Destroy()
		end)

		test("disconnect prevents later listener invocation", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fired = false
			local conn = manager:OnValueChange({ "player", "health" }, function()
				fired = true
			end)

			conn:Disconnect()
			manager.Proxy.player.health = 50

			expect(fired).never_is_true()
			manager:Destroy()
		end)
	end)

	describe("Method: OnKeyChange", function()
		test("fires when a scalar key changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local seenKey = nil
			local seenNew = nil
			local seenOld = nil

			manager:OnKeyChange({ "player" }, function(key, newValue, oldValue)
				fireCount += 1
				seenKey = key
				seenNew = newValue
				seenOld = oldValue
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(1)
			expect(seenKey).is("health")
			expect(seenNew).is(50)
			expect(seenOld).is(100)

			manager:Destroy()
		end)

		test("fires for array mutations at ancestor key", function()
			local manager = TableManager.new {
				game = {
					players = { "Alice", "Bob" },
				},
			}

			local fireCount = 0

			manager:OnKeyChange({ "game" }, function(key, _newValue, _oldValue)
				fireCount += 1
				expect(key).is("players")
			end)

			manager:ArrayInsert({ "game", "players" }, "Charlie")

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				game = { state = { level = 1 } },
			}
			local managerAny: any = manager

			local fireCount = 0
			managerAny:OnKeyChange("game.state", function(key, newValue, oldValue)
				fireCount += 1
				expect(key).is("level")
				expect(newValue).is(2)
				expect(oldValue).is(1)
			end)

			manager.Proxy.game.state.level = 2

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("respects ListenDepth=0 for descendant changes", function()
			local manager = TableManager.new {
				game = { state = { level = 1 } },
			}

			local fireCount = 0
			manager:OnKeyChange({ "game" }, function()
				fireCount += 1
			end, { ListenDepth = 0 })

			manager.Proxy.game.state.level = 2

			expect(fireCount).is(0)
			manager:Destroy()
		end)

		test("pairs with KeyChanged signal payload", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerCount = 0
			local signalCount = 0

			manager:OnKeyChange({ "player" }, function()
				listenerCount += 1
			end)

			local conn = manager.KeyChanged:Connect(function(path, key, newValue, oldValue)
				signalCount += 1
				expect(path).is_shallow_equal { "player" }
				expect(key).is("health")
				expect(newValue).is(80)
				expect(oldValue).is(100)
			end)

			manager.Proxy.player.health = 80

			expect(listenerCount).is(1)
			expect(signalCount).is(1)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)
end
