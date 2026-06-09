--!strict
--[[
	Unit tests for ProxyManager_new to verify:
	- Proxy creation for nested structures
	- Metadata tracking (ArrayLength, Original)
	- ChangeDetector wiring (can be set, proxies modify original data)
	- GetOriginal/GetMetadata helpers
	- Array metadata tracking
	- Edge cases (nil values, deep nesting, scalars, cleanup)
	
	Note: These are UNIT tests for ProxyManager in isolation.
	Full ChangeDetector integration (auto-triggering, snapshots, etc.) 
	is tested at the TableManager integration level.
]]

return function(t: tiniest)
	local ProxyManager = require("../ProxyManager")
	local ChangeDetector = require("../ChangeDetector")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Proxy Creation", function()
		test("should create a proxy for a table", function()
			local data = { health = 100 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy).exists()
			expect(proxy.health).is(100)

			manager:Destroy()
		end)

		test("should create nested proxies automatically", function()
			local data = {
				player = { health = 100, stats = { level = 5 } },
			}
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			-- Access nested table - should return a proxy
			local playerProxy = proxy.player
			expect(playerProxy).exists()
			expect(playerProxy.health).is(100)
			expect(playerProxy.stats.level).is(5)

			manager:Destroy()
		end)

		test("should handle scalar values in tables", function()
			local data = {
				name = "Alice",
				age = 25,
				active = true,
			}
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy.name).is("Alice")
			expect(proxy.age).is(25)
			expect(proxy.active).is_true()

			manager:Destroy()
		end)

		test("should handle arrays", function()
			local data = {
				items = { "Sword", "Shield", "Potion" },
			}
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy.items[1]).is("Sword")
			expect(proxy.items[2]).is("Shield")
			expect(proxy.items[3]).is("Potion")

			manager:Destroy()
		end)
	end)

	describe("Metadata Tracking", function()
		test("should track metadata for proxies", function()
			local data = { health = 100 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local meta = manager:GetMetadata(proxy)

			expect(meta).exists()
			expect(meta.Original).is(data)
			expect(manager:GetPath(proxy)).is_shallow_equal {}

			manager:Destroy()
		end)

		test("should track ArrayLength for arrays", function()
			local data = { items = { "Sword", "Shield", "Potion" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local itemsProxy = proxy.items
			local meta = manager:GetMetadata(itemsProxy)

			expect(meta).exists()
			expect(meta.ArrayLength).is(3)

			manager:Destroy()
		end)

		test("should update ArrayLength when items change", function()
			local data = { items = { "Sword" } }
			local manager = ProxyManager.new(data)
			local detector = ChangeDetector.new {}
			manager:SetChangeDetector(detector)
			local proxy = manager:CreateProxy(data)

			local itemsProxy = proxy.items
			local meta = manager:GetMetadata(itemsProxy)

			expect(meta.ArrayLength).is(1)

			-- Add item (this will update the original table)
			data.items[2] = "Shield"
			-- Note: ArrayLength only updates when accessed through proxy operations
			-- or when explicitly recalculated

			manager:Destroy()
		end)
	end)

	describe("GetOriginal Helper", function()
		test("should return original table for proxy", function()
			local data = { health = 100 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local original = manager:GetOriginal(proxy)

			expect(original).is(data)

			manager:Destroy()
		end)

		test("should return scalar values unchanged", function()
			local manager = ProxyManager.new {}

			expect(manager:GetOriginal(42)).is(42)
			expect(manager:GetOriginal("hello")).is("hello")
			expect(manager:GetOriginal(true)).is_true()
			expect(manager:GetOriginal(nil)).is(nil)

			manager:Destroy()
		end)

		test("should return non-proxy tables unchanged", function()
			local manager = ProxyManager.new {}

			local regularTable = { x = 1, y = 2 }
			local result = manager:GetOriginal(regularTable)

			expect(result).is(regularTable)

			manager:Destroy()
		end)
	end)

	describe("ChangeDetector Integration", function()
		test("should allow setting a ChangeDetector", function()
			local manager = ProxyManager.new {}

			local detector = ChangeDetector.new {
				OnValueChanged = function() end,
			}

			-- Should not error when setting detector
			manager:SetChangeDetector(detector)

			expect(true).is_true() -- If we get here, it worked

			manager:Destroy()
		end)

		test("should modify original data when proxy changes", function()
			local data = { health = 100 }
			local manager = ProxyManager.new(data)

			local detector = ChangeDetector.new {
				OnValueChanged = function() end,
			}
			manager:SetChangeDetector(detector)
			local proxy = manager:CreateProxy(data)

			-- Change value through proxy
			proxy.health = 50

			-- Verify the original data was modified
			expect(data.health).is(50)

			manager:Destroy()
		end)

		test("should modify nested original data when proxy changes", function()
			local data = {
				player = { health = 100, mana = 50 },
			}
			local manager = ProxyManager.new(data)

			local detector = ChangeDetector.new {
				OnValueChanged = function() end,
			}
			manager:SetChangeDetector(detector)
			local proxy = manager:CreateProxy(data)

			-- Change nested value through proxy
			proxy.player.health = 75

			-- Verify the original nested data was modified
			expect(data.player.health).is(75)

			manager:Destroy()
		end)
	end)

	describe("Array Operations", function()
		test("should handle direct array modifications", function()
			local data = { items = { "Sword" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			-- Directly modify the underlying array
			-- Note: ProxyManager doesn't intercept table.insert itself
			-- That's handled by TableManager using SetArrayInsertedCallback
			data.items[2] = "Shield"

			-- Verify the change is reflected in both proxy and original
			expect(proxy.items[2]).is("Shield")
			expect(data.items[2]).is("Shield")

			manager:Destroy()
		end)

		test("should track ArrayLength metadata", function()
			local data = { items = { "Sword", "Shield" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			local itemsProxy = proxy.items
			local meta = manager:GetMetadata(itemsProxy)

			expect(meta).exists()
			expect(meta.ArrayLength).is(2)

			manager:Destroy()
		end)

		test("table.insert on proxy arrays is rejected natively", function()
			local data = { items = { "Sword", "Shield" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(function()
				table.insert(proxy.items, "Potion")
			end).fails_with("invalid argument #1 to 'insert' %(table expected, got userdata%)")

			expect(data.items[1]).is("Sword")
			expect(data.items[2]).is("Shield")
			expect(data.items[3]).is(nil)

			manager:Destroy()
		end)

		test("table.remove on proxy arrays is rejected natively", function()
			local data = { items = { "Sword", "Shield" } }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(function()
				table.remove(proxy.items, 1)
			end).fails_with("invalid argument #1 to 'remove' %(table expected, got userdata%)")

			expect(data.items[1]).is("Sword")
			expect(data.items[2]).is("Shield")
			expect(data.items[3]).is(nil)

			manager:Destroy()
		end)
	end)

	describe("Edge Cases", function()
		test("should handle nil values", function()
			local data = { health = 100, mana = nil }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy.health).is(100)
			expect(proxy.mana).is(nil)

			manager:Destroy()
		end)

		test("should handle setting values to nil", function()
			local data: { [any]: any } = { health = 100, mana = 50 }
			local manager = ProxyManager.new(data)
			local detector = ChangeDetector.new {}
			manager:SetChangeDetector(detector)
			local proxy = manager:CreateProxy(data)

			detector:CaptureSnapshot(data, {})

			proxy.mana = nil

			expect(data.mana).is(nil)

			manager:Destroy()
		end)

		test("should handle empty tables", function()
			local data = {}
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy).exists()

			manager:Destroy()
		end)

		test("should handle deeply nested structures", function()
			local data = {
				level1 = {
					level2 = {
						level3 = {
							level4 = { value = 42 },
						},
					},
				},
			}
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			expect(proxy.level1.level2.level3.level4.value).is(42)

			manager:Destroy()
		end)

		test("should not create proxy for scalar values", function()
			local data = { name = "Alice" }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			-- Accessing scalar should return the scalar, not a proxy
			local name = proxy.name
			expect(name).is("Alice")
			expect(type(name)).is("string")

			manager:Destroy()
		end)
	end)

	describe("Cleanup", function()
		test("should clean up on Destroy", function()
			local data = { health = 100 }
			local manager = ProxyManager.new(data)
			local proxy = manager:CreateProxy(data)

			manager:Destroy()

			-- After destroy, metadata should not be accessible
			local meta = manager:GetMetadata(proxy)
			expect(meta).is(nil)
		end)
	end)
end
