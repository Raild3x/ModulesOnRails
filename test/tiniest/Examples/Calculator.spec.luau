--[=[
	Calculator Module Tests
	
	This file demonstrates comprehensive testing of a module using the tiniest framework.
	It shows examples of:
	- Testing normal cases
	- Testing edge cases
	- Testing error conditions
	- Using different assertion methods
	- Organizing tests with nested describe blocks
]=]

return function(t)
	local Calculator = require(script.Parent.Calculator)
	local expect = t.expect
	local describe = t.describe
	local test = t.test

	describe("Calculator", function()
		describe("Add", function()
			test("should add positive numbers", function()
				expect(Calculator.Add(2, 3)).is(5)
				expect(Calculator.Add(10, 20)).is(30)
			end)

			test("should add negative numbers", function()
				expect(Calculator.Add(-5, -3)).is(-8)
				expect(Calculator.Add(-10, 5)).is(-5)
			end)

			test("should handle zero", function()
				expect(Calculator.Add(0, 0)).is(0)
				expect(Calculator.Add(5, 0)).is(5)
				expect(Calculator.Add(0, 5)).is(5)
			end)
		end)

		describe("Subtract", function()
			test("should subtract numbers", function()
				expect(Calculator.Subtract(10, 5)).is(5)
				expect(Calculator.Subtract(100, 50)).is(50)
			end)

			test("should handle negative results", function()
				expect(Calculator.Subtract(5, 10)).is(-5)
			end)
		end)

		describe("Multiply", function()
			test("should multiply numbers", function()
				expect(Calculator.Multiply(3, 4)).is(12)
				expect(Calculator.Multiply(7, 8)).is(56)
			end)

			test("should handle multiplication by zero", function()
				expect(Calculator.Multiply(5, 0)).is(0)
				expect(Calculator.Multiply(0, 5)).is(0)
			end)

			test("should handle negative multiplication", function()
				expect(Calculator.Multiply(-5, 3)).is(-15)
				expect(Calculator.Multiply(-5, -3)).is(15)
			end)
		end)

		describe("Divide", function()
			test("should divide numbers", function()
				expect(Calculator.Divide(10, 2)).is(5)
				expect(Calculator.Divide(100, 4)).is(25)
			end)

			test("should handle decimal results", function()
				local result = Calculator.Divide(10, 3)
				-- Check that result is close to expected (floating point comparison)
				expect(result).is_a("number")
				expect(result > 3.33).is_true()
				expect(result < 3.34).is_true()
			end)

			test("should fail when dividing by zero", function()
				expect(function()
					Calculator.Divide(10, 0)
				end).fails_with("divide by zero")
			end)
		end)

		describe("Power", function()
			test("should calculate powers", function()
				expect(Calculator.Power(2, 3)).is(8)
				expect(Calculator.Power(5, 2)).is(25)
			end)

			test("should handle power of zero", function()
				expect(Calculator.Power(5, 0)).is(1)
			end)

			test("should handle power of one", function()
				expect(Calculator.Power(5, 1)).is(5)
			end)
		end)

		describe("IsEven", function()
			test("should return true for even numbers", function()
				expect(Calculator.IsEven(2)).is_true()
				expect(Calculator.IsEven(4)).is_true()
				expect(Calculator.IsEven(100)).is_true()
			end)

			test("should return false for odd numbers", function()
				expect(Calculator.IsEven(1)).never_is_true()
				expect(Calculator.IsEven(3)).never_is_true()
				expect(Calculator.IsEven(99)).never_is_true()
			end)

			test("should handle zero", function()
				expect(Calculator.IsEven(0)).is_true()
			end)

			test("should handle negative numbers", function()
				expect(Calculator.IsEven(-2)).is_true()
				expect(Calculator.IsEven(-3)).never_is_true()
			end)
		end)

		describe("Max", function()
			test("should find maximum in array", function()
				expect(Calculator.Max { 1, 5, 3, 2 }).is(5)
				expect(Calculator.Max { 10, 20, 15 }).is(20)
			end)

			test("should handle single element", function()
				expect(Calculator.Max { 42 }).is(42)
			end)

			test("should handle negative numbers", function()
				expect(Calculator.Max { -5, -2, -10 }).is(-2)
			end)

			test("should return nil for empty array", function()
				expect(Calculator.Max {}).never_exists()
			end)

			test("should handle array with duplicates", function()
				expect(Calculator.Max { 5, 5, 5 }).is(5)
			end)
		end)

		-- Example of integration testing multiple functions together
		describe("Complex Operations", function()
			test("should chain operations correctly", function()
				-- (10 + 5) * 2 = 30
				local step1 = Calculator.Add(10, 5)
				local step2 = Calculator.Multiply(step1, 2)
				expect(step2).is(30)
			end)

			test("should handle order of operations", function()
				-- Calculate: (20 / 4) ^ 2 - 10
				local division = Calculator.Divide(20, 4)
				local power = Calculator.Power(division, 2)
				local result = Calculator.Subtract(power, 10)
				expect(result).is(15)
			end)
		end)
	end)
end
