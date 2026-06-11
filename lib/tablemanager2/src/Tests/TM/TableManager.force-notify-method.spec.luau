--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: ForceNotify", function()
		test("fires listeners for same-table assignments", function()
			local manager = TableManager.new {
				players = { John = { Stats = { Health = 100, Level = 5 } } },
			}

			local statsListenerCount = 0
			local johnListenerCount = 0

			local statsConn = manager:OnValueChange(
				{ "players", "John", "Stats" },
				function(_newValue, _oldValue, metadata)
					statsListenerCount += 1
					if metadata.Diff then
						expect(metadata.Diff.old).is(metadata.Diff.new)
					end
				end
			)

			local johnConn = manager:OnChange({ "players", "John" }, function()
				johnListenerCount += 1
			end)

			local sameStats = manager.Proxy.players.John.Stats
			manager.Proxy.players.John.Stats = sameStats

			expect(statsListenerCount).is(0)
			expect(johnListenerCount).is(0)

			manager:ForceNotify { "players", "John", "Stats" }

			expect(statsListenerCount).is(1)
			expect(johnListenerCount).is(1)

			statsConn:Disconnect()
			johnConn:Disconnect()
			manager:Destroy()
		end)

		test("provides changed metadata where old equals new", function()
			local manager = TableManager.new {
				settings = { volume = 80 },
			}

			local hasDiff = false
			local oldEqualsNew = false

			local conn = manager:OnValueChange({ "settings", "volume" }, function(_newValue, _oldValue, metadata)
				if metadata.Diff then
					hasDiff = true
					oldEqualsNew = (metadata.Diff.old == metadata.Diff.new)
				end
			end)

			manager:ForceNotify { "settings", "volume" }

			expect(hasDiff).is_true()
			expect(oldEqualsNew).is_true()

			conn:Disconnect()
			manager:Destroy()
		end)

		test("fires ancestor listeners for forced notifications", function()
			local manager = TableManager.new {
				game = {
					world = {
						players = { John = { health = 100 } },
					},
				},
			}

			local gameCount = 0
			local worldCount = 0
			local playersCount = 0
			local johnCount = 0
			local healthCount = 0

			manager:OnChange({ "game" }, function()
				gameCount += 1
			end)
			manager:OnChange({ "game", "world" }, function()
				worldCount += 1
			end)
			manager:OnChange({ "game", "world", "players" }, function()
				playersCount += 1
			end)
			manager:OnChange({ "game", "world", "players", "John" }, function()
				johnCount += 1
			end)
			manager:OnChange({ "game", "world", "players", "John", "health" }, function()
				healthCount += 1
			end)

			manager:ForceNotify { "game", "world", "players", "John", "health" }

			expect(gameCount).is(1)
			expect(worldCount).is(1)
			expect(playersCount).is(1)
			expect(johnCount).is(1)
			expect(healthCount).is(1)

			manager:Destroy()
		end)

		test("respects ListenDepth=0 for forced descendant notifications", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local unlimited = 0
			local directOnly = 0

			manager:OnChange({ "player" }, function()
				unlimited += 1
			end)
			manager:OnChange({ "player" }, function()
				directOnly += 1
			end, { ListenDepth = 0 })

			manager:ForceNotify { "player", "health" }

			expect(unlimited).is(1)
			expect(directOnly).is(0)

			manager:Destroy()
		end)
	end)
end
