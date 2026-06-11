--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: OnChange", function()
		test("fires for direct leaf change with Diff metadata", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local hasDiff = false
			local originPath = nil

			local conn = manager:OnChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
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

			manager:OnChange({ "player" }, function(_newValue, _oldValue, metadata)
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
			managerAny:OnChange("player.stats.health", function(newValue, oldValue, metadata)
				fireCount += 1
				expect(newValue).is(75)
				expect(oldValue).is(100)
				expect(metadata.Diff).exists()
			end)

			manager.Proxy.player.stats.health = 75

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("fires when a descendant changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			manager:OnChange({ "player" }, function()
				fireCount += 1
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("Once option auto-disconnects after first invocation", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:OnChange({ "player", "health" }, function()
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

			manager:OnChange({ "player", "health" }, function()
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
			local conn = manager:OnChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			expect(capturedMetadata).exists()
			assert(capturedMetadata, "Expected metadata to be provided for direct change")
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
			local conn = manager:OnChange({ "player" }, function(_newValue, _oldValue, metadata)
				if metadata.Diff == nil then
					ancestorMetadata = metadata
				end
			end)

			manager.Proxy.player.health = 50

			expect(ancestorMetadata).exists()
			assert(ancestorMetadata, "Expected metadata to be provided for ancestor notification")
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
			local conn = manager:OnChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			expect(capturedMetadata).exists()
			assert(capturedMetadata, "Expected metadata to be provided for direct change")
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
			local conn = manager:OnChange({}, function(_newValue, _oldValue, metadata)
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

			local conn1 = manager:OnChange({ "player", "health" }, function()
				count1 += 1
			end)
			local conn2 = manager:OnChange({ "player", "health" }, function()
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
			local conn = manager:OnChange({ "player", "health" }, function()
				fired = true
			end)

			conn:Disconnect()
			manager.Proxy.player.health = 50

			expect(fired).never_is_true()
			manager:Destroy()
		end)
	end)

	describe("Method: OnValueChange", function()
		test("fires only for direct reassignment of the exact path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:OnValueChange({ "player", "health" }, function()
				fireCount += 1
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(1)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("does NOT fire when only a descendant changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(0)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("fires when the whole subtree is directly reassigned", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end)

			manager.Proxy.player = { health = 50 }

			expect(fireCount).is(1)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Method: Observe", function()
		test("immediately fires with the current value and nil metadata", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedValue = nil
			local capturedOld: any = "unset"
			local capturedMetadata: any = "unset"

			local conn = manager:Observe({ "player", "health" }, function(newValue, oldValue, metadata)
				capturedValue = newValue
				capturedOld = oldValue
				capturedMetadata = metadata
			end)

			expect(capturedValue).is(100)
			expect(capturedOld).is(nil)
			expect(capturedMetadata).is(nil)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("fires again with real metadata on subsequent changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local lastValue = nil
			local lastMetadata: any = nil

			local conn = manager:Observe({ "player", "health" }, function(newValue, _oldValue, metadata)
				fireCount += 1
				lastValue = newValue
				lastMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			expect(fireCount).is(2) -- initial + change
			expect(lastValue).is(50)
			expect(lastMetadata).exists()

			conn:Disconnect()
			manager:Destroy()
		end)

		test("immediately fires with nil for a path that does not exist yet", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedValue: any = "unset"
			local conn = manager:Observe({ "player", "mana" }, function(newValue)
				capturedValue = newValue
			end)

			expect(capturedValue).is(nil)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("disconnect prevents later listener invocation", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local conn = manager:Observe({ "player", "health" }, function()
				fireCount += 1
			end)

			conn:Disconnect()
			manager.Proxy.player.health = 50

			expect(fireCount).is(1) -- only the initial fire
			manager:Destroy()
		end)
	end)

	describe("Wildcard listeners", function()
		test("OnValueChange with a wildcard path fires for any matching key", function()
			local manager = TableManager.new {
				Players = {
					p123 = { Health = 100 },
					p456 = { Health = 80 },
				},
			}

			local fired: { [string]: number } = {}
			local conn = manager:OnValueChange({ "Players", "*", "Health" }, function(newValue, _oldValue, metadata)
				local playerId = metadata.WildcardMatches and metadata.WildcardMatches[1]
				fired[playerId] = newValue
			end)

			manager.Proxy.Players.p123.Health = 90
			manager.Proxy.Players.p456.Health = 70

			expect(fired.p123).is(90)
			expect(fired.p456).is(70)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("a new key added under a wildcard-watched parent fires the wildcard ancestor listener", function()
			local manager = TableManager.new {
				Players = {
					p123 = { Health = 100 },
				},
			}

			local matchedIds: { string } = {}
			local conn = manager:OnChange({ "Players", "*" }, function(_newValue, _oldValue, metadata)
				if metadata.WildcardMatches then
					table.insert(matchedIds, metadata.WildcardMatches[1])
				end
			end)

			manager.Proxy.Players.p456 = { Health = 80 }

			expect(#matchedIds).is(1)
			expect(matchedIds[1]).is("p456")

			conn:Disconnect()
			manager:Destroy()
		end)

		test("supports dot-string wildcard path input", function()
			local manager = TableManager.new {
				Players = {
					p123 = { Health = 100 },
				},
			}
			local managerAny: any = manager

			local fireCount = 0
			local conn = managerAny:OnValueChange("Players.*.Health", function()
				fireCount += 1
			end)

			manager.Proxy.Players.p123.Health = 50

			expect(fireCount).is(1)

			conn:Disconnect()
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

			manager:OnKeyChange("player", function(key, newValue, oldValue)
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

			manager:ArrayInsert("game.players", "Charlie")

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
