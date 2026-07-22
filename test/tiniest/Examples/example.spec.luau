--[=[
	Example Test File
	
	This file demonstrates how to write tests using the tiniest testing framework.
	Test files should end with .spec.luau and return a function that accepts the testing framework.
]=]

return function(t)
	local expect = t.expect
	local describe = t.describe
	local test = t.test

	-- Use describe to group related tests together
	describe("Basic Assertions", function()
		-- Use test to define individual test cases
		test("should compare numbers with .is()", function()
			local result = 2 + 2
			expect(result).is(4)
		end)

		test("should check existence with .exists()", function()
			local value = "something"
			expect(value).exists()
			expect(nil).never_exists()
		end)

		test("should check types with .is_a()", function()
			expect(123).is_a("number")
			expect("hello").is_a("string")
			expect(true).is_a("boolean")
		end)

		test("should check booleans with .is_true()", function()
			local isValid = true
			expect(isValid).is_true()

			local isInvalid = false
			expect(isInvalid).never_is_true()
		end)
	end)

	describe("Table Assertions", function()
		test("should check for keys with .has_key()", function()
			local player = {
				Name = "Player1",
				Health = 100,
			}
			expect(player).has_key("Name")
			expect(player).has_key("Health")
			expect(player).never_has_key("InvalidKey")
		end)

		test("should check for values with .has_value()", function()
			local inventory = { "Sword", "Shield", "Potion" }
			expect(inventory).has_value("Sword")
			expect(inventory).has_value("Shield")
			expect(inventory).never_has_value("Dragon")
		end)
	end)

	describe("Function Assertions", function()
		test("should check if functions fail with .fails()", function()
			local function throwError()
				error("This function always fails")
			end

			expect(throwError).fails()
		end)

		test("should check functions succeed with .never_fails()", function()
			local function succeed()
				return true
			end

			expect(succeed).never_fails()
		end)

		test("should check error messages with .fails_with()", function()
			local function divideByZero()
				error("Cannot divide by zero")
			end

			expect(divideByZero).fails_with("divide by zero")
		end)
	end)

	describe("Nested Describe Blocks", function()
		-- You can nest describe blocks to create hierarchical test organization
		describe("Math Operations", function()
			describe("Addition", function()
				test("should add positive numbers", function()
					expect(5 + 3).is(8)
				end)

				test("should add negative numbers", function()
					expect(-5 + -3).is(-8)
				end)
			end)

			describe("Multiplication", function()
				test("should multiply positive numbers", function()
					expect(5 * 3).is(15)
				end)

				test("should multiply by zero", function()
					expect(5 * 0).is(0)
				end)
			end)
		end)
	end)

	describe("Chaining Assertions", function()
		test("can chain multiple assertions together", function()
			local value = "test"
			-- All assertions return the expectation object, allowing chaining
			expect(value).exists().is_a("string").is("test")
		end)

		test("can chain table assertions", function()
			local config = {
				Enabled = true,
				MaxPlayers = 10,
			}
			expect(config).has_key("Enabled").has_key("MaxPlayers")
		end)
	end)
end
