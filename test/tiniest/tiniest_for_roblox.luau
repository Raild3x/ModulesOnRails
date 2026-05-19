-- From dphfox/tiniest, licensed under BSD
--!strict

--[=[
	@class TiniestForRoblox
	
	A lightweight testing framework for Roblox, adapted from dphfox/tiniest.
	
	Provides a simple, expressive API for writing and running tests with support for:
	- Nested test suites using `describe()`
	- Individual test cases using `test()`
	- Assertions using `expect()`
	- Automatic test discovery from hierarchy
	- Pretty formatted output with timing information
	
	## Example Usage
	
	### Basic Test File (MyModule.spec.luau)
	```lua
	return function(t)
		local MyModule = require(script.Parent.MyModule)
		
		t.describe("MyModule", function()
			t.describe("Add function", function()
				t.test("should add two numbers", function()
					local result = MyModule.Add(2, 3)
					t.expect(result).is(5)
				end)
				
				t.test("should handle negative numbers", function()
					local result = MyModule.Add(-5, 3)
					t.expect(result).is(-2)
				end)
			end)
			
			t.describe("Multiply function", function()
				t.test("should multiply two numbers", function()
					local result = MyModule.Multiply(4, 5)
					t.expect(result).is(20)
				end)
			end)
		end)
	end
	```
	
	### Running Tests
	```lua
	local tiniest = require(path.to.tiniest_for_roblox).configure {
		pretty = {
			disable_emoji = false,
			disable_unicode = false,
		}
	}
	
	-- Automatically discover and run all .spec files in a hierarchy
	local tests = tiniest.collect_tests_from_hierarchy(script.Parent)
	tiniest.run_tests(tests, {}) -- automatically prints results unless disabled in config
	```
]=]

local tiniest_expect = require("./tiniest_expect")
local tiniest_time = require("./tiniest_time")
local tiniest_pretty = require("./tiniest_pretty")
local tiniest_context = require("./tiniest_context")
local tiniest = require("./tiniest")

export type Options = {
	snapshot_path: string?,
	save_snapshots: boolean?,
	pretty: nil | {
		disable_emoji: boolean?,
		disable_unicode: boolean?,
		disable_output: nil | {
			after_run: boolean?,
		},
	},
}

export type CollectOptions = {
	file_name_pattern: string?,
}

local tiniest_for_roblox = {}

--[=[
	Configures and returns a new instance of the testing framework with the specified options.
	
	@param options Options -- Configuration table for the testing framework
	@return Configured -- A configured instance with test methods (describe, test, expect, etc.)
	
	## Options Table
	- `snapshot_path: string?` -- Path to save test snapshots (not yet implemented)
	- `save_snapshots: boolean?` -- Whether to save snapshots (not yet implemented)
	- `pretty: table?` -- Pretty printing options
		- `disable_emoji: boolean?` -- Don't use emoji in output (defaults to false)
		- `disable_unicode: boolean?` -- Don't use unicode characters in output (defaults to false)
		- `disable_output: table?` -- Control output behavior
			- `after_run: boolean?` -- Don't automatically print after running tests
	
	## Example
	```lua
	local tiniest = require(path.to.tiniest_for_roblox).configure {
		pretty = {
			disable_emoji = false,
			disable_unicode = false,
		}
	}
	
	-- Now you can use tiniest.describe, tiniest.test, tiniest.expect, etc.
	```
]=]
function tiniest_for_roblox.configure(options: Options)
	local self = {}

	self.expect = tiniest_expect.expect
	self.context = tiniest_context

	local tiniest_time = tiniest_time.configure {
		get_timestamp = os.clock,
	}

	local tiniest_pretty = tiniest_pretty.configure {
		disable_colour = true,
		disable_emoji = options.pretty and options.pretty.disable_emoji,
		disable_unicode = options.pretty and options.pretty.disable_unicode,
		disable_output = options.pretty and options.pretty.disable_output,
		plugins = { tiniest_time :: any },
	}
	self.format_run = tiniest_pretty.format_run

	local tiniest = tiniest.configure {
		plugins = { tiniest_time :: any, tiniest_context :: any, tiniest_pretty },
	}
	self.describe = tiniest.describe
	self.FOCUS = tiniest.FOCUS
	self.test = tiniest.test
	self.collect_tests = tiniest.collect_tests
	self.run_tests = tiniest.run_tests

	--[=[
		Automatically discovers and collects test files from an Instance hierarchy.
		
		Recursively traverses the given ancestor and its descendants, finding all ModuleScripts
		that match the file name pattern (defaults to files ending in ".spec"). Each matching
		module is required and expected to return a function that accepts the testing framework
		instance as a parameter.
		
		@param ancestor Instance -- The root Instance to search for test files
		@param declared_collect_options CollectOptions? -- Optional configuration for test collection
		@return {Test} -- Array of collected tests
		
		## CollectOptions
		- `file_name_pattern: string?` -- Lua pattern to match test files (defaults to "%.spec$")
		
		## Example
		```lua
		local tiniest = require(path.to.tiniest_for_roblox).configure {}
		
		-- Collect all .spec files from the Tests folder
		local tests = tiniest.collect_tests_from_hierarchy(game.ReplicatedStorage.Tests)
		
		-- Run the collected tests
		local results = tiniest.run_tests(tests, {})
		print(tiniest.format_run(results))
		```
		
		## Test File Structure
		Each test file should return a function that accepts the testing framework:
		```lua
		-- MyModule.spec.luau
		return function(t)
			t.describe("MyModule", function()
				t.test("should work", function()
					t.expect(1 + 1).is(2)
				end)
			end)
		end
		```
	]=]
	function self.collect_tests_from_hierarchy(ancestor: Instance, declared_collect_options: CollectOptions?)
		local collect_options: CollectOptions = declared_collect_options or {}
		local file_name_pattern = collect_options.file_name_pattern or "%.spec$"
		local function discover(ancestor: Instance): ()
			self.describe(ancestor.Name, function()
				if ancestor:IsA("ModuleScript") and ancestor.Name:match(file_name_pattern) then
					local requireOk, module = pcall(require, ancestor)
					if not requireOk then
						error(`Error while requiring {ancestor:GetFullName()}`, 0)
					elseif typeof(module) ~= "function" then
						error(`Did not get a function from {ancestor:GetFullName()}`, 0)
					end
					local collectOk, err = pcall(module, self)
					if not collectOk then
						error(err, 0)
					end
				end
				local children = ancestor:GetChildren()
				if #children > 0 then
					table.sort(children, function(a: Instance, b: Instance)
						return a.Name < b.Name
					end)
					for _, child in children do
						discover(child)
					end
				end
			end)
		end
		return self.collect_tests(function()
			discover(ancestor)
		end)
	end

	return self
end

export type Configured = typeof(tiniest_for_roblox.configure {})

return tiniest_for_roblox
