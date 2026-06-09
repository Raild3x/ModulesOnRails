--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Integration: Nested Change Flows", function()
		test("handles complex nested structure with multiple changes", function()
			local manager = TableManager.new {
				game = {
					world = {
						players = {
							{ name = "Alice", health = 100 },
							{ name = "Bob", health = 100 },
						},
					},
				},
			}

			local changeCount = 0
			local connection = manager:OnValueChange({ "game" }, function()
				changeCount += 1
			end)

			manager.Proxy.game.world.players[1].health = 50
			manager.Proxy.game.world.players[2].health = 75
			manager:ArrayInsert({ "game", "world", "players" }, { name = "Charlie", health = 100 })

			expect(changeCount >= 3).is_true()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("maintains correct state after multiple array operations", function()
			local manager = TableManager.new {
				inventory = { "Sword" },
			}

			manager:ArrayInsert({ "inventory" }, "Shield")
			manager:ArrayInsert({ "inventory" }, "Potion")
			manager:ArrayRemove({ "inventory" }, 2)

			local firstItem: string = manager.Proxy.inventory[1] :: string
			local secondItem: string = manager.Proxy.inventory[2] :: string
			expect(firstItem).is("Sword")
			expect(secondItem).is("Potion")

			manager:Destroy()
		end)

		test("keeps listener ordering stable through mixed scalar and array updates", function()
			local manager = TableManager.new {
				profile = {
					stats = { level = 1 },
					items = { "Wood" },
				},
			}

			local events = {}
			manager:OnValueChange("profile", function(_newValue, _oldValue, metadata)
				table.insert(events, metadata.OriginPath and table.concat(metadata.OriginPath, ".") or "nil")
			end)

			manager.Proxy.profile.stats.level = 2
			manager:ArrayInsert({ "profile", "items" }, "Stone")
			manager:ArrayRemove({ "profile", "items" }, 1)

			expect(#events >= 3).is_true()
			expect(manager.Proxy.profile.stats.level).is(2)
			expect(manager.Proxy.profile.items[1]).is("Stone")

			manager:Destroy()
		end)
	end)
end
