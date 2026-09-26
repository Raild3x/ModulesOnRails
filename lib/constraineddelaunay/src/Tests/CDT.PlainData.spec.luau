-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local PlainData = require("../PlainData")
	local Fixtures = require("../Fixtures")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function rejects(value: unknown, reasonPattern: string)
		local ok, reason = PlainData.Check(value)
		expect(ok).never_is_true()
		expect((reason or ""):find(reasonPattern) ~= nil).is_true()
	end

	describe("PlainData.Check accepts", function()
		test("every fixture", function()
			for _, scenario in Fixtures.All do
				expect(PlainData.Check(scenario)).is_true()
			end
		end)

		test("native vector values (Roblox Vector3)", function()
			expect(PlainData.Check({ Positions = { vector.create(1, 2, 3), vector.create(-4, 0, 5) } })).is_true()
		end)

		test("flat arrays, string dictionaries, buffers, empty tables and infinities", function()
			expect(PlainData.Check({ Coords = { 0, 1.5, -2 }, Name = "x", Blob = buffer.create(8), Empty = {}, Far = math.huge })).is_true()
		end)
	end)

	describe("PlainData.Check rejects (negative controls)", function()
		test("a sparse array", function()
			local sparse = { 1, 2, 3 }
			sparse[2] = nil
			rejects(sparse, "sparse")
		end)

		test("a mixed table", function()
			rejects({ 1, 2, Name = "x" }, "mixes")
		end)

		test("a function", function()
			rejects({ Fn = function() end }, "function")
		end)

		test("a metatable", function()
			rejects(setmetatable({}, {}), "metatable")
		end)

		test("NaN", function()
			rejects({ 0 / 0 }, "NaN")
		end)

		test("a non-string dictionary key", function()
			rejects({ [true] = 1 }, "not a string")
		end)

		test("a cycle", function()
			local cyclic = {}
			cyclic.Self = cyclic
			rejects(cyclic, "cycle")
		end)
	end)
end
