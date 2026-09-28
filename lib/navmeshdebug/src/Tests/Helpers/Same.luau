--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Deep equality for plain data: NaN equals NaN, and -0 differs from 0 (both must round-trip).

local function same(a: any, b: any): boolean
	if type(a) == "table" and type(b) == "table" then
		for key, value in a do
			if not same(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	elseif type(a) == "number" and type(b) == "number" then
		if a ~= a then
			return b ~= b
		end
		return a == b and (a ~= 0 or 1 / a == 1 / b)
	end
	return a == b
end

return same
