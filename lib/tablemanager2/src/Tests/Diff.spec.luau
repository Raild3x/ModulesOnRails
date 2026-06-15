--!strict
--[[
	Unit tests for Diff module snapshot-based diffing.
]]

return function(t: tiniest)
	local Diff = require("../Diff")

	local test = t.test
	local expect = t.expect

	test("diffFromSnapshot still works with valid snapshots", function()
		local before = Diff.snapshot { x = 1, nested = { y = 2 } }
		local root = Diff.diffFromSnapshot(before, { x = 5, nested = { y = 2 } })
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
