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
8. [Common Patterns](#common-patterns)
9. [Best Practices](#best-practices)

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
print(manager.Proxy.Player.Name) -- "Alice"

-- Modification (triggers listeners)
manager.Proxy.Player.Level = 5

-- Iteration (use generic for, NOT pairs!)
for key, value in manager.Proxy.Player do
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
    print("Changed path:", table.concat(metadata.OriginPath, "."))
    print("Direct change:", metadata.Diff ~= nil)
end)

manager.Proxy.Player.Health = 80
-- Output: "Health: 100 → 80"
--         "Changed path: Player.Health"
--         "Direct change: true"
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
    print("Origin:", table.concat(metadata.OriginPath, "."))
    if metadata.Diff then
        print("Direct replacement at this path")
    else
        print("Descendant changed under this path")
    end
end)

-- Change deep nested value
manager.Proxy.Game.World.Region.Zone = 2
-- Output: "Origin: Game.World.Region.Zone"
--         "Descendant changed under this path"
```

### Root Level Listener

```lua
-- Listen to ALL changes in the entire structure
manager:OnValueChange({}, function(newValue, oldValue, metadata)
    print("Something changed at:", table.concat(metadata.OriginPath, "."))
end)
```

### OnValueChange vs OnChange

`OnValueChange` and `OnChange` are for the two most common listening patterns:

- **`OnValueChange`** fires ONLY when this exact path is directly reassigned.
- **`OnChange`** fires when this path is directly reassigned OR any descendant
  of it changes.

```lua
local manager = TableManager.new({
    Player = { Health = 100, Mana = 50 }
})

manager:OnValueChange({"Player"}, function(newValue, oldValue, metadata)
    print("Player table was directly replaced")
end)

manager:OnChange({"Player"}, function(newValue, oldValue, metadata)
    print("Player table or one of its fields changed")
end)

manager.Proxy.Player.Health = 80
-- Output: "Player table or one of its fields changed"
-- (OnValueChange does NOT fire - only Health changed, not Player itself)

manager.Proxy.Player = { Health = 100, Mana = 50 }
-- Output: "Player table was directly replaced"
--         "Player table or one of its fields changed"
```

### Observe

`Observe` immediately invokes the callback with the current value (with
`oldValue` and `metadata` both `nil`), then behaves like `OnValueChange` for
subsequent changes. Useful for binding UI to data without separately calling
`Get` first.

```lua
local manager = TableManager.new({
    Player = { Health = 100 }
})

manager:Observe({"Player", "Health"}, function(newValue, oldValue, metadata)
    if metadata == nil then
        print("Initial value:", newValue)
    else
        print("Health changed:", oldValue, "→", newValue)
    end
end)
-- Output immediately: "Initial value: 100"

manager.Proxy.Player.Health = 80
-- Output: "Health changed: 100 → 80"
```

### Wildcard Listeners

A `"*"` path segment matches any literal key at that position, which is
useful for dynamic collections (e.g. per-player data) without needing to
register a listener for each existing key or re-register on `KeyAdded`.
The matched keys are available via `metadata.WildcardMatches`, in
left-to-right order.

```lua
local manager = TableManager.new({
    Players = {
        p123 = { Health = 100 },
        p456 = { Health = 80 },
    }
})

manager:OnValueChange({"Players", "*", "Health"}, function(newValue, oldValue, metadata)
    local playerId = metadata.WildcardMatches[1]
    print(playerId, "health:", oldValue, "→", newValue)
end)

manager.Proxy.Players.p123.Health = 90  -- "p123 health: 100 → 90"
manager.Proxy.Players.p456.Health = 70  -- "p456 health: 80 → 70"

-- A new player added later is also covered by a wildcard ancestor listener:
manager:OnChange({"Players", "*"}, function(_, _, metadata)
    if metadata.WildcardMatches then
        print("Player data changed for:", metadata.WildcardMatches[1])
    end
end)

manager.Proxy.Players.p789 = { Health = 100 }
-- Output: "Player data changed for: p789"
```

> Note: a listener registered with `Once = true` on a wildcard path fires once
> **total** across all matching keys, not once per key, since it lives on a
> single tree node.

---

## Array Operations

### Array Insertion

```lua
local manager = TableManager.new({
    Inventory = { "Sword", "Shield" }
})

-- Listen for insertions
manager:OnArrayInsert({"Inventory"}, function(index, newValue, metadata)
    print("Inserted", newValue, "at index", index)
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
local removed = manager:Remove({"Queue"}, #manager.Proxy.Queue)
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
manager.Proxy.Items[1] = "Steel Sword"
-- Output: "Item 1 upgraded: Bronze Sword → Steel Sword"
```

---

## Key Tracking

### Key Addition

```lua
local manager = TableManager.new({
    Settings = { Volume = 50 }
})

manager:OnKeyAdd({"Settings"}, function(newValue, metadata)
    local key = if metadata.Diff then metadata.Diff.key else "<ancestor>"
    print("New setting:", key, "=", newValue)
end)

-- Add new key
manager.Proxy.Settings.Brightness = 80
-- Output: "New setting: Brightness = 80"

-- Modifying existing key does NOT trigger OnKeyAdd
manager.Proxy.Settings.Volume = 75 -- No output (triggers OnKeyChange instead)
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

manager:OnKeyRemove({"Player"}, function(oldValue, metadata)
    local key = if metadata.Diff then metadata.Diff.key else "<ancestor>"
    print("Removed:", key, "(was", oldValue .. ")")
end)

-- Remove keys by setting to nil
manager.Proxy.Player.TempBoost = nil
-- Output: "Removed: TempBoost (was 10)"

manager.Proxy.Player.TempBuff = nil
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
manager.Proxy.Config.Timeout = 60
-- Output: "Timeout modified: 30 → 60"

-- Add new key (does NOT trigger OnKeyChange, triggers OnKeyAdd)
manager.Proxy.Config.MaxConnections = 100 -- No output here

-- Remove key (does NOT trigger OnKeyChange, triggers OnKeyRemove)
manager.Proxy.Config.Retries = nil -- No output here
```

---

## Parent/Child Relationships

### Understanding Diff and OriginPath

```lua
local manager = TableManager.new({
    Game = {
        World = {
            Region = { Zone = 1 }
        }
    }
})

manager:OnValueChange({"Game", "World"}, function(newValue, oldValue, metadata)
    local path = table.concat(metadata.OriginPath, ".")

    if metadata.Diff then
        print("Direct change at:", path)
    else
        print("Descendant change originated at:", path)
    end
end)

-- Scenario 1: Descendant change under Game.World
manager.Proxy.Game.World.Region.Zone = 2
-- Output: "Descendant change originated at: Game.World.Region.Zone"

-- Scenario 2: Direct replacement at Game.World
manager.Proxy.Game.World = { Region = { Zone = 3 } }
-- Output: "Direct change at: Game.World"

-- Note: listeners registered at {"Game", "World"} only fire for that path and
-- descendant-origin changes, not unrelated parent-only replacements.
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
    print("[ROOT]", table.concat(metadata.OriginPath, "."))
end)

-- Listener 2: App level
manager:OnValueChange({"App"}, function(newValue, oldValue, metadata)
    print("[APP]", table.concat(metadata.OriginPath, "."))
end)

-- Listener 3: UI level
manager:OnValueChange({"App", "UI"}, function(newValue, oldValue, metadata)
    print("[UI]", table.concat(metadata.OriginPath, "."))
end)

-- One change triggers all three listeners!
manager.Proxy.App.UI.Menu.Visible = false
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

manager.Proxy.Player.Name = "Bob"
manager.Proxy.Settings.Volume = 100
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

manager.Proxy.Player.Level = 1
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

-- Get root (returns managed raw table)
local root = manager:Get({}) -- Same as manager.Raw
```

### Using Set Method

```lua
-- Set values by path
manager:Set({"Player", "Name"}, "Bob")
manager:Set({"Player", "Stats", "Health"}, 80)

-- Equivalent to:
-- manager.Proxy.Player.Name = "Bob"
-- manager.Proxy.Player.Stats.Health = 80

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
manager.Proxy.Player.Stats.Health = 75
manager.Proxy.Player.Stats.Mana = 40
```

---

> Note: Fusion helper APIs are not part of this package's current public API.
> Keep integration logic in application code using signals/listeners from this module.

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
        manager.Proxy.Player.Level = oldValue
    end
end)

manager.Proxy.Player.Level = 150 -- Automatically reverted to previous value
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
for key, value in manager.Proxy.config do
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
for k, v in pairs(manager.Proxy) do end -- ❌ Won't work!

-- Don't use table.* functions on proxies
table.insert(manager.Proxy.items, "value") -- ❌ Won't work!
table.remove(manager.Proxy.items) -- ❌ Won't work!

-- Don't compare proxy == original directly
if manager.Proxy == originalTable then end -- ❌ Won't work!
-- Use: manager._proxyManager:Equals(manager.Proxy, originalTable)

-- Don't set root directly
manager:Set({}, newTable) -- ❌ Errors!
```

---

## Summary

TableManager provides a powerful, type-safe way to observe and manage nested table data in Roblox. Key takeaways:

- 🎯 **Automatic change detection** at any depth
- 🔄 **Parent/child relationships** for cascading updates
- 📡 **Global signals** for cross-cutting concerns
- ✅ **Type-safe** with full autocomplete support
- ⚡ **Performance optimized** with proxy caching

For more examples, see:
- `Tests/TableManagerDemo.server.luau` - Interactive demonstration
- `Tests/TableManager.spec.luau` - Comprehensive test cases
- `PROXY_USERDATA_NOTES.md` - Technical details about proxy behavior
