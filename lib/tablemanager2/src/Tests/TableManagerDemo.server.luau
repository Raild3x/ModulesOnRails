--[=[
	@class TableManagerDemo
	
	Simple demo showcasing TableManager functionality with userdata proxies.
	This demonstrates best practices for working with proxy tables.
]=]

local TableManager = require(script.Parent.Parent)

local tm = TableManager.new {
	Player = {
		Name = "Alice",
		Level = 1,
		Gold = 100,
	},
	Inventory = {
		Potions = {},
	},
}

tm:OnArrayInsert({ "Inventory", "Potions" }, function(index, value)
	print(string.format("[OnArrayInsert] Potion inserted at index %d: %s", index, value))
end)

tm.ValueChanged:Connect(function(path, newValue, oldValue)
	print(
		string.format(
			"Global change detected! Path: %s, Value: %s -> %s",
			table.concat(path, "."),
			tostring(oldValue),
			tostring(newValue)
		)
	)
end)

tm.ArrayInserted:Connect(function(path, index, value)
	print(
		string.format(
			"Global array insert detected! Path: %s, Index: %d, Value: %s",
			table.concat(path, "."),
			index,
			tostring(value)
		)
	)
end)

tm.KeyAdded:Connect(function(path, key, value)
	print(
		string.format(
			"Global key added detected! Path: %s, Key: %s, Value: %s",
			table.concat(path, "."),
			tostring(key),
			tostring(value)
		)
	)
end)

tm.KeyChanged:Connect(function(path, key, newValue, oldValue)
	print(
		string.format(
			"Global key change detected! Path: %s, Key: %s, Value: %s -> %s",
			table.concat(path, "."),
			tostring(key),
			tostring(oldValue),
			tostring(newValue)
		)
	)
end)

tm:OnArraySet({ "Inventory", "Potions" }, function(index, value, oldValue)
	print(
		string.format(
			"[OnArraySet] Potion at index %d changed from %s to %s",
			index,
			tostring(oldValue),
			tostring(value)
		)
	)
end)

tm:OnKeyChange("Inventory", function(key, newValue, oldValue)
	print(
		string.format("[OnKeyChange] Inventory %s changed from %s to %s", key, tostring(oldValue), tostring(newValue))
	)
end)

tm:OnKeyChange({ "Inventory", "Potions" }, function(key, newValue, oldValue)
	print(string.format("[OnKeyChange] Potion %s changed from %s to %s", key, tostring(oldValue), tostring(newValue)))
end)

tm:OnKeyAdd({ "Inventory", "Potions" }, function(key, value)
	print(string.format("[OnKeyAdd] Potion added: %s = %s", key, tostring(value)))
end)

tm:Insert({ "Inventory", "Potions" }, "Health Potion")
task.wait()
print("\nChanging Potion")
tm.Data.Inventory.Potions[1] = "Super Health Potion"

-- print("\n========== TABLEMANAGER DEMO ==========\n")

-- -- Example 1: Basic value change detection
-- print("--- Example 1: Basic Value Changes ---")
-- local playerData = TableManager.new {
-- 	Name = "Alice",
-- 	Level = 1,
-- 	Gold = 100,
-- }

-- playerData:OnValueChange({ "Level" }, function(newValue, oldValue, metadata)
-- 	print(string.format("Player leveled up! %d -> %d (Source: %s)", oldValue, newValue, metadata.SourceDirection))
-- end)

-- playerData.Data.Level = 5
-- task.wait(0.1)

-- -- Example 2: Array operations (use TableManager methods, NOT table.insert!)
-- print("\n--- Example 2: Array Operations ---")
-- local inventoryManager = TableManager.new {
-- 	Inventory = {},
-- }

-- inventoryManager:OnArrayInsert({ "Inventory" }, function(index, value)
-- 	print(string.format("Item added at index %d: %s", index, value))
-- end)

-- -- ✅ CORRECT: Use TableManager methods
-- inventoryManager:Insert({ "Inventory" }, "Sword")
-- inventoryManager:Insert({ "Inventory" }, "Shield")
-- inventoryManager:Insert({ "Inventory" }, "Potion")
-- task.wait(0.1)

-- -- ✅ CORRECT: Length operator works on proxies!
-- print(string.format("Inventory has %d items", #inventoryManager.Data.Inventory))

-- -- Example 3: Nested change detection
-- print("\n--- Example 3: Nested Changes ---")
-- local gameState = TableManager.new {
-- 	World = {
-- 		Region = {
-- 			Zone = 1,
-- 			Temperature = 20,
-- 		},
-- 	},
-- }

-- -- Listen to parent path to detect all child changes
-- gameState:OnValueChange({ "World" }, function(newValue, oldValue, metadata)
-- 	print(
-- 		string.format(
-- 			"Change detected! Path: %s, Direction: %s, Value: %s -> %s",
-- 			table.concat(metadata.SourcePath, "."),
-- 			metadata.SourceDirection,
-- 			tostring(oldValue),
-- 			tostring(newValue)
-- 		)
-- 	)
-- end)

-- gameState.Data.World.Region.Zone = 2
-- gameState.Data.World.Region.Temperature = 25
-- task.wait(0.1)

-- -- Example 4: Iteration (works with generic for!)
-- print("\n--- Example 4: Iteration with Generic For ---")
-- local config = TableManager.new {
-- 	Settings = {
-- 		Volume = 50,
-- 		Quality = "High",
-- 		Fullscreen = true,
-- 	},
-- 	Tags = { "Player", "Premium", "Verified" },
-- }

-- print("Settings (using generic for):")
-- for key, value in config.Data.Settings do
-- 	print(string.format("  %s = %s", key, tostring(value)))
-- end

-- print("\nTags (using generic for):")
-- for i, tag in config.Data.Tags do
-- 	print(string.format("  [%d] = %s", i, tag))
-- end

-- -- Note: pairs() and ipairs() do NOT work on userdata proxies!
-- -- Always use generic for: for k, v in proxy do

-- -- Example 5: Key change tracking
-- print("\n--- Example 5: Key Change Tracking ---")
-- local userPrefs = TableManager.new {
-- 	Theme = "Dark",
-- 	Language = "en",
-- }

-- userPrefs:OnKeyChange({}, function(key, newValue, oldValue)
-- 	print(string.format("Setting changed: %s = %s (was %s)", key, tostring(newValue), tostring(oldValue)))
-- end)

-- userPrefs:OnKeyAdd({}, function(key, value)
-- 	print(string.format("New setting added: %s = %s", key, tostring(value)))
-- end)

-- userPrefs.Data.Theme = "Light" -- Triggers OnKeyChange
-- userPrefs.Data.FontSize = 14 -- Triggers OnKeyAdd
-- task.wait(0.1)

-- -- Example 6: Global signals
-- print("\n--- Example 6: Global Signals ---")
-- local store = TableManager.new {
-- 	Products = {},
-- 	Revenue = 0,
-- }

-- -- Global signal fires for ALL changes
-- store.ValueChanged:Connect(function(path, newValue, oldValue)
-- 	print(
-- 		string.format(
-- 			"Global: %s changed from %s to %s",
-- 			table.concat(path, "."),
-- 			tostring(oldValue),
-- 			tostring(newValue)
-- 		)
-- 	)
-- end)

-- store.Data.Revenue = 1000
-- store.Data.Products = { "Apple", "Banana" }
-- task.wait(0.1)

-- -- Example 7: Proxy comparison helpers
-- print("\n--- Example 7: Proxy Comparisons ---")
-- local sharedData = { Value = 42 }
-- local tm1 = TableManager.new { Data = sharedData }
-- local tm2 = TableManager.new { Data = sharedData }

-- -- Both proxies wrap the same original table
-- if tm1.Data.Data == tm2.Data.Data then
-- 	print("✓ Proxies of same table are equal (proxy == proxy)")
-- end

-- -- To compare proxy with original, use ProxyManager:Equals
-- if tm1._proxyManager:Equals(tm1.Data.Data, sharedData) then
-- 	print("✓ Proxy equals original (using ProxyManager:Equals)")
-- end

-- -- Or get the original and compare directly
-- if tm1._proxyManager:GetOriginal(tm1.Data.Data) == sharedData then
-- 	print("✓ Original extracted from proxy matches")
-- end

-- -- Example 8: Set and Get methods
-- print("\n--- Example 8: Set and Get Methods ---")
-- local gameData = TableManager.new {
-- 	Player = {
-- 		Name = "Alice",
-- 		Stats = {
-- 			Health = 100,
-- 			Mana = 50,
-- 		},
-- 	},
-- 	Settings = {
-- 		Volume = 75,
-- 	},
-- }

-- -- Get values using path
-- print("Player name:", gameData:Get { "Player", "Name" })
-- print("Player health:", gameData:Get { "Player", "Stats", "Health" })

-- -- Set values using path (equivalent to direct assignment)
-- gameData:Set({ "Player", "Stats", "Health" }, 80)
-- gameData:Set({ "Settings", "Volume" }, 100)

-- print("Updated health:", gameData:Get { "Player", "Stats", "Health" })
-- print("Updated volume:", gameData:Get { "Settings", "Volume" })

-- -- Get returns proxies for nested tables
-- local statsProxy = gameData:Get { "Player", "Stats" }
-- print("Stats proxy health:", statsProxy.Health) -- Can use like normal table

-- -- Set triggers all the same events as direct assignment
-- gameData:OnValueChange({ "Player", "Name" }, function(newValue, oldValue)
-- 	print(string.format("Name changed from %s to %s via :Set()", oldValue, newValue))
-- end)

-- gameData:Set({ "Player", "Name" }, "Bob")
-- task.wait(0.05)

-- print("\n========== DEMO COMPLETE ==========\n")

-- --[=[
-- 	IMPORTANT NOTES FOR USERDATA PROXIES:

-- 	✅ DO:
-- 	- Use # operator for length: #proxy.Data.array
-- 	- Use generic for iteration: for k, v in proxy do
-- 	- Use TableManager methods: :Insert(), :Remove(), :Set()
-- 	- Use ProxyManager:Equals() for proxy-to-original comparison

-- 	❌ DON'T:
-- 	- Use pairs(proxy) or ipairs(proxy) -- Won't work on userdatas!
-- 	- Use table.insert(proxy.Data.array, value) -- Won't work!
-- 	- Use table.remove(proxy.Data.array) -- Won't work!
-- 	- Compare proxy == original directly -- Use ProxyManager:Equals()
-- 	- Use rawget/rawset on proxies

-- 	See PROXY_USERDATA_NOTES.md for detailed documentation.
-- ]=]

-- return {
-- 	RunDemo = function()
-- 		-- The demo runs automatically when required
-- 		-- This function is provided for explicit invocation if needed
-- 	end,
-- }
