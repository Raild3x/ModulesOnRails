-- Authors: Logan Hunt (Raildex)
-- September 27, 2026

return function(t: tiniest)
	local ConstrainedDelaunay = require("../../ConstrainedDelaunay")
	local LuauLiteral = require("../LuauLiteral")
	local NavMesh = require("../../NavMesh")
	local same = require("./Helpers/Same")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- The real compiler, where this context allows it (a server Script needs LoadStringEnabled).
	local compile: ((string) -> any)? = nil
	local okLoad, probe = pcall(function()
		return (loadstring :: any)("return 1")
	end)
	if okLoad and type(probe) == "function" then
		compile = loadstring :: any
	end

	-- The top-level entries that differ, so a failure names them ("" when equal).
	local function diff(value: any, other: any): string
		local out = ""
		for k, v in value do
			if not same(v, other[k]) then
				out ..= `{k}: {LuauLiteral.Print(v)} became {LuauLiteral.Print(other[k])}; `
			end
		end
		return out
	end

	local function roundTrip(value: any)
		local text = LuauLiteral.Print(value)
		expect(diff(value, LuauLiteral.Parse(text))).is("")
		if compile then
			expect(diff(value, (compile :: any)("return " .. text)())).is("")
		end
		expect(LuauLiteral.Print(LuauLiteral.Parse(text))).is(text)
	end

	describe("LuauLiteral", function()
		test("round-trips every NavMesh fixture", function()
			expect(#NavMesh.Fixtures.All > 0).is_true()
			for _, scenario in NavMesh.Fixtures.All do
				roundTrip(scenario)
			end
		end)

		test("round-trips every CDT fixture and its TriangulateInput", function()
			expect(#ConstrainedDelaunay.Fixtures.All > 0).is_true()
			for _, scenario in ConstrainedDelaunay.Fixtures.All do
				roundTrip(scenario)
				roundTrip(ConstrainedDelaunay.Fixtures.ToInput(scenario))
			end
		end)

		test("numbers parse back exactly", function()
			local numbers = {
				0.1,
				1 / 3,
				-12.5,
				1e-7,
				2 ^ 53,
				2 ^ 60,
				5e-324,
				1.7976931348623157e308,
				-0,
				math.huge,
				-math.huge,
				0 / 0,
			}
			roundTrip(numbers)
			expect(LuauLiteral.Print(-0)).is("-0")
			expect(LuauLiteral.Print(0 / 0)).is("0/0")
			expect(LuauLiteral.Print(1 / 3)).is("0.3333333333333333")
		end)

		test("strings that need escapes", function()
			roundTrip { 'a"b', "back\\slash", "new\nline", "tab\t", "\0nul", "\1277", "bell\a", "caf\u{e9}" }
			expect(LuauLiteral.Print("a\nb")).is('"a\\nb"')
		end)

		test("vectors, nested tables and keys that are not names", function()
			local value = {
				Nested = { { 1, { 2, { 3 } } }, {} },
				V = vector.create(0.5, -2, 1024.25), -- exact in f32 (Vector3) too
				["not a name"] = true,
				["end"] = false,
				[5] = "sparse",
				[1.5] = "number key",
			}
			roundTrip(value)
			local text = LuauLiteral.Print(value)
			expect(string.find(text, '["end"] = false', 1, true) ~= nil).is_true()
			expect(string.find(text, "vector.create(0.5, -2, 1024.25)", 1, true) ~= nil).is_true()
		end)

		test("prints dictionary keys sorted, so equal data prints equal text", function()
			expect(LuauLiteral.Print { b = 1, a = 2, [2] = 3, [true] = 4 }).is("{ [true] = 4, [2] = 3, a = 2, b = 1 }")
		end)

		test("parses Vector3.new, comments and a leading return", function()
			local parsed = LuauLiteral.Parse("return { -- a comment\n Vector3.new(1, 2, 3); 'x' }")
			expect(same(parsed, { vector.create(1, 2, 3), "x" })).is_true()
		end)

		test("rejects what it cannot print", function()
			expect(function()
				LuauLiteral.Print { f = print }
			end).fails_with("LuauLiteral.Print: cannot print a function at value.f")
			local cycle = {}
			cycle.self = cycle
			expect(function()
				LuauLiteral.Print(cycle)
			end).fails_with("LuauLiteral.Print: cycle at value.self")
		end)

		test("rejects source outside the literal grammar, naming the line", function()
			expect(function()
				LuauLiteral.Parse("{\n\tos.exit(1)\n}")
			end).fails_with("LuauLiteral.Parse: unexpected 'os' at line 2")
			expect(function()
				LuauLiteral.Parse("{ 1 } 2")
			end).fails_with("LuauLiteral.Parse: unexpected text after the value at line 1")
			expect(function()
				LuauLiteral.Parse('{ "open }')
			end).fails()
		end)
	end)
end
