# Tiniest Testing Framework for Roblox

A lightweight, expressive testing framework for Roblox, adapted from [dphfox/tiniest](https://github.com/dphfox/tiniest).

## Features

- 🎯 Simple, expressive API for writing tests
- 📦 Automatic test discovery from Instance hierarchy
- 🎨 Pretty formatted output with timing information
- 🔗 Chainable assertions
- 📊 Detailed error reporting with stack traces
- ⚡ Fast execution with minimal overhead

## Quick Start

### 1. Create a Test File

Test files should end with `.spec.luau` and return a function that accepts the testing framework:

```lua
-- MyModule.spec.luau
return function(t)
	local MyModule = require(script.Parent.MyModule)
	
	t.describe("MyModule", function()
		t.test("should add two numbers", function()
			local result = MyModule.Add(2, 3)
			t.expect(result).is(5)
		end)
	end)
end
```

### 2. Run Your Tests

```lua
-- testRunner.server.luau
local tiniest = require(path.to.tiniest_for_roblox).configure {}

-- Automatically discover and run all .spec files
local tests = tiniest.collect_tests_from_hierarchy(script.Parent)
local results = tiniest.run_tests(tests, {})

-- Print formatted results
print(tiniest.format_run(results))
```

## API Reference

### Configuration

```lua
local tiniest = require(path.to.tiniest_for_roblox).configure {
	pretty = {
		disable_emoji = false,       -- Disable emoji in output
		disable_unicode = false,     -- Use ASCII-only characters
		disable_output = {
			after_run = false,       -- Suppress automatic output
		}
	}
}
```

### Test Structure

#### `describe(label, inner)`

Groups related tests together. Can be nested to create hierarchical organization.

```lua
t.describe("Player System", function()
	t.describe("Health", function()
		t.test("should start at 100", function()
			t.expect(player.Health).is(100)
		end)
	end)
end)
```

#### `test(label, run)`

Defines an individual test case. Must be called within a `describe` block.

```lua
t.test("should add two numbers", function()
	local result = add(2, 3)
	t.expect(result).is(5)
end)
```

### Assertions

All assertions are accessed via `t.expect(value)` and return the expectation object for chaining.

#### Existence

```lua
t.expect(value).exists()          -- Asserts value is not nil
t.expect(value).never_exists()    -- Asserts value is nil
```

#### Equality

```lua
t.expect(value).is(expected)      -- Asserts value == expected
t.expect(value).never_is(other)   -- Asserts value ~= other
```

#### Boolean

```lua
t.expect(value).is_true()         -- Asserts value is true
t.expect(value).never_is_true()   -- Asserts value is false
```

#### Type Checking

```lua
t.expect(value).is_a("number")    -- Asserts typeof(value) == "number"
t.expect(value).never_is_a("nil") -- Asserts typeof(value) ~= "nil"
```

#### Table/Userdata

```lua
t.expect(table).has_key("Health")       -- Asserts table has key
t.expect(table).never_has_key("Invalid") -- Asserts table doesn't have key
t.expect(array).has_value(100)          -- Asserts array contains value
t.expect(array).never_has_value(0)      -- Asserts array doesn't contain value
```

#### Functions

```lua
t.expect(function() error("fail") end).fails()
-- Asserts function throws an error

t.expect(function() return true end).never_fails()
-- Asserts function doesn't throw an error

t.expect(function() error("specific error") end).fails_with("specific")
-- Asserts function fails with error containing message (case-insensitive)

t.expect(function() return true end).never_fails_with("error")
-- Asserts function doesn't fail with message
```

### Test Discovery

#### `collect_tests_from_hierarchy(ancestor, options?)`

Automatically discovers and collects test files from an Instance hierarchy.

```lua
-- Collect all .spec files from a folder
local tests = tiniest.collect_tests_from_hierarchy(game.ServerScriptService.Tests)

-- Customize the file pattern
local tests = tiniest.collect_tests_from_hierarchy(
	game.ServerScriptService.Tests,
	{ file_name_pattern = "%.test$" }  -- Look for .test files instead
)
```

### Running Tests

#### `run_tests(tests, options)`

Executes the given array of tests and returns results.

```lua
local results = tiniest.run_tests(tests, {})

print(`Passed: {results.status_tally.pass}`)
print(`Failed: {results.status_tally.fail}`)
```

#### `format_run(results)`

Formats test results as a pretty-printed string.

```lua
local results = tiniest.run_tests(tests, {})
print(tiniest.format_run(results))
```

## Examples

### Basic Test

```lua
return function(t)
	t.describe("Calculator", function()
		t.test("adds numbers", function()
			t.expect(2 + 2).is(4)
		end)
		
		t.test("multiplies numbers", function()
			t.expect(3 * 4).is(12)
		end)
	end)
end
```

### Testing a Module

```lua
return function(t)
	local Inventory = require(script.Parent.Inventory)
	
	t.describe("Inventory", function()
		t.describe("AddItem", function()
			t.test("should add item to inventory", function()
				local inv = Inventory.New()
				inv:AddItem("Sword", 1)
				
				t.expect(inv.Items).has_key("Sword")
				t.expect(inv.Items.Sword).is(1)
			end)
			
			t.test("should stack items", function()
				local inv = Inventory.New()
				inv:AddItem("Potion", 3)
				inv:AddItem("Potion", 2)
				
				t.expect(inv.Items.Potion).is(5)
			end)
		end)
		
		t.describe("RemoveItem", function()
			t.test("should remove item from inventory", function()
				local inv = Inventory.New()
				inv:AddItem("Shield", 1)
				inv:RemoveItem("Shield", 1)
				
				t.expect(inv.Items).never_has_key("Shield")
			end)
			
			t.test("should fail when removing non-existent item", function()
				local inv = Inventory.New()
				
				t.expect(function()
					inv:RemoveItem("Dragon", 1)
				end).fails_with("not found")
			end)
		end)
	end)
end
```

### Chaining Assertions

```lua
return function(t)
	t.describe("Player", function()
		t.test("has valid initial state", function()
			local player = {
				Name = "Player1",
				Health = 100,
				Level = 1
			}
			
			-- Chain multiple assertions
			t.expect(player).exists()
				.is_a("table")
				.has_key("Name")
				.has_key("Health")
				.has_key("Level")
		end)
	end)
end
```

## Tips

1. **Organize with describe blocks**: Use nested `describe` blocks to create a clear hierarchy
2. **One assertion per test**: Keep tests focused by testing one thing at a time
3. **Descriptive labels**: Use clear, descriptive labels that explain what's being tested
4. **Test edge cases**: Don't forget to test error conditions and edge cases
5. **Use chaining sparingly**: While chaining is powerful, too many chained assertions can make failures harder to debug

## License

BSD (from dphfox/tiniest)
