--!strict
--[=[
	@class TableManager_new.spec
	
	Comprehensive test suite for the clean TableManager_new implementation.
	
	Tests cover:
	- Basic proxy functionality
	- Unified change detection
	- Signals fire once behavior
	- Listeners fire appropriately (ancestors handled by ChangeDetector)
	- ListenDepth / Once filtering
	- Array operations with ancestor notifications
	- Metadata structure validation
]=]

return function(t: tiniest)
	local TableManager = require("../TableManager")
	local T = require("../../T")

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

	describe("ListenDepth Filtering", function()
		test("should fire for descendants by default (nil depth)", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0

			-- Default: depth=nil (unlimited)
			-- Listening at ["player"], change at ["player", "health"]
			-- Should fire when the descendant changes (ancestor notification)
			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end)

			manager.Proxy.player.health = 50

			-- Should fire exactly once (for the descendant change notification)
			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("should NOT fire for descendants when ListenDepth = 0", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0

			-- ListenDepth = 0: only fires for direct changes, not ancestor notifications
			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end, { ListenDepth = 0 })

			-- Change nested value (should NOT fire listener)
			manager.Proxy.player.health = 50

			expect(fireCount).is(0)

			manager:Destroy()
		end)

		test("should fire for direct change even when ListenDepth = 0", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fireCount = 0

			manager:OnValueChange({ "player" }, function()
				fireCount += 1
			end, { ListenDepth = 0 })

			-- Replace the player table itself (direct change)
			manager.Proxy.player = { health = 200 }

			-- Should fire exactly once (for the direct change)
			expect(fireCount).is(1)
			manager:Destroy()
		end)
	end)

	describe("Once Option", function()
		test("Once listener fires exactly once then auto-disconnects", function()
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
	end)

	describe("Array Operations", function()
		test("should handle Insert at end of array", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			manager:ArrayInsert({ "items" }, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is("Potion")

			manager:Destroy()
		end)

		test("should handle Insert at specific position", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			manager:ArrayInsert({ "items" }, 2, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Potion")
			expect(manager.Proxy.items[3]).is("Shield")

			manager:Destroy()
		end)

		test("should handle Remove from array", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local removed = manager:ArrayRemove({ "items" }, 2)

			expect(removed).is("Shield")
			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Potion")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("ArrayInsert supports both path and proxy array targets", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			manager:ArrayInsert({ "items" }, "Shield")
			manager:ArrayInsert(manager.Proxy.items, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is("Potion")

			manager:Destroy()
		end)

		test("ArrayRemove supports both path and proxy array targets", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local removedByPath = manager:ArrayRemove({ "items" }, 1)
			local removedByProxy = manager:ArrayRemove(manager.Proxy.items, 1)

			expect(removedByPath).is("Sword")
			expect(removedByProxy).is("Shield")
			expect(manager.Proxy.items[1]).is("Potion")
			expect(manager.Proxy.items[2]).is(nil)

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

			manager:ArrayInsert({ "items" }, "Potion")

			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)

		test("ArrayInserted payload is correct when target is proxy", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			local eventCount = 0
			local capturedPath = nil
			local capturedIndex = nil
			local capturedValue = nil

			local connection = manager.ArrayInserted:Connect(function(path, index, value)
				eventCount += 1
				capturedPath = path
				capturedIndex = index
				capturedValue = value
			end)

			manager:ArrayInsert(manager.Proxy.items, "Potion")

			expect(eventCount).is(1)
			expect(capturedPath).is_shallow_equal { "items" }
			expect(capturedIndex).is(2)
			expect(capturedValue).is("Potion")

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

			manager:ArrayRemove({ "items" }, 1)

			expect(signalCount).is(1)

			connection:Disconnect()
			manager:Destroy()
		end)

		test("ArrayRemoved payload is correct when target is proxy", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local eventCount = 0
			local capturedPath = nil
			local capturedIndex = nil
			local capturedValue = nil

			local connection = manager.ArrayRemoved:Connect(function(path, index, value)
				eventCount += 1
				capturedPath = path
				capturedIndex = index
				capturedValue = value
			end)

			manager:ArrayRemove(manager.Proxy.items, 2)

			expect(eventCount).is(1)
			expect(capturedPath).is_shallow_equal { "items" }
			expect(capturedIndex).is(2)
			expect(capturedValue).is("Shield")

			connection:Disconnect()
			manager:Destroy()
		end)

		test("table.insert on proxy arrays is rejected", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			expect(function()
				table.insert(manager.Proxy.items, "Potion")
			end).fails_with("invalid argument #1 to 'insert' %(table expected, got userdata%)")

			-- Ensure data was not mutated by the rejected call.
			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("table.remove on proxy arrays is rejected", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			expect(function()
				table.remove(manager.Proxy.items, 1)
			end).fails_with("invalid argument #1 to 'remove' %(table expected, got userdata%)")

			-- Ensure data was not mutated by the rejected call.
			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("held proxy key updates after insert shifts it", function()
			-- Hold a proxy to items[1] (a table), then insert before it.
			-- Writes through the held proxy must land at items[2] (the new index)
			-- and the change event path must report {"items", 2}.
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			-- Grab the proxy for items[1] before any insert.
			local heldProxy = manager.Proxy.items[1]
			expect(heldProxy).exists()

			local capturedPath = nil
			manager:OnValueChange({ "items", 2, "value" }, function(_new, _old, metadata)
				capturedPath = metadata.OriginPath
			end)

			-- Insert a new item before index 1, shifting items[1] → items[2].
			manager:ArrayInsert({ "items" }, 1, { value = 99 })

			-- Write through the held proxy — should now target items[2].
			heldProxy.value = 42

			-- The underlying data at the new index should be updated.
			expect(manager:Get { "items", 2, "value" }).is(42)
			-- The event path should reflect the live index.
			expect(capturedPath).exists()
			expect(capturedPath[1]).is("items")
			expect(capturedPath[2]).is(2)
			expect(capturedPath[3]).is("value")

			manager:Destroy()
		end)

		test("held proxy key updates after remove shifts it", function()
			-- Hold a proxy to items[2], then remove items[1].
			-- Writes through the held proxy must land at items[1] (the new index).
			local manager = TableManager.new {
				items = { { value = 0 }, { value = 20 } },
			}

			local heldProxy = manager.Proxy.items[2]
			expect(heldProxy).exists()

			local capturedPath = nil
			manager:OnValueChange({ "items", 1, "value" }, function(_new, _old, metadata)
				capturedPath = metadata.OriginPath
			end)

			-- Remove items[1], shifting items[2] → items[1].
			manager:ArrayRemove({ "items" }, 1)

			-- Write through the held proxy — should now target items[1].
			heldProxy.value = 77

			expect(manager:Get { "items", 1, "value" }).is(77)
			expect(capturedPath).exists()
			expect(capturedPath[1]).is("items")
			expect(capturedPath[2]).is(1)
			expect(capturedPath[3]).is("value")

			manager:Destroy()
		end)
	end)

	describe("Proxy Key Tracking", function()
		test("multiple inserts accumulate key shifts on a held proxy", function()
			-- Each insert before the held proxy should add 1 to its key.
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			local heldProxy = manager.Proxy.items[1]

			manager:ArrayInsert({ "items" }, 1, { value = 1 })
			manager:ArrayInsert({ "items" }, 1, { value = 2 })
			manager:ArrayInsert({ "items" }, 1, { value = 3 })

			-- heldProxy should now be at index 4
			heldProxy.value = 99

			expect(manager:Get { "items", 4, "value" }).is(99)
			-- items 1-3 should be the newly inserted ones, untouched
			expect(manager:Get { "items", 1, "value" }).is(3)
			expect(manager:Get { "items", 2, "value" }).is(2)
			expect(manager:Get { "items", 3, "value" }).is(1)

			manager:Destroy()
		end)

		test("fresh proxy access returns same object after shift", function()
			-- After insert shifts items[1] → items[2], accessing manager.Proxy.items[2]
			-- must return the exact same proxy object (not a duplicate).
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			local heldProxy = manager.Proxy.items[1]
			manager:ArrayInsert({ "items" }, 1, { value = 99 })

			local freshProxy = manager.Proxy.items[2]
			expect(freshProxy).is(heldProxy)

			manager:Destroy()
		end)

		test("proxy below insert point is not shifted", function()
			-- Inserting at index 3 must not change the key of a proxy at index 1.
			local manager = TableManager.new {
				items = { { value = 1 }, { value = 2 }, { value = 3 } },
			}

			local proxy1 = manager.Proxy.items[1]

			manager:ArrayInsert({ "items" }, 3, { value = 99 })

			-- proxy1 should still report index 1
			proxy1.value = 55

			expect(manager:Get { "items", 1, "value" }).is(55)
			-- The original items[2] should be unaffected
			expect(manager:Get { "items", 2, "value" }).is(2)

			manager:Destroy()
		end)

		test("dead proxy after remove does not corrupt the live array data", function()
			-- items[1] is removed. Writing through the dead proxy must write to the
			-- removed table's own fields — NOT to the new items[1] (the shifted item).
			local manager = TableManager.new {
				items = { { value = 10 }, { value = 20 } },
			}

			local deadProxy = manager.Proxy.items[1]
			local survivorProxy = manager.Proxy.items[2]

			manager:ArrayRemove({ "items" }, 1)

			-- The survivor (was items[2]) should now be at items[1].
			expect(manager:Get { "items", 1, "value" }).is(20)

			-- Writing through the dead proxy must NOT land in the live array slot.
			deadProxy.value = 999

			-- The live items[1] (the survivor) must be unchanged.
			expect(survivorProxy.value).is(20)
			expect(manager:Get { "items", 1, "value" }).is(20)

			manager:Destroy()
		end)

		test("proxies in a sibling array are not shifted", function()
			-- Insert into array `a` must leave proxies in array `b` at their original keys.
			local manager = TableManager.new {
				a = { { value = 1 } },
				b = { { value = 2 } },
			}

			local bProxy1 = manager.Proxy.b[1]

			manager:ArrayInsert({ "a" }, 1, { value = 99 })

			-- bProxy1 should still be at index 1
			bProxy1.value = 77

			expect(manager:Get { "b", 1, "value" }).is(77)

			manager:Destroy()
		end)

		test("nested array shift updates path of deeply held proxy", function()
			-- Hold a proxy to items[1].nested[2].
			-- Insert at items[1].nested index 1 should shift the held proxy to nested[3],
			-- and _GetLivePath should report {"items", 1, "nested", 3}.
			local manager = TableManager.new {
				items = { { nested = { { v = 1 }, { v = 2 } } } },
			}

			-- Navigate to nested[2] via proxy chain (avoids mixed-type path literals)
			local heldProxy = manager.Proxy.items[1].nested[2]
			expect(heldProxy).exists()

			-- Insert at the front of the nested array through proxy reference
			local nestedProxy = manager.Proxy.items[1].nested
			manager:ArrayInsert(nestedProxy, 1, { v = 99 })

			-- Write through the held proxy — should land at nested index 3 now
			heldProxy.v = 42

			-- Verify data via proxy navigation (no mixed-type literals needed)
			expect(manager.Proxy.items[1].nested[3].v).is(42)
			expect(manager.Proxy.items[1].nested[1].v).is(99)

			-- The outer items[1] proxy key must NOT have changed (insert was in the nested array)
			local outerProxy = manager.Proxy.items[1]
			outerProxy.nested = outerProxy.nested -- harmless read; ensure proxy still alive
			expect(manager:Get { "items", 1 }).exists()

			manager:Destroy()
		end)

		test("tostring of held proxy reflects live index after shift", function()
			local manager = TableManager.new {
				items = { { value = 1 } },
			}

			local heldProxy = manager.Proxy.items[1]
			expect(tostring(heldProxy)).is("TableManager.Data(items.1)")

			manager:ArrayInsert({ "items" }, 1, { value = 99 })

			expect(tostring(heldProxy)).is("TableManager.Data(items.2)")

			manager:Destroy()
		end)

		test("iteration after shift returns correct current keys", function()
			-- After an insert, iterating the parent proxy must yield the actual
			-- current indices — not stale pre-shift keys.
			local manager = TableManager.new {
				items = { { v = 1 }, { v = 2 } },
			}

			-- Hold a proxy for items[1] to ensure it exists in _originalToProxy
			local _ = manager.Proxy.items[1]

			manager:ArrayInsert({ "items" }, 1, { v = 0 })

			local keys = {}
			for k in manager.Proxy.items do
				table.insert(keys, k)
			end
			table.sort(keys)

			expect(#keys).is(3)
			expect(keys[1]).is(1)
			expect(keys[2]).is(2)
			expect(keys[3]).is(3)

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

			manager:ArrayInsert({ "game", "players" }, "Charlie")

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

			manager:ArrayRemove({ "game", "players" }, 2)

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
				player = { health = 100, mana = 50 :: number? },
			}

			manager.Proxy.player.mana = nil

			expect(manager.Proxy.player.mana).is(nil)
			expect(manager.Proxy.player.health).is(100)

			manager:Destroy()
		end)

		test("should handle root path changes", function()
			local manager = TableManager.new {
				player = { health = 100 },
				settings = nil :: any,
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
			manager:ArrayInsert({ "game", "world", "players" }, { name = "Charlie", health = 100 })

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

			manager:ArrayInsert({ "inventory" }, "Shield")
			manager:ArrayInsert({ "inventory" }, "Potion")
			manager:ArrayRemove({ "inventory" }, 2)

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

		test("should respect ListenDepth=0 for forced notifications (no ancestor firing)", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local unlimited = 0
			local directOnly = 0

			-- Default: depth=nil (fires for all ancestor notifications)
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, _metadata)
				unlimited += 1
			end)

			-- ListenDepth = 0: should NOT fire for ancestor notifications
			manager:OnValueChange({ "player" }, function(_newValue, _oldValue, _metadata)
				directOnly += 1
			end, { ListenDepth = 0 })

			-- Force notification at descendant path
			manager:ForceNotify { "player", "health" }

			-- Only the unlimited listener should fire for the ancestor notification
			expect(unlimited).is(1)
			expect(directOnly).is(0)

			manager:Destroy()
		end)
	end)

	describe("Schema Validation", function()
		test("re-exports T module for schema helpers", function()
			expect(type(TableManager.T)).is("table")
			expect(type(TableManager.T.interface)).is("function")
			expect(type(TableManager.T.GetMeta)).is("function")
		end)

		test("does not require GetSchemaMeta when schema is configured", function()
			local manager = TableManager.new({ value = 1 }, {
				Schema = T.interface { value = T.number },
			})

			expect(manager.Proxy.value).is(1)
			manager:Destroy()
		end)

		test("validates initial data against schema at creation", function()
			local ok, err = pcall(function()
				TableManager.new({ value = "bad" }, {
					Schema = T.interface { value = T.number },
				})
			end)

			expect(ok).is(false)
			expect(type(err)).is("string")
		end)

		test("calls OnValidationFailed for invalid initial data", function()
			local failures = 0
			local capturedPath = ""
			local capturedMessage = ""

			local ok = pcall(function()
				TableManager.new({ value = "bad" }, {
					Schema = T.interface { value = T.number },
					OnValidationFailed = function(path, _value, err)
						failures += 1
						capturedPath = table.concat(path, ".")
						capturedMessage = err
					end,
				})
			end)

			expect(ok).is(false)
			expect(failures).is(1)
			expect(capturedPath).is("")
			expect(type(capturedMessage)).is("string")
		end)

		test("blocks invalid proxy writes and calls OnValidationFailed", function()
			local failures = {}
			local manager = TableManager.new({
				player = { health = 100, name = "Builderman" },
			}, {
				Schema = T.interface {
					player = T.interface {
						health = T.numberConstrained(0, 100),
						name = T.string,
					},
				},
				OnValidationFailed = function(path, value, err)
					table.insert(failures, {
						path = table.concat(path, "."),
						value = value,
						err = err,
					})
				end,
			})

			manager.Proxy.player.health = 80
			expect(manager.Proxy.player.health).is(80)

			manager.Proxy.player.health = 150
			expect(manager.Proxy.player.health).is(80)
			expect(#failures).is(1)
			expect(failures[1].path).is("player.health")
			expect(type(failures[1].err)).is("string")

			manager:Destroy()
		end)

		test("allows unschemed paths to remain permissive", function()
			local failures = 0
			local manager = TableManager.new({
				player = { health = 100, mana = 50 },
			}, {
				Schema = T.interface {
					player = T.interface {
						health = T.number,
					},
				},
				OnValidationFailed = function()
					failures += 1
				end,
			})

			manager.Proxy.player.mana = 10
			expect(manager.Proxy.player.mana).is(10)
			expect(failures).is(0)

			manager:Destroy()
		end)

		test("validates ArrayInsert values against array element schema", function()
			local failures = 0
			local manager = TableManager.new({
				inventory = { "sword" },
			}, {
				Schema = T.interface {
					inventory = T.array(T.string),
				},
				OnValidationFailed = function()
					failures += 1
				end,
			})

			manager:ArrayInsert({ "inventory" }, "shield")
			expect(manager.Proxy.inventory[2]).is("shield")

			manager:ArrayInsert({ "inventory" }, 999)
			expect(manager.Proxy.inventory[3]).is(nil)
			expect(failures).is(1)

			manager:Destroy()
		end)

		test("supports optional fields with nil assignments", function()
			local failures = 0
			local manager = TableManager.new({
				player = { nickname = "Rail" },
			}, {
				Schema = T.interface {
					player = T.interface {
						nickname = T.optional(T.string),
					},
				},
				OnValidationFailed = function()
					failures += 1
				end,
			})
			local proxy: any = manager.Proxy

			proxy.player.nickname = nil
			expect(proxy.player.nickname).is(nil)

			proxy.player.nickname = 123
			expect(proxy.player.nickname).is(nil)
			expect(failures).is(1)

			manager:Destroy()
		end)
	end)

	describe("Batch / Suspend / Resume", function()
		test("Batch suppresses intermediate signals and fires once at flush", function()
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

			-- Only the net changes should fire (health: 100→60, mana: 50→30)
			-- Each generates one ValueChanged + one KeyChanged
			expect(valueChangedCount).is(2)
			expect(keyChangedCount).is(2)

			manager:Destroy()
		end)

		test("Batch with no net change fires nothing", function()
			local manager = TableManager.new {
				x = 1,
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Batch(function()
				manager.Proxy.x = 99
				manager.Proxy.x = 1 -- back to original
			end)

			expect(fired).is(0)

			manager:Destroy()
		end)

		test("nested Batch call is a no-op (inner window ignored)", function()
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

			-- Should fire exactly once at outer flush
			expect(fired).is(1)
			expect(manager.Proxy.a).is(2)

			manager:Destroy()
		end)

		test("Batch with ArrayInsert emits ArrayInserted on flush", function()
			local manager = TableManager.new {
				items = { "a", "b" },
			}

			-- Track that no signals fire while the batch function body is executing.
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
			-- Final array should be {"a","b","c","d"}
			expect(manager.Proxy.items[3]).is("c")
			expect(manager.Proxy.items[4]).is("d")

			manager:Destroy()
		end)

		test("Batch with ArrayRemove emits ArrayRemoved on flush", function()
			local manager = TableManager.new {
				items = { "a", "b", "c" },
			}

			local removedEvents: { { index: number, value: any } } = {}
			manager.ArrayRemoved:Connect(function(_path, index, value)
				table.insert(removedEvents, { index = index, value = value })
			end)

			manager:Batch(function()
				manager:ArrayRemove({ "items" }, 1) -- removes "a"; array becomes {"b","c"}
				manager:ArrayRemove({ "items" }, 1) -- removes "b"; array becomes {"c"}
			end)

			expect(#removedEvents).is(2)
			-- Final array should be {"c"}
			expect(manager.Proxy.items[1]).is("c")
			expect(manager.Proxy.items[2]).is(nil)

			manager:Destroy()
		end)

		test("Batch: insert then remove same element fires nothing (born-and-died)", function()
			local manager = TableManager.new {
				items = { "a", "b" },
			}

			local insertCount = 0
			local removeCount = 0
			manager.ArrayInserted:Connect(function()
				insertCount += 1
			end)
			manager.ArrayRemoved:Connect(function()
				removeCount += 1
			end)

			manager:Batch(function()
				manager:ArrayInsert({ "items" }, "c") -- items = {"a","b","c"}
				manager:ArrayRemove({ "items" }, 3) -- items = {"a","b"}  (net: nothing)
			end)

			-- Net effect: no change → no events
			expect(insertCount).is(0)
			expect(removeCount).is(0)
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("Batch: mixed scalar and array changes flush correctly", function()
			local manager = TableManager.new {
				score = 0,
				items = { "x" },
			}

			local scoreChanged = 0
			local itemsInserted = 0
			manager.ValueChanged:Connect(function(path)
				if path[1] == "score" then
					scoreChanged += 1
				end
			end)
			manager.ArrayInserted:Connect(function()
				itemsInserted += 1
			end)

			manager:Batch(function()
				manager.Proxy.score = 10
				manager:ArrayInsert({ "items" }, "y")
			end)

			expect(scoreChanged).is(1)
			expect(itemsInserted).is(1)
			expect(manager.Proxy.score).is(10)
			expect(manager.Proxy.items[2]).is("y")

			manager:Destroy()
		end)

		test("Suspend/Resume API works like Batch", function()
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
			expect(fired).is(0) -- nothing yet
			manager:Resume()

			expect(fired).is(1) -- only the net change v:1→3
			expect(manager.Proxy.v).is(3)

			manager:Destroy()
		end)

		test("Resume without Suspend is a no-op", function()
			local manager = TableManager.new { x = 1 }
			-- Should not error or do anything
			manager:Resume()
			manager:Resume()
			expect(manager.Proxy.x).is(1)
			manager:Destroy()
		end)

		test("ForceNotify during batch is suppressed", function()
			local manager = TableManager.new { x = 1 }

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Batch(function()
				manager:ForceNotify { "x" }
			end)

			-- ForceNotify is suppressed during batch; only real changes fire
			expect(fired).is(0)

			manager:Destroy()
		end)
	end)
end
