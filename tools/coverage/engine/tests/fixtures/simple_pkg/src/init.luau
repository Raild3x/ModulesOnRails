-- Coverage fixture: exercises each collector feature once.
-- Golden files pin probe positions -- do not reformat this file.

local M = {}

type Foo = { n: number }

local x = 1 local y = 2

function M.add(a: number, b: number): number
	if a > 0 and b > 0 then
		return a + b
	else
		return a - b
	end
end

function M:_reset()
	local total = 0
	for i = 1, 3 do
		total += x + i
	end
	for i = 1, 10 do end
	return total
end

local function helper(n: number): number
	if n > 10 then
		return 10
	elseif n > 5 then
		return 5
	end
	return n
end

local cb = function(): number
	return helper(y)
end

function M.drain(list: { number }): number
	local i = #list
	while i > 0 do
		i -= 1
	end
	repeat
		i += 1
	until i >= 1
	return cb()
end

function M.each(items: { number }, f: (number) -> ())
	table.sort(items, function(a, b)
		return a < b
	end)
	for _, v in items do
		f(v)
	end
end

function M.gated(service): number
	if service:IsRunning() then
		return 1
	end
	return 0
end

function M.boom()
	error("boom")
	x = 99
end

if false then
	x = -1
end

if true then
	y = 2
else
	y = -2
end

return M
