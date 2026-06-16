--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("TableManager.Extend", function()
		test("Extend via proxy: bidirectional fan-out and shared identity", function()
			local data = { Stats = { Health = 100 } }
			local playerTM = TableManager.new(data)

			local statsTM = playerTM:Extend(playerTM:GetProxy("Stats"))

			expect(statsTM.Raw).is(data.Stats)
			expect(playerTM.Linker:IsLinkedWith(statsTM)).is_true()

			local seen
			playerTM:OnValueChange("Stats.Health", function(newValue)
				seen = newValue
			end)
			statsTM:Set("Health", 50)
			expect(data.Stats.Health).is(50)
			expect(seen).is(50)

			local seenOnStats
			statsTM:OnValueChange("Health", function(newValue)
				seenOnStats = newValue
			end)
			playerTM:Set("Stats.Health", 75)
			expect(seenOnStats).is(75)

			playerTM:Destroy()
			statsTM:Destroy()
		end)

		test("Extend via path string", function()
			local data = { Stats = { Health = 100 } }
			local playerTM = TableManager.new(data)

			local statsTM = playerTM:Extend("Stats")
			expect(statsTM.Raw).is(data.Stats)

			local seen
			statsTM:OnValueChange("Health", function(newValue)
				seen = newValue
			end)
			playerTM:Set("Stats.Health", 10)
			expect(seen).is(10)

			playerTM:Destroy()
			statsTM:Destroy()
		end)

		test("Extend via raw value already in the tree", function()
			local data = { Inventory = { { Name = "Sword" } } }
			local playerTM = TableManager.new(data)

			local swordTM = playerTM:Extend(data.Inventory[1])
			expect(swordTM.Raw).is(data.Inventory[1])

			local seen
			playerTM:OnValueChange({ "Inventory", 1, "Name" }, function(newValue)
				seen = newValue
			end)
			swordTM:Set("Name", "Axe")
			expect(seen).is("Axe")

			playerTM:Destroy()
			swordTM:Destroy()
		end)

		test("Extend follows array shifts: the parent anchor is recomputed at fan-out time", function()
			local data = { Inventory = { { Name = "Sword" }, { Name = "Shield" } } }
			local playerTM = TableManager.new(data)

			local swordTM = playerTM:Extend(data.Inventory[1])

			-- Insert ahead of the extended element; its index shifts from 1 to 2.
			playerTM:ArrayInsert("Inventory", 1, { Name = "Dagger" })

			local seen
			playerTM:OnValueChange({ "Inventory", 2, "Name" }, function(newValue)
				seen = newValue
			end)
			swordTM:Set("Name", "Excalibur")

			expect(data.Inventory[2].Name).is("Excalibur")
			expect(seen).is("Excalibur")

			playerTM:Destroy()
			swordTM:Destroy()
		end)

		test("Detachment: replacing the extended object dissolves the group", function()
			local data = { Stats = { Health = 100 } }
			local playerTM = TableManager.new(data)

			local statsTM = playerTM:Extend("Stats")

			playerTM:Set("Stats", { Health = 999 })

			expect(playerTM.Linker:IsLinkedWith(statsTM)).never_is_true()

			-- statsTM keeps operating on the orphaned object, independent of
			-- playerTM's new "Stats" table.
			local seen
			statsTM:OnValueChange("Health", function(newValue)
				seen = newValue
			end)
			statsTM:Set("Health", 1)
			expect(seen).is(1)
			expect(statsTM.Raw.Health).is(1)
			expect(data.Stats.Health).is(999)

			playerTM:Destroy()
			statsTM:Destroy()
		end)

		test("Extend requires a table target", function()
			local playerTM = TableManager.new { Stats = { Health = 100 }, Name = "Bob" }

			expect(function()
				playerTM:Extend("Name")
			end).fails()

			playerTM:Destroy()
		end)

		test("Extend does not require proxies", function()
			local playerTM = TableManager.new({ Stats = { Health = 100 } }, { EnableProxies = false })

			expect(function()
				playerTM:Extend("Stats")
			end).never_fails()

			playerTM:Destroy()
		end)
	end)
end
