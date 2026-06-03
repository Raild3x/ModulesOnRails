--!nonstrict
local Stats = game:GetService("Stats")
--[=[
	@class TableManager_new.spec
	
	Comprehensive test suite for the clean TableManager_new implementation.
	
	Tests cover:
	- Basic proxy functionality
	- Unified change detection
	- Signals fire once behavior
	- Listeners fire appropriately (ancestors handled by ChangeDetector)
	- FireOnDescendantChanges filtering
	- Array operations with ancestor notifications
	- Metadata structure validation
]=]

return function(t)
	local TableManager = require(script.Parent.Parent)

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- test("notepad", function()
	-- 	local manager = TableManager.new {
	-- 		players = { John = { Inventory = { Sword = 1 }, Stats = { Health = 100, Level = 5 } } },
	-- 	}

	-- 	local defaultCount = 0
	-- 	local noDescendantCount = 0

	-- 	-- Default behavior: FireOnDescendantChanges = true
	-- 	-- Should fire for direct change AND descendant changes
	-- 	manager:OnValueChange({ "players", "John" }, function(_newValue, _oldValue: any?, metadata)
	-- 		defaultCount += 1

	-- 		-- Use diff metadata to inspect the change
	-- 		if metadata.Diff then
	-- 			-- Direct change to this path
	-- 			print(`ValueChanged for players.John (DIRECT): Fire #{defaultCount}`)
	-- 			print(`  Old value type: {typeof(metadata.Diff.Old)}`)
	-- 			print(`  New value type: {typeof(metadata.Diff.New)}`)
	-- 			print(`  Same reference? {metadata.Diff.Old == metadata.Diff.New}`)
	-- 		else
	-- 			-- Ancestor notification from a descendant change
	-- 			print(`ValueChanged for players.John (ANCESTOR): Fire #{defaultCount}`)
	-- 			print(`  Origin path: {table.concat(metadata.OriginPath, ".")}`)
	-- 			if metadata.OriginDiff then
	-- 				print(`  Origin changed: {metadata.OriginDiff.Old} -> {metadata.OriginDiff.New}`)
	-- 			end
	-- 		end
	-- 	end)

	-- 	-- FireOnDescendantChanges = false
	-- 	-- Should ONLY fire for direct changes to players.John, NOT for descendant changes
	-- 	manager:OnValueChange({ "players", "John" }, function(_newValue, _oldValue: any?, metadata)
	-- 		noDescendantCount += 1
	-- 		print(
	-- 			`ValueChanged for players.John (FireOnDescendantChanges=false): Fire #{noDescendantCount}, hasDiff={metadata.Diff ~= nil}`
	-- 		)
	-- 	end, { FireOnDescendantChanges = false })

	-- 	local statsCount = 0
	-- 	manager:OnValueChange("players.John.Stats", function(_newValue, _oldValue: any?, metadata)
	-- 		statsCount += 1

	-- 		-- Demonstrate using diff to detect same-table assignments
	-- 		if metadata.Diff and metadata.Diff.Old == metadata.Diff.New then
	-- 			print(`ValueChanged for players.John.Stats: Fire #{statsCount} (SAME TABLE REASSIGNED)`)
	-- 		elseif metadata.Diff then
	-- 			print(`ValueChanged for players.John.Stats: Fire #{statsCount} (NEW TABLE)`)
	-- 		else
	-- 			print(`ValueChanged for players.John.Stats: Fire #{statsCount} (DESCENDANT CHANGED)`)
	-- 		end
	-- 	end)

	-- 	local statsNoDescendantCount = 0
	-- 	manager:OnValueChange("players.John.Stats", function(_newValue, _oldValue: any?, metadata)
	-- 		statsNoDescendantCount += 1
	-- 		print(
	-- 			`ValueChanged for players.John.Stats (FireOnDescendantChanges=false): Fire #{statsNoDescendantCount}, hasDiff={metadata.Diff ~= nil}`
	-- 		)
	-- 	end, { FireOnDescendantChanges = false })

	-- 	-- This is a DIRECT change to players.John (replacing the entire table)
	-- 	-- Both listeners should fire ONCE
	-- 	print("\n--- Setting players.John to new table ---")
	-- 	manager.Proxy.players.John = {
	-- 		Inventory = { Sword = 3 },
	-- 		Stats = { Health = 90, Level = 5, Mana = 50 },
	-- 	}
	-- 	print(`After replace: defaultCount={defaultCount}, noDescendantCount={noDescendantCount}`)
	-- 	print(`Stats listener count: statsCount={statsCount}, statsNoDescendantCount={statsNoDescendantCount}`)

	-- 	-- This is a DESCENDANT change (changing a nested value)
	-- 	-- Only the default listener (DescendantChanges=true) should fire
	-- 	print("\n--- Setting players.John.Stats.Health to 80 ---")
	-- 	manager.Proxy.players.John.Stats.Health = 80
	-- 	print(`After descendant change: defaultCount={defaultCount}, noDescendantCount={noDescendantCount}`)
	-- 	print(`Stats listener count: statsCount={statsCount}, statsNoDescendantCount={statsNoDescendantCount}`)

	-- 	-- Demonstrate same-table assignment detection
	-- 	print("\n--- Re-assigning same Stats table ---")
	-- 	local sameStats = manager.Proxy.players.John.Stats
	-- 	manager.Proxy.players.John.Stats = sameStats
	-- 	print(`After same-table assign: statsCount={statsCount}, statsNoDescendantCount={statsNoDescendantCount}`)

	-- 	-- Assertions
	-- 	expect(defaultCount).is(3) -- Fires for: 1) direct replace, 2) descendant health change, 3) same-table assign
	-- 	expect(noDescendantCount).is(2) -- Fires ONLY for: 1) direct replace, 2) same-table assign (both are direct to John)
	-- 	expect(statsCount).is(3) -- Fires for: 1) ancestor notify from replace, 2) direct from health, 3) same-table assign
	-- 	expect(statsNoDescendantCount).is(2) -- Fires for: 1) direct replace, 2) same-table assign
	-- end)
	-- if true then
	-- 	return
	-- end

	describe("Basic Functionality", function()
		test("should create a manager with initial data", function()
			local manager = TableManager.new {
				player = { health = 100, level = 5 },
				settings = { volume = 80 },
			}

			expect(manager).exists()
			expect(manager.Proxy).exists()
			expect(manager.Proxy.player).exists()
			expect(manager.Proxy.player.health).is(100)

			manager:Destroy()
		end)

		test("should read nested values via proxy", function()
			local manager = TableManager.new {
				game = {
					world = {
						region = { zone = 1 },
					},
				},
			}

			expect(manager.Proxy.game.world.region.zone).is(1)

			manager:Destroy()
		end)

		test("should write nested values via proxy", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			manager.Proxy.player.health = 50
			expect(manager.Proxy.player.health).is(50)

			manager:Destroy()
		end)

		test("should handle Get helper method", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local health = manager:Get { "player", "health" }
			expect(health).is(100)

			manager:Destroy()
		end)

		test("should handle Set helper method", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			manager:Set({ "player", "health" }, 75)
			expect(manager.Proxy.player.health).is(75)

			manager:Destroy()
		end)
	end)

	describe("Signals Fire Once", function()
		test("should fire ValueChanged signal once per change", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local signalCount = 0
			local connection = manager.ValueChanged:Connect(function()
				signalCount += 1
			end)

			-- Make a change
			manager.Proxy.player.health = 50

			-- Signal should fire exactly once
			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should fire KeyChanged signal once per change", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local signalCount = 0
			local connection = manager.KeyChanged:Connect(function()
				signalCount += 1
			end)

			manager.Proxy.player.health = 50

			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should fire KeyAdded signal once when key is added", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local signalCount = 0
			local addedKey = nil
			local addedValue = nil
			local updatedPath = nil
			local allFires = {}

			local connection = manager.KeyAdded:Connect(function(path, key, value)
				signalCount += 1
				addedKey = key
				addedValue = value
				updatedPath = path

				-- Debug: Track all fires
				table.insert(allFires, {
					fireNum = signalCount,
					path = table.clone(path),
					key = key,
					value = value,
					pathStr = table.concat(path, "."),
				})
			end)

			manager.Proxy.player.mana = 50

			-- Debug output if test fails
			if signalCount ~= 1 or not updatedPath or #updatedPath ~= 1 or updatedPath[1] ~= "player" then
				print("\n=== KeyAdded Signal Debug ===")
				print("Signal fired", signalCount, "times (expected 1)")
				print("All fires:")
				for _, fire in allFires do
					print(
						string.format(
							"  Fire #%d: path=%s, key=%s, value=%s",
							fire.fireNum,
							fire.pathStr,
							tostring(fire.key),
							tostring(fire.value)
						)
					)
				end
				print("Final captured values:")
				print("  path:", updatedPath and table.concat(updatedPath, ".") or "nil")
				print("  key:", tostring(addedKey))
				print("  value:", tostring(addedValue))
				print("===========================\n")
			end

			expect(signalCount).is(1)
			expect(updatedPath).is_shallow_equal { "player" }
			expect(addedKey).is("mana")
			expect(addedValue).is(50)

			connection:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Listeners Fire Multiple Times", function()
		test("should fire listener for direct change (metadata.Diff exists)", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerFireCount = 0
			local hasDiff = false
			local allFires = {}

			local connection = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				listenerFireCount += 1
				hasDiff = metadata.Diff ~= nil
				table.insert(allFires, {
					fireNum = listenerFireCount,
					newValue = _newValue,
					oldValue = _oldValue,
					hasDiff = metadata.Diff ~= nil,
					originPath = metadata.OriginPath,
				})
			end)

			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if listenerFireCount ~= 1 then
				print("\n=== Direct Change Listener Debug ===")
				print("Listener fired", listenerFireCount, "times (expected 1)")
				print("All fires:")
				for _, fire in allFires do
					print(
						string.format(
							"  Fire #%d: newValue=%s, oldValue=%s, hasDiff=%s, originPath=%s",
							fire.fireNum,
							tostring(fire.newValue),
							tostring(fire.oldValue),
							tostring(fire.hasDiff),
							fire.originPath and table.concat(fire.originPath, ".") or "nil"
						)
					)
				end
				print("===========================\n")
			end

			-- This listener should fire exactly once
			expect(listenerFireCount).is(1)
			expect(hasDiff).is_true()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should fire listener for ancestor notification (metadata.Diff is nil)", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local ancestorFireCount = 0
			local ancestorFired = false

			-- Listen at parent level
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				ancestorFireCount += 1
				if metadata.Diff == nil then
					ancestorFired = true
				end
			end)

			-- Change nested value
			manager.Proxy.player.health = 50

			-- This listener should fire exactly once (as ancestor notification)
			expect(ancestorFireCount).is(1)
			expect(ancestorFired).is_true()

			manager:Destroy()
		end)

		test("should fire different listeners along the same path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local directFireCount = 0
			local ancestorFireCount = 0
			local directFires = {}
			local ancestorFires = {}

			-- Listen at parent level (ancestor notification)
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				ancestorFireCount += 1
				table.insert(ancestorFires, {
					fireNum = ancestorFireCount,
					hasDiff = metadata.Diff ~= nil,
					originPath = metadata.OriginPath and table.concat(metadata.OriginPath, ".") or "nil",
				})
			end)

			-- Listen at the exact changed path (direct change)
			manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				directFireCount += 1
				table.insert(directFires, {
					fireNum = directFireCount,
					hasDiff = metadata.Diff ~= nil,
					originPath = metadata.OriginPath and table.concat(metadata.OriginPath, ".") or "nil",
				})
			end)

			-- Make a change - should fire both listeners once each:
			-- 1. {"player", "health"} listener fires once (direct, with Diff)
			-- 2. {"player"} listener fires once (ancestor, without Diff)
			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if directFireCount ~= 1 or ancestorFireCount ~= 1 then
				print("\n=== Different Listeners Debug ===")
				print("Direct listener fired", directFireCount, "times (expected 1)")
				print("Ancestor listener fired", ancestorFireCount, "times (expected 1)")
				print("\nDirect fires:")
				for _, fire in directFires do
					print(
						string.format(
							"  Fire #%d: hasDiff=%s, originPath=%s",
							fire.fireNum,
							tostring(fire.hasDiff),
							fire.originPath
						)
					)
				end
				print("\nAncestor fires:")
				for _, fire in ancestorFires do
					print(
						string.format(
							"  Fire #%d: hasDiff=%s, originPath=%s",
							fire.fireNum,
							tostring(fire.hasDiff),
							fire.originPath
						)
					)
				end
				print("===========================\n")
			end

			expect(directFireCount).is(1)
			expect(ancestorFireCount).is(1)
			manager:Destroy()
		end)
	end)

	describe("FireOnDescendantChanges Filtering", function()
		test("should fire for descendants when FireOnDescendantChanges is true (default)", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0

			-- Default: FireOnDescendantChanges = true
			-- Listening at ["player"], change at ["player", "health"]
			-- Should fire when the descendant changes (ancestor notification)
			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end, { FireOnDescendantChanges = true })

			manager.Proxy.player.health = 50

			-- Should fire exactly once (for the descendant change notification)
			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("should NOT fire for descendants when FireOnDescendantChanges is false", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0
			local allFires = {}

			-- Explicit: FireOnDescendantChanges = false
			-- Listening at ["player"], change at ["player", "health"]
			-- Should NOT fire for descendant changes
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				fireCount += 1
				table.insert(allFires, {
					fireNum = fireCount,
					hasDiff = metadata.Diff ~= nil,
					originPath = metadata.OriginPath and table.concat(metadata.OriginPath, ".") or "nil",
				})
			end, { FireOnDescendantChanges = false })

			-- Change nested value (should NOT fire listener)
			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if fireCount ~= 0 then
				print("\n=== FireOnDescendantChanges=false Debug ===")
				print("Listener fired", fireCount, "times (expected 0)")
				print("All fires:")
				for _, fire in allFires do
					print(
						string.format(
							"  Fire #%d: hasDiff=%s, originPath=%s",
							fire.fireNum,
							tostring(fire.hasDiff),
							fire.originPath
						)
					)
				end
				print("===========================\n")
			end

			expect(fireCount).is(0)

			manager:Destroy()
		end)

		test("should fire for direct change even when FireOnDescendantChanges is false", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0

			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end, { FireOnDescendantChanges = false })

			-- Replace the player table itself (direct change)
			manager.Proxy.player = { health = 200 }

			-- Should fire exactly once (for the direct change)
			expect(fireCount).is(1)
			manager:Destroy()
		end)
	end)

	describe("Array Operations", function()
		test("should handle Insert at end of array", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			manager:Insert({ "items" }, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is("Potion")

			manager:Destroy()
		end)

		test("should handle Insert at specific position", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			manager:Insert({ "items" }, 2, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Potion")
			expect(manager.Proxy.items[3]).is("Shield")

			manager:Destroy()
		end)

		test("should handle Remove from array", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local removed = manager:Remove({ "items" }, 2)

			expect(removed).is("Shield")
			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Potion")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("should fire ArrayInserted signal once", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			local signalCount = 0
			local connection = manager.ArrayInserted:Connect(function()
				signalCount += 1
			end)

			manager:Insert({ "items" }, "Potion")

			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should fire ArrayRemoved signal once", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			local signalCount = 0
			local connection = manager.ArrayRemoved:Connect(function()
				signalCount += 1
			end)

			manager:Remove({ "items" }, 1)

			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Array Ancestor Notifications", function()
		test("should notify ancestors when array element is inserted", function()
			local manager = TableManager.new {
				game = {
					players = { "Alice", "Bob" },
				},
			}

			local gameNotified = 0
			local originPath = nil

			-- Listen at game level (ancestor of the inserted element)
			manager:OnValueChange({ "game" }, function(_newValue, _oldValue, metadata)
				gameNotified += 1
				originPath = metadata.OriginPath
			end)

			local gameKeyChangeNotified = 0
			manager:OnKeyChange({ "game" }, function(key, newValue, oldValue)
				gameKeyChangeNotified += 1
				expect(key).is("players")
				print(
					string.format("[OnKeyChange] %s changed from %s to %s", key, tostring(oldValue), tostring(newValue))
				)
			end)

			manager:Insert({ "game", "players" }, "Charlie")

			-- Should fire once for ancestor notification
			expect(gameNotified).is(1)
			expect(originPath).exists()
			expect(#originPath).is(3) -- {"game", "players", 3}
			expect(gameKeyChangeNotified).is(1) -- Notify game that "players" key was changed (array modified)

			manager:Destroy()
		end)

		test("should notify ancestors when array element is removed", function()
			local manager = TableManager.new {
				game = {
					players = { "Alice", "Bob", "Charlie" },
				},
			}

			local notifiedCount = 0

			-- Listen at game level (ancestor of the removed element)
			manager:OnValueChange({ "game" }, function(_newValue, _oldValue, _metadata)
				notifiedCount += 1
			end)

			manager:Remove({ "game", "players" }, 2)

			-- Should fire exactly once (ancestor notification for the removal)
			expect(notifiedCount).is(1)
			manager:Destroy()
		end)
	end)

	describe("Metadata Structure", function()
		test("should provide correct metadata for direct changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedMetadata = nil

			local connection = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if not capturedMetadata or not capturedMetadata.Diff then
				print("\n=== Metadata Structure Debug ===")
				print("capturedMetadata:", capturedMetadata)
				if capturedMetadata then
					print("  Diff:", capturedMetadata.Diff)
					print(
						"  OriginPath:",
						capturedMetadata.OriginPath and table.concat(capturedMetadata.OriginPath, ".") or "nil"
					)
					print("  OriginDiff:", capturedMetadata.OriginDiff)
				end
				print("===========================\n")
			end

			expect(capturedMetadata).exists()
			expect(capturedMetadata.Diff).exists()
			expect(capturedMetadata.OriginPath).exists()
			expect(capturedMetadata.OriginDiff).exists()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should provide correct metadata for ancestor notifications", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local ancestorMetadata = nil

			local connection = manager:OnValueChange({ "player" }, function(_newValue, _oldValue, metadata)
				if metadata.Diff == nil then
					ancestorMetadata = metadata
				end
			end)

			manager.Proxy.player.health = 50

			expect(ancestorMetadata).exists()
			expect(ancestorMetadata.Diff).is(nil)
			expect(ancestorMetadata.OriginPath).exists()
			expect(ancestorMetadata.OriginDiff).exists()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should have matching OriginPath and OriginDiff for leaf changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedMetadata = nil

			local connection = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				capturedMetadata = metadata
			end)

			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if not capturedMetadata or capturedMetadata.Diff ~= capturedMetadata.OriginDiff then
				print("\n=== OriginPath/OriginDiff Debug ===")
				print("capturedMetadata:", capturedMetadata)
				if capturedMetadata then
					print("  Diff:", capturedMetadata.Diff)
					print("  OriginDiff:", capturedMetadata.OriginDiff)
					print("  Diff == OriginDiff:", capturedMetadata.Diff == capturedMetadata.OriginDiff)
				end
				print("===========================\n")
			end

			expect(capturedMetadata.Diff).is(capturedMetadata.OriginDiff)

			connection:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Edge Cases", function()
		test("should handle nil value assignments", function()
			local manager = TableManager.new {
				player = { health = 100, mana = 50 },
			}

			manager.Proxy.player.mana = nil

			expect(manager.Proxy.player.mana).is(nil)
			expect(manager.Proxy.player.health).is(100)

			manager:Destroy()
		end)

		test("should handle root path changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerFired = false
			local capturedData = {}

			local connection = manager:OnValueChange({}, function(_newValue, _oldValue, metadata)
				listenerFired = true
				table.insert(capturedData, {
					newValue = _newValue,
					oldValue = _oldValue,
					hasDiff = metadata.Diff ~= nil,
					originPath = metadata.OriginPath and table.concat(metadata.OriginPath, ".") or "nil",
				})
			end)

			manager.Proxy.settings = { volume = 80 }

			-- Debug output if test fails
			if not listenerFired then
				print("\n=== Root Path Changes Debug ===")
				print("Listener fired:", listenerFired)
				print("Number of fires:", #capturedData)
				print("All fires:")
				for i, fire in capturedData do
					print(
						string.format(
							"  Fire #%d: newValue=%s, oldValue=%s, hasDiff=%s, originPath=%s",
							i,
							tostring(fire.newValue),
							tostring(fire.oldValue),
							tostring(fire.hasDiff),
							fire.originPath
						)
					)
				end
				print("===========================\n")
			end

			expect(listenerFired).is_true()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should handle multiple listeners on same path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local count1 = 0
			local count2 = 0
			local fires1 = {}
			local fires2 = {}

			-- Two different listeners on the exact same path
			local conn1 = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				count1 += 1
				table.insert(fires1, {
					fireNum = count1,
					hasDiff = metadata.Diff ~= nil,
				})
			end)

			local conn2 = manager:OnValueChange({ "player", "health" }, function(_newValue, _oldValue, metadata)
				count2 += 1
				table.insert(fires2, {
					fireNum = count2,
					hasDiff = metadata.Diff ~= nil,
				})
			end)

			manager.Proxy.player.health = 50

			-- Debug output if test fails
			if count1 ~= 1 or count2 ~= 1 then
				print("\n=== Multiple Listeners Debug ===")
				print("Listener 1 fired", count1, "times (expected 1)")
				print("Listener 2 fired", count2, "times (expected 1)")
				print("\nListener 1 fires:")
				for _, fire in fires1 do
					print(string.format("  Fire #%d: hasDiff=%s", fire.fireNum, tostring(fire.hasDiff)))
				end
				print("\nListener 2 fires:")
				for _, fire in fires2 do
					print(string.format("  Fire #%d: hasDiff=%s", fire.fireNum, tostring(fire.hasDiff)))
				end
				print("===========================\n")
			end

			-- Both listeners should fire exactly once
			expect(count1).is(1)
			expect(count2).is(1)

			conn1:Disconnect()
			conn2:Disconnect()
			manager:Destroy()
		end)

		test("should handle disconnecting listeners", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerFired = false

			local connection = manager:OnValueChange({ "player", "health" }, function()
				listenerFired = true
			end)

			connection:Disconnect()

			manager.Proxy.player.health = 50

			expect(listenerFired).never_is_true()

			manager:Destroy()
		end)
	end)

	describe("Integration Tests", function()
		test("should handle complex nested structure with multiple changes", function()
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

			-- Multiple changes
			manager.Proxy.game.world.players[1].health = 50
			manager.Proxy.game.world.players[2].health = 75
			manager:Insert({ "game", "world", "players" }, { name = "Charlie", health = 100 })

			-- Should fire for each change + ancestors (at least 3 times)
			local wasTriggeredMultipleTimes = changeCount >= 3
			expect(wasTriggeredMultipleTimes).is_true()

			connection:Disconnect()
			manager:Destroy()
		end)

		test("should maintain correct state after multiple operations", function()
			local manager = TableManager.new {
				inventory = { "Sword" },
			}

			manager:Insert({ "inventory" }, "Shield")
			manager:Insert({ "inventory" }, "Potion")
			manager:Remove({ "inventory" }, 2)

			-- Check state
			local firstItem: string = manager.Proxy.inventory[1] :: string
			local secondItem: string = manager.Proxy.inventory[2] :: string
			expect(firstItem).is("Sword")
			expect(secondItem).is("Potion")

			manager:Destroy()
		end)
	end)

	describe("ForceNotify", function()
		test("should fire listeners even for same-table assignments", function()
			local manager = TableManager.new {
				players = { John = { Stats = { Health = 100, Level = 5 } } },
			}

			local statsListenerCount = 0
			local johnListenerCount = 0

			-- Listen to Stats path
			local statsConn = manager:OnValueChange(
				{ "players", "John", "Stats" },
				function(_newValue, _oldValue, metadata)
					statsListenerCount += 1

					-- Check if this is a same-table assignment
					if metadata.Diff and metadata.Diff.old == metadata.Diff.new then
						print(`Stats listener: Same table assigned (old == new)`)
					end
				end
			)

			-- Listen to John path (ancestor)
			local johnConn = manager:OnValueChange({ "players", "John" }, function(_newValue, _oldValue, _metadata)
				johnListenerCount += 1
			end)

			-- Test 1: Same-table assignment WITHOUT ForceNotify
			-- This should NOT fire any listeners
			local sameStats = manager.Proxy.players.John.Stats
			manager.Proxy.players.John.Stats = sameStats

			expect(statsListenerCount).is(0)
			expect(johnListenerCount).is(0)

			-- Test 2: Same-table assignment WITH ForceNotify
			-- This SHOULD fire listeners
			manager:ForceNotify { "players", "John", "Stats" }

			expect(statsListenerCount).is(1)
			expect(johnListenerCount).is(1)

			statsConn:Disconnect()
			johnConn:Disconnect()
			manager:Destroy()
		end)

		test("should provide correct metadata for forced notifications", function()
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

			-- Force notification
			manager:ForceNotify { "settings", "volume" }

			-- Should have Diff present and old == new
			expect(hasDiff).is_true()
			expect(oldEqualsNew).is_true()

			conn:Disconnect()
			manager:Destroy()
		end)

		test("should fire ancestor listeners for forced notifications", function()
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

			manager:OnValueChange({ "game" }, function()
				gameCount += 1
			end)
			manager:OnValueChange({ "game", "world" }, function()
				worldCount += 1
			end)
			manager:OnValueChange({ "game", "world", "players" }, function()
				playersCount += 1
			end)
			manager:OnValueChange({ "game", "world", "players", "John" }, function()
				johnCount += 1
			end)
			manager:OnValueChange({ "game", "world", "players", "John", "health" }, function()
				healthCount += 1
			end)

			-- Force notification at health path
			manager:ForceNotify { "game", "world", "players", "John", "health" }

			-- All ancestors should be notified
			expect(gameCount).is(1)
			expect(worldCount).is(1)
			expect(playersCount).is(1)
			expect(johnCount).is(1)
			expect(healthCount).is(1)

			manager:Destroy()
		end)

		test("should respect FireOnDescendantChanges=false for forced notifications", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local withDescendants = 0
			local withoutDescendants = 0

			-- Default: FireOnDescendantChanges = true
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, _metadata)
				withDescendants += 1
			end)

			-- FireOnDescendantChanges = false
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, _metadata)
				withoutDescendants += 1
			end, { FireOnDescendantChanges = false })

			-- Force notification at descendant path
			manager:ForceNotify { "player", "health" }

			-- Only listener with FireOnDescendantChanges=true should fire for ancestor
			expect(withDescendants).is(1)
			expect(withoutDescendants).is(0)

			manager:Destroy()
		end)
	end)
end
