--[=[
	Test Runner Script
	
	This script automatically discovers and runs all test files (*.spec.luau) in the project.
	
	## How It Works
	1. Configures the testing framework with default options
	2. Discovers all .spec files in the specified hierarchy
	3. Runs all collected tests
	4. Prints formatted results to the output
	
	## Creating Test Files
	Test files should end with .spec.luau and return a function that accepts the testing framework:
	
	```lua
	-- MyModule.spec.luau
	return function(t)
		local MyModule = require(script.Parent.MyModule)
		
		t.describe("MyModule", function()
			t.describe("Add", function()
				t.test("should add positive numbers", function()
					t.expect(MyModule.Add(2, 3)).is(5)
				end)
				
				t.test("should add negative numbers", function()
					t.expect(MyModule.Add(-2, -3)).is(-5)
				end)
			end)
			
			t.describe("Divide", function()
				t.test("should divide numbers", function()
					t.expect(MyModule.Divide(10, 2)).is(5)
				end)
				
				t.test("should fail when dividing by zero", function()
					t.expect(function()
						MyModule.Divide(10, 0)
					end).fails_with("cannot divide by zero")
				end)
			end)
		end)
	end
	```
	
	## Configuration Options
	You can customize the test runner by modifying the configuration:
	
	```lua
	local tiniest = require("./tiniest_for_roblox").configure {
		pretty = {
			disable_emoji = false,      -- Set to true to disable emoji in output
			disable_unicode = false,     -- Set to true to use ASCII-only characters
			disable_output = {
				after_run = false,       -- Set to true to suppress automatic output
			}
		}
	}
	```
]=]

local tiniest = require("./tiniest/tiniest_for_roblox").configure {
	pretty = {
		format = "tree", -- "tree" or "flat"
		trim_duplicate_trace = true, -- omit shared stack frames from multiple failing tests
	},
}
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PACKAGE_TO_TEST = "tablemanager2" -- Change this to the name of the package you want to test
local tests = tiniest.collect_tests_from_hierarchy(ReplicatedStorage.src:FindFirstChild(PACKAGE_TO_TEST), {
	ignore = function(obj: Instance)
		if obj.Name == "_Index" then
			return true, true -- ignore this instance and its descendants
		end
		return false, false -- do not ignore
	end,
})

task.wait(1) -- wait a moment to make it easier to identify the run in the microprofiler
tiniest.run_tests(tests, {})
