--[=[
	Sample Module to be Tested
	
	This is a simple calculator module to demonstrate how to write testable code
	and how to test it using the tiniest framework.
]=]

local Calculator = {}

function Calculator.Add(a: number, b: number): number
	return a + b
end

function Calculator.Subtract(a: number, b: number): number
	return a - b
end

function Calculator.Multiply(a: number, b: number): number
	return a * b
end

function Calculator.Divide(a: number, b: number): number
	if b == 0 then
		error("Cannot divide by zero")
	end
	return a / b
end

function Calculator.Power(base: number, exponent: number): number
	return base ^ exponent
end

function Calculator.IsEven(n: number): boolean
	return n % 2 == 0
end

function Calculator.Max(numbers: { number }): number?
	if #numbers == 0 then
		return nil
	end

	local max = numbers[1]
	for _, num in numbers do
		if num > max then
			max = num
		end
	end
	return max
end

return Calculator
