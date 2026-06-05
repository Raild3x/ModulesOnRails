# Proxy Userdata Implementation Notes

## Overview
Proxies in TableManager are implemented as **userdatas** (via weak table tracking) rather than regular tables. This design provides several advantages but requires understanding of metamethod behavior.

## What Works ✅

### 1. Length Operator
```lua
local tm = TableManager.new { items = {1, 2, 3} }
print(#tm.Proxy.items) -- Works! Returns 3
```
The `__len` metamethod returns `#meta.Original`, so the length operator works transparently.

### 2. Generic Iteration
```lua
local tm = TableManager.new { a = 1, b = 2, c = 3 }
-- ❌ This does NOT work - pairs()and ipairs don't work on userdatas
for key, value in pairs(tm.Proxy) do
    print(key, value) -- Won't work!
end

-- ✅ Use generic for iteration instead
for key, value in tm.Proxy do
    print(key, value) -- Works! Uses __iter metamethod
end
```
The `__iter` metamethod enables generic for iteration on userdatas.
Generic for iteration works for both arrays and dictionaries.

### 3. Indexing and Assignment
```lua
local tm = TableManager.new { data = {} }
tm.Proxy.data.key = "value"  -- Works! Triggers __newindex
local val = tm.Proxy.data.key -- Works! Triggers __index
```
Standard table operations work via `__index` and `__newindex` metamethods.

### 4. Equality Comparison (proxy-to-proxy)
```lua
local shared = { x = 1 }
local tm1 = TableManager.new { shared = shared }
local tm2 = TableManager.new { shared = shared }
if tm1.Proxy.shared == tm2.Proxy.shared then
    -- Works! Proxies wrapping same original are equal
end
```
The `__eq` metamethod compares the underlying original tables.

### 5. String Conversion
```lua
local tm = TableManager.new { nested = { deep = 1 } }
print(tostring(tm.Proxy.nested.deep)) 
-- Prints: "TableManager.Data(nested.deep)"
```
The `__tostring` metamethod provides readable proxy identification.

## What Doesn't Work ❌

### 1. Direct table.* Functions on Proxies
```lua
-- ❌ DON'T DO THIS
local tm = TableManager.new { items = {} }
table.insert(tm.Proxy.items, "value") -- Won't work! items is a proxy, not a table
```

**Solution:** Use TableManager's methods instead:
```lua
-- ✅ DO THIS
tm:Insert({"items"}, "value")
```

### 2. Comparing Proxy to Original (using ==)
```lua
-- ❌ This doesn't work due to Lua/Luau limitation
local original = { a = 1 }
local tm = TableManager.new(original)
if tm.Proxy == original then -- Won't work! Different metatables
    -- __eq only works when both operands have same metatable
end
```

**Solution:** Use the ProxyManager's `Equals` method:
```lua
-- ✅ DO THIS
if tm._proxyManager:Equals(tm.Proxy, original) then
    -- This works!
end
```

### 3. rawget/rawset on Proxies
```lua
-- ❌ These bypass metamethods and won't work correctly
rawget(tm.Proxy, "key")
rawset(tm.Proxy, "key", "value")
```
Since proxies are tracked via weak tables, raw operations may not behave as expected.

### 4. Using Proxies as Table Keys
```lua
-- ❌ Proxies and originals are NOT interchangeable as table keys
local original = { id = 1 }
local tm = TableManager.new(original)
local lookup = {}

lookup[original] = "value1"
lookup[tm.Proxy] -- Returns nil! Proxy is a different key than original

lookup[tm.Proxy] = "value2"
lookup[original] -- Still "value1"! They are separate keys
```

**Why?** In Lua, table key lookup uses **raw identity**, not metamethod equality. Even though proxies have a `__eq` metamethod, Lua's table implementation doesn't use it for key comparison. A userdata proxy and its original table are **different objects with different identities**, so they cannot be used interchangeably as keys.

**Solution:** Be consistent - always use either the proxy OR the original as keys, never mix them:
```lua
-- ✅ Consistent usage - use proxy everywhere
lookup[tm.Proxy] = "value"
print(lookup[tm.Proxy]) -- Works!

-- ✅ Consistent usage - use original everywhere  
lookup[original] = "value"
print(lookup[original]) -- Works!

-- ❌ Mixed usage - doesn't work
lookup[original] = "value"
print(lookup[tm.Proxy]) -- Returns nil!
```

## Best Practices

### 1. Always Use TableManager Methods for Array Modifications
```lua
-- ✅ Correct
tm:Insert({"inventory"}, item)
tm:Remove({"inventory"}, index)

-- ❌ Incorrect
table.insert(tm.Proxy.inventory, item) -- Won't work
table.remove(tm.Proxy.inventory) -- Won't work
```

### 2. Use # Operator Freely for Length
```lua
-- ✅ This is fine!
local count = #tm.Proxy.items
if #tm.Proxy.inventory > 10 then
    -- This works correctly
end
```

### 3. Iterate with Generic For as Normal
```lua
-- ✅ Generic for iteration works correctly
for key, value in tm.Proxy.config do 
    print(key, value)
end

for i, item in tm.Proxy.items do 
    print(i, item)
end

-- ❌ Don't use pairs() or ipairs()
-- for k, v in pairs(tm.Proxy.config) do end -- Won't work!
-- for i, v in ipairs(tm.Proxy.items) do end -- Won't work!
```

### 4. For Equality Checks with Originals, Use ProxyManager
```lua
-- ✅ Correct way to compare proxy with original
if tm._proxyManager:Equals(tm.Proxy.something, originalTable) then
    -- This works
end

-- Or unwrap first
if tm._proxyManager:GetOriginal(tm.Proxy.something) == originalTable then
    -- This also works
end
```

## Summary

The userdata proxy implementation provides transparent table-like behavior through metamethods:
- ✅ `#proxy` works via `__len`
- ✅ `for k, v in proxy do` works via `__iter` (generic for iteration)
- ✅ `proxy.key` and `proxy.key = value` work via `__index` and `__newindex`
- ✅ `proxy1 == proxy2` works via `__eq`
- ❌ `pairs(proxy)` doesn't work (use generic for: `for k, v in proxy do`)
- ❌ `ipairs(proxy)` doesn't work (use generic for: `for i, v in proxy do`)
- ❌ `table.*` functions don't work (use TableManager methods)
- ❌ `proxy == original` doesn't work (use ProxyManager:Equals)

When in doubt, use the TableManager's built-in methods for modifications, and the ProxyManager's helper methods for comparisons.
