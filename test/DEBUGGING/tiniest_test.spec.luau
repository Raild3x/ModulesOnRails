return function(tiniest: tiniest)
	local FOCUS = tiniest.FOCUS
	local expect = tiniest.expect
	local describe = tiniest.describe
	local test = tiniest.test

	describe("Describe 1", function()
		test("Passing Test 1.1", function()
			expect(true).is(true)
		end)

		test("Failing Test 1.2", function()
			expect(false).is(true)
		end)

		test("Erroring Test 1.3", function()
			error("This is an error")
		end)

		test("Passing Test 1.4", function()
			expect(1 + 1).is(2)
		end)
	end)

	describe("Describe 2", function()
		test("Passing Test 2.1", function()
			expect("hello").is("hello")
		end)

		test("Failing Test 2.2", function()
			expect(5).is(10)
		end)
	end)

	describe("Describe 3", function()
		test("Erroring Test 3.1", function()
			error("Another error")
		end)

		test("Passing Test 3.2", function()
			expect({ a = 1 }).is_a("table")
		end)

		test("timeout Test 3.3", function()
			local x = 1
			while true do
				x = x + 1
			end
		end)

		test("Passing Test 3.4", function()
			expect("world").is("world")
		end)

		test("Erroring test 3.5", function()
			error("Yet another error")
		end)
	end)

	describe("Describe 4", function()
		test("Passing Test 4.1", function()
			expect(20).is_greater_than(10)
		end)

		test("Failing Test 4.2", function()
			expect(5).is_greater_than(10)
		end)

		test("Passing Test 4.3", function()
			expect(1).is_not(2)
		end)
	end)
end
