# TableManager Examples Guide

Comprehensive examples for using the TableManager system.

---

## Table of Contents

1. [Basic Setup](#basic-setup)
2. [Value Changes](#value-changes)
3. [Array Operations](#array-operations)
4. [Key Tracking](#key-tracking)
5. [Parent/Child Relationships](#parentchild-relationships)
6. [Global Signals](#global-signals)
7. [Path-Based Access](#path-based-access)
8. [Fusion Integration](#fusion-integration)
9. [Common Patterns](#common-patterns)
10. [Best Practices](#best-practices)

---

## Basic Setup

### Creating a TableManager

```lua
local TableManager = require(path.to.TableManager)

-- Simple creation
local manager = TableManager.new({
    Player = {
        Name = "Alice",
        Level = 1
    }
})

-- Type-safe creation
type GameData = {
    Player: {
        Name: string,
        Level: number,
        Gold: number
    }
}

local gameManager: TableManager<GameData> = TableManager.new({
    Player = {
        Name = "Alice",
        Level = 1,
        Gold = 100
    }
})
```

### Accessing Data

```lua
-- Direct access through proxy
print(manager.Data.Player.Name) -- "Alice"

-- Modification (triggers listeners)
manager.Data.Player.Level = 5

-- Iteration (use generic for, NOT pairs!)
for key, value in manager.Data.Player do
    print(key, "=", value)
end
```

---

## Value Changes

### Basic Value Change Listener

```lua
local manager = TableManager.new({
    Player = { Health = 100 }
})

manager:OnValueChange({"Player", "Health"}, function(newValue, oldValue, metadata)
    print("Health:", oldValue, "→", newValue)
    print("Source:", metadata.SourceDirection) -- "self", "child", or "parent"
end)

manager.Data.Player.Health = 80
-- Output: "Health: 100 → 80"
--         "Source: self"
```

### Observing Nested Changes

```lua
local manager = TableManager.new({
    Game = {
        World = {
            Region = { Zone = 1, Temperature = 20 }
        }
    }
})

-- Listen to parent path
manager:OnValueChange({"Game", "World"}, function(newValue, oldValue, metadata)
    print("Changed at:", table.concat(metadata.SourcePath, "."))
    print("Direction:", metadata.SourceDirection)
end)

-- Change deep nested value
manager.Data.Game.World.Region.Zone = 2
-- Output: "Changed at: Game.World.Region.Zone"
--         "Direction: child"
```

### Root Level Listener

```lua
-- Listen to ALL changes in the entire structure
manager:OnValueChange({}, function(newValue, oldValue, metadata)
    print("Something changed at:", table.concat(metadata.SourcePath, "."))
end)
```

---

## Array Operations

### Array Insertion

```lua
local manager = TableManager.new({
    Inventory = { "Sword", "Shield" }
})

-- Listen for insertions
manager:OnArrayInsert({"Inventory"}, function(index, value, metadata)
    print("Inserted", value, "at index", index)
end)

-- Insert at end
manager:Insert({"Inventory"}, "Potion")
-- Result: {"Sword", "Shield", "Potion"}

-- Insert at specific position
manager:Insert({"Inventory"}, 1, "Bow")
-- Result: {"Bow", "Sword", "Shield", "Potion"}
```

### Array Removal

```lua
local manager = TableManager.new({
    Queue = { "Task1", "Task2", "Task3" }
})

-- Listen for removals
manager:OnArrayRemove({"Queue"}, function(index, oldValue, metadata)
    print("Removed", oldValue, "from index", index)
end)

-- Remove last element
local removed = manager:Remove({"Queue"})
print("Removed:", removed) -- "Task3"

-- Remove specific index
removed = manager:Remove({"Queue"}, 1)
print("Removed:", removed) -- "Task1"
```

### Array Modification

```lua
local manager = TableManager.new({
    Items = { "Bronze Sword", "Iron Shield" }
})

-- Listen for element modifications
manager:OnArraySet({"Items"}, function(index, newValue, oldValue, metadata)
    print("Item", index, "upgraded:", oldValue, "→", newValue)
end)

-- Modify existing element (NOT insertion or removal)
manager.Data.Items[1] = "Steel Sword"
-- Output: "Item 1 upgraded: Bronze Sword → Steel Sword"
```

---

## Key Tracking

### Key Addition

```lua
local manager = TableManager.new({
    Settings = { Volume = 50 }
})

manager:OnKeyAdd({"Settings"}, function(key, value, metadata)
    print("New setting:", key, "=", value)
end)

-- Add new key
manager.Data.Settings.Brightness = 80
-- Output: "New setting: Brightness = 80"

-- Modifying existing key does NOT trigger OnKeyAdd
manager.Data.Settings.Volume = 75 -- No output (triggers OnKeyChange instead)
```

### Key Removal

```lua
local manager = TableManager.new({
    Player = {
        Name = "Alice",
        TempBoost = 10,
        TempBuff = "Speed"
    }
})

manager:OnKeyRemove({"Player"}, function(key, oldValue, metadata)
    print("Removed:", key, "(was", oldValue .. ")")
end)

-- Remove keys by setting to nil
manager.Data.Player.TempBoost = nil
-- Output: "Removed: TempBoost (was 10)"

manager.Data.Player.TempBuff = nil
-- Output: "Removed: TempBuff (was Speed)"
```

### Key Change (Modification)

```lua
local manager = TableManager.new({
    Config = { Timeout = 30, Retries = 3 }
})

manager:OnKeyChange({"Config"}, function(key, newValue, oldValue, metadata)
    print(key, "modified:", oldValue, "→", newValue)
end)

-- Modify existing key (triggers OnKeyChange)
manager.Data.Config.Timeout = 60
-- Output: "Timeout modified: 30 → 60"

-- Add new key (does NOT trigger OnKeyChange, triggers OnKeyAdd)
manager.Data.Config.MaxConnections = 100 -- No output here

-- Remove key (does NOT trigger OnKeyChange, triggers OnKeyRemove)
manager.Data.Config.Retries = nil -- No output here
```

---

## Parent/Child Relationships

### Understanding Source Direction

```lua
local manager = TableManager.new({
    Game = {
        World = {
            Region = { Zone = 1 }
        }
    }
})

manager:OnValueChange({"Game", "World"}, function(newValue, oldValue, metadata)
    local direction = metadata.SourceDirection
    local path = table.concat(metadata.SourcePath, ".")
    
    if direction == "self" then
        print("World table itself changed at:", path)
    elseif direction == "child" then
        print("Child of World changed at:", path)
    elseif direction == "parent" then
        print("Parent of World changed at:", path)
    end
end)

-- Scenario 1: Child change
manager.Data.Game.World.Region.Zone = 2
-- Output: "Child of World changed at: Game.World.Region.Zone"

-- Scenario 2: Self change
manager.Data.Game.World = { Region = { Zone = 3 } }
-- Output: "World table itself changed at: Game.World"

-- Scenario 3: Parent change
manager.Data.Game = { World = { Region = { Zone = 4 } } }
-- Output: "Parent of World changed at: Game"
```

### Cascading Listeners

```lua
local manager = TableManager.new({
    App = {
        UI = {
            Menu = { Visible = true }
        }
    }
})

-- Listener 1: Root level
manager:OnValueChange({}, function(newValue, oldValue, metadata)
    print("[ROOT]", table.concat(metadata.SourcePath, "."))
end)

-- Listener 2: App level
manager:OnValueChange({"App"}, function(newValue, oldValue, metadata)
    print("[APP]", table.concat(metadata.SourcePath, "."))
end)

-- Listener 3: UI level
manager:OnValueChange({"App", "UI"}, function(newValue, oldValue, metadata)
    print("[UI]", table.concat(metadata.SourcePath, "."))
end)

-- One change triggers all three listeners!
manager.Data.App.UI.Menu.Visible = false
-- Output:
-- [ROOT] App.UI.Menu.Visible
-- [APP] App.UI.Menu.Visible
-- [UI] App.UI.Menu.Visible
```

---

## Global Signals

### ValueChanged Signal

```lua
local manager = TableManager.new({
    Player = { Name = "Alice" },
    Settings = { Volume = 75 }
})

-- Listen to ALL value changes globally
manager.ValueChanged:Connect(function(path, newValue, oldValue)
    print("Global change at:", table.concat(path, "."))
    print("Value:", oldValue, "→", newValue)
end)

manager.Data.Player.Name = "Bob"
manager.Data.Settings.Volume = 100
-- Both trigger the global listener
```

### KeyAdded Signal

```lua
-- Listen to ALL key additions globally
manager.KeyAdded:Connect(function(path, key, value)
    print("New key added:", key)
    print("At path:", table.concat(path, "."))
    print("Value:", value)
end)

manager.Data.Player.Level = 1
-- Output: "New key added: Level"
--         "At path: Player"
--         "Value: 1"
```

### ArrayInserted Signal

```lua
local manager = TableManager.new({
    Players = {},
    Items = {}
})

-- Listen to ALL array insertions globally
manager.ArrayInserted:Connect(function(path, index, value)
    print("Array insert at:", table.concat(path, "."))
    print("Index:", index, "Value:", value)
end)

manager:Insert({"Players"}, "Alice")
manager:Insert({"Items"}, "Sword")
-- Both trigger the global listener
```

---

## Path-Based Access

### Using Get Method

```lua
local manager = TableManager.new({
    Player = {
        Name = "Alice",
        Stats = {
            Health = 100,
            Mana = 50
        }
    }
})

-- Get values by path
local name = manager:Get({"Player", "Name"}) -- "Alice"
local health = manager:Get({"Player", "Stats", "Health"}) -- 100

-- Get returns nil for non-existent paths
local missing = manager:Get({"NonExistent", "Path"}) -- nil

-- Get root (returns proxy)
local root = manager:Get({}) -- Same as manager.Data
```

### Using Set Method

```lua
-- Set values by path
manager:Set({"Player", "Name"}, "Bob")
manager:Set({"Player", "Stats", "Health"}, 80)

-- Equivalent to:
-- manager.Data.Player.Name = "Bob"
-- manager.Data.Player.Stats.Health = 80

-- Set triggers all normal events
manager:OnValueChange({"Player", "Name"}, function(newValue, oldValue)
    print("Name changed via Set:", oldValue, "→", newValue)
end)

manager:Set({"Player", "Name"}, "Charlie")
-- Triggers the listener
```

### Dynamic Path Building

```lua
-- Build paths dynamically
local function watchStat(statName)
    local path = {"Player", "Stats", statName}
    
    manager:OnValueChange(path, function(newValue, oldValue)
        print(statName, "changed:", oldValue, "→", newValue)
    end)
end

watchStat("Health")
watchStat("Mana")

-- Both are now watched
manager.Data.Player.Stats.Health = 75
manager.Data.Player.Stats.Mana = 40
```

---

## Fusion Integration

### Creating Fusion State

```lua
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local scope = Fusion.scoped(Fusion)

local manager = TableManager.new({
    Player = { Health = 100, Mana = 50 }
})

-- Create Fusion Values that auto-sync
local healthValue = manager:ToFusionState({"Player", "Health"}, scope)
local manaValue = manager:ToFusionState({"Player", "Mana"}, scope)

-- Use in Fusion UI
local healthBar = scope:New "Frame" {
    Size = scope:Computed(function(use)
        local health = use(healthValue)
        return UDim2.new(health / 100, 0, 1, 0)
    end)
}

-- When TableManager data changes, Fusion UI updates automatically!
manager.Data.Player.Health = 80 -- healthBar resizes
```

### Bidirectional Binding

```lua
local manager = TableManager.new({
    Settings = { Volume = 75 }
})

local volumeValue = manager:ToFusionState({"Settings", "Volume"}, scope)

-- Fusion → TableManager
local slider = scope:New "TextButton" {
    [scope:Out "Activated"] = function()
        volumeValue:set(100) -- Updates both Fusion AND TableManager
    end
}

-- TableManager → Fusion (automatic)
manager.Data.Settings.Volume = 50 -- volumeValue updates automatically
```

---

## Common Patterns

### Undo/Redo System

```lua
local history = {}
local historyIndex = 0

manager.ValueChanged:Connect(function(path, newValue, oldValue)
    -- Record change for undo
    historyIndex += 1
    history[historyIndex] = {
        path = path,
        oldValue = oldValue,
        newValue = newValue
    }
    -- Clear redo history
    for i = historyIndex + 1, #history do
        history[i] = nil
    end
end)

function undo()
    if historyIndex > 0 then
        local change = history[historyIndex]
        manager:Set(change.path, change.oldValue)
        historyIndex -= 1
    end
end

function redo()
    if historyIndex < #history then
        historyIndex += 1
        local change = history[historyIndex]
        manager:Set(change.path, change.newValue)
    end
end
```

### Validation System

```lua
local manager = TableManager.new({
    Player = { Level = 1 }
})

manager:OnValueChange({"Player", "Level"}, function(newValue, oldValue, metadata)
    -- Validate level is within bounds
    if newValue < 1 or newValue > 100 then
        warn("Invalid level:", newValue, "- reverting to", oldValue)
        manager.Data.Player.Level = oldValue
    end
end)

manager.Data.Player.Level = 150 -- Automatically reverted to previous value
```

### Auto-Save System

```lua
local saveDebounce = {}

manager.ValueChanged:Connect(function(path, newValue, oldValue)
    local pathStr = table.concat(path, ".")
    
    -- Cancel existing debounce for this path
    if saveDebounce[pathStr] then
        task.cancel(saveDebounce[pathStr])
    end
    
    -- Schedule save after 2 seconds of no changes
    saveDebounce[pathStr] = task.delay(2, function()
        print("Auto-saving:", pathStr)
        -- Save to DataStore here
        saveDebounce[pathStr] = nil
    end)
end)
```

### Derived Values

```lua
local manager = TableManager.new({
    Player = {
        Stats = {
            Strength = 10,
            Agility = 8
        }
    }
})

-- Auto-calculate total stats
local totalStats = 0

local function updateTotal()
    local strength = manager:Get({"Player", "Stats", "Strength"})
    local agility = manager:Get({"Player", "Stats", "Agility"})
    totalStats = strength + agility
    print("Total stats:", totalStats)
end

manager:OnValueChange({"Player", "Stats"}, function()
    updateTotal()
end)

updateTotal() -- Initial calculation
```

---

## Best Practices

### ✅ DO

```lua
-- Use generic for iteration
for key, value in manager.Data.config do
    print(key, value)
end

-- Use TableManager methods for arrays
manager:Insert({"items"}, "newItem")
manager:Remove({"items"}, 1)

-- Use Set/Get for dynamic paths
manager:Set({"Player", "Stats", statName}, value)

-- Store connections for cleanup
local conn = manager:OnValueChange({}, callback)
-- Later: conn:Disconnect()

-- Use type annotations
type MyData = { ... }
local manager: TableManager<MyData> = TableManager.new({...})
```

### ❌ DON'T

```lua
-- Don't use pairs() or ipairs() on proxies
for k, v in pairs(manager.Data) do end -- ❌ Won't work!

-- Don't use table.* functions on proxies
table.insert(manager.Data.items, "value") -- ❌ Won't work!
table.remove(manager.Data.items) -- ❌ Won't work!

-- Don't compare proxy == original directly
if manager.Data == originalTable then end -- ❌ Won't work!
-- Use: manager._proxyManager:Equals(manager.Data, originalTable)

-- Don't set root directly
manager:Set({}, newTable) -- ❌ Errors!

-- Don't forget to disconnect listeners
manager:OnValueChange({}, callback) -- ❌ Memory leak if never disconnected
```

---

## Summary

TableManager provides a powerful, type-safe way to observe and manage nested table data in Roblox. Key takeaways:

- 🎯 **Automatic change detection** at any depth
- 🔄 **Parent/child relationships** for cascading updates
- 📡 **Global signals** for cross-cutting concerns
- 🎨 **Fusion integration** for reactive UI
- ✅ **Type-safe** with full autocomplete support
- ⚡ **Performance optimized** with proxy caching

For more examples, see:
- `Demo.luau` - Interactive demonstration
- `UnitTests.luau` - Comprehensive test cases
- `PROXY_USERDATA_NOTES.md` - Technical details about proxy behavior
