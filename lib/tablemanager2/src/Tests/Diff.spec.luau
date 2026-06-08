--!strict
--[[
	Unit tests for Diff module snapshot boundaries and malformed snapshot handling.
]]

return function(t: tiniest)
	local Diff = require("../Diff")

	local test = t.test
	local expect = t.expect

	test("diffFromSnapshot rejects non-table snapshot roots", function()
		local ok, err = pcall(function()
			Diff.diffFromSnapshot(123 :: any, { x = 1 }, true)
		end)

		expect(ok).is(false)
		expect(type(err)).is("string")
		expect((err :: string):find("Invalid snapshot object for Diff.diffFromSnapshot", 1, true) ~= nil).is_true()
	end)

	test("diffFromSnapshot rejects table snapshot nodes missing children", function()
		local malformedSnapshot = {
			value = { x = 1 },
			ref = { x = 1 },
			children = nil,
		}

		local ok, err = pcall(function()
			Diff.diffFromSnapshot(malformedSnapshot :: any, { x = 1 }, true)
		end)

		expect(ok).is(false)
		expect(type(err)).is("string")
		expect((err :: string):find("table values require children", 1, true) ~= nil).is_true()
	end)

	test("diffFromSnapshot rejects scalar snapshot nodes with children", function()
		local malformedSnapshot = {
			value = 1,
			ref = nil,
			children = {
				x = {
					value = 2,
					ref = nil,
					children = nil,
				},
			},
		}

		local ok, err = pcall(function()
			Diff.diffFromSnapshot(malformedSnapshot :: any, 1, true)
		end)

		expect(ok).is(false)
		expect(type(err)).is("string")
		expect((err :: string):find("scalar values cannot have children", 1, true) ~= nil).is_true()
	end)

	test("diffFromSnapshot still works with valid snapshots", function()
		local before = Diff.snapshot { x = 1, nested = { y = 2 } }
		local root = Diff.diffFromSnapshot(before, { x = 5, nested = { y = 2 } }, true)
		local flat = Diff.flatten(root, {})

		expect(#flat >= 1).is_true()
		local foundXChange = false
		for _, entry in flat do
			if #entry.path == 1 and entry.path[1] == "x" and entry.type == "changed" and entry.new == 5 then
				foundXChange = true
			end
		end
		expect(foundXChange).is_true()
	end)
end
