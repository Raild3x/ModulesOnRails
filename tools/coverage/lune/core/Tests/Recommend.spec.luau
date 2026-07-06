local Recommend = require("../Recommend")

local function m(covered: number, total: number)
	return { covered = covered, total = total }
end

local function emptyFile(path: string)
	return {
		path = path,
		lines = m(0, 0),
		statements = m(0, 0),
		functions = m(0, 0),
		branches = m(0, 0),
		decisions = m(0, 0),
		conditions = m(0, 0),
		fnEntries = {},
		partials = {},
		condPartials = {},
	}
end

local function mergedWith(overrides: { [string]: any })
	local merged = {
		package = "fixture_pkg",
		mapSha = "cafe",
		totals = {
			lines = m(0, 0),
			statements = m(0, 0),
			functions = m(0, 0),
			branches = m(0, 0),
			decisions = m(0, 0),
			conditions = m(0, 0),
		},
		files = { emptyFile("src/a.luau") },
		idToSite = {},
		suppressed = { ignored = {}, gated = {}, dead = {} },
		loops = {},
		constCandidates = {},
	}
	for key, value in overrides do
		merged[key] = value
	end
	return merged
end

local GREEN = { pass = 5, fail = 0, skipped = 0 }

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Recommend.build categories", function()
		test("a clean report yields no recommendations", function()
			local recs, total = Recommend.build(mergedWith({}) :: any, { tally = GREEN })
			expect(#recs).is(0)
			expect(total).is(0)
		end)

		test("failing tests outrank everything and carry the count", function()
			local file = emptyFile("src/a.luau")
			file.fnEntries = { { name = "M.go", line = 3, hits = 0, isPrivate = false } }
			local recs = Recommend.build(
				mergedWith({ files = { file } }) :: any,
				{ tally = { pass = 1, fail = 2, skipped = 0 } }
			)
			expect(recs[1].category).is("failing_tests")
			expect(recs[1].action:find("2 failing", 1, true)).exists()
		end)

		test("mutation survivors rank right after failing tests", function()
			local recs = Recommend.build(mergedWith({}) :: any, {
				tally = GREEN,
				survivors = {
					{ file = "src/a.luau", line = 7, op = "ror", original = "<", replacement = "<=" },
					{ file = "src/a.luau", line = 9, op = "not", original = "not", replacement = "" },
				},
			})
			expect(#recs).is(2)
			expect(recs[1].category).is("mutation_survivor")
			expect(recs[1].line).is(7)
			expect(recs[1].action:find("becomes '<='", 1, true)).exists()
			expect(recs[2].action:find("'not' is removed", 1, true)).exists()
		end)

		test("uncovered public functions include their parameter list", function()
			local file = emptyFile("src/a.luau")
			file.fnEntries = {
				{ name = "M.add", line = 3, hits = 0, isPrivate = false, params = { "a", "b" } },
				{ name = "local hidden", line = 9, hits = 0, isPrivate = true },
				{ name = "M.done", line = 12, hits = 4, isPrivate = false },
			}
			local recs = Recommend.build(mergedWith({ files = { file } }) :: any, { tally = GREEN })
			-- Only the uncovered public function; privates and covered are skipped.
			expect(#recs).is(1)
			expect(recs[1].category).is("uncovered_function")
			expect(recs[1].action).is("Add a test that calls M.add(a, b).")
		end)

		test("decision and condition partials get side-aware phrasing", function()
			local file = emptyFile("src/a.luau")
			file.partials = {
				{ file = "src/a.luau", line = 4, ctx = "while", src = "i > 0", missing = "never false" },
				{ file = "src/a.luau", line = 8, ctx = "if", src = "ok", missing = "never true" },
			}
			file.condPartials = {
				{ file = "src/a.luau", line = 8, src = "b", missing = "never false" },
			}
			local recs = Recommend.build(mergedWith({ files = { file } }) :: any, { tally = GREEN })
			expect(#recs).is(3)
			expect(recs[1].action:find("exit path is untested", 1, true)).exists()
			expect(recs[2].action:find("the if condition 'ok' holds", 1, true)).exists()
			expect(recs[3].category).is("condition_partial")
			expect(recs[3].action:find("'b' is false", 1, true)).exists()
		end)

		test("loops and const candidates trail the list", function()
			local recs = Recommend.build(
				mergedWith({
					loops = { { file = "src/a.luau", line = 5, ctx = "for", zero = 0, one = 2, many = 0 } },
					constCandidates = {
						{ file = "src/a.luau", line = 1, col = 1, kind = "local", names = { "M" }, site = "s" },
						{ file = "src/a.luau", line = 2, col = 1, kind = "local", names = { "x" }, site = "t" },
					},
				}) :: any,
				{ tally = GREEN }
			)
			expect(#recs).is(2)
			expect(recs[1].category).is("loop_iteration")
			expect(recs[1].action:find("at least twice", 1, true)).exists()
			expect(recs[2].category).is("const_candidate")
			expect(recs[2].action:find("2 local(s)", 1, true)).exists()
			expect(recs[2].file).never_exists()
		end)
	end)

	describe("Recommend.build ranking and cap", function()
		test("sorts by priority, then file, then line", function()
			local fileB = emptyFile("src/b.luau")
			fileB.partials = { { file = "src/b.luau", line = 2, ctx = "if", src = "x", missing = "never true" } }
			local fileA = emptyFile("src/a.luau")
			fileA.fnEntries = { { name = "A.fn", line = 20, hits = 0, isPrivate = false } }
			fileA.partials = { { file = "src/a.luau", line = 9, ctx = "if", src = "y", missing = "never true" } }
			local recs = Recommend.build(mergedWith({ files = { fileB, fileA } }) :: any, {
				tally = GREEN,
				survivors = { { file = "src/z.luau", line = 99, op = "lit", original = "1", replacement = "0" } },
			})
			expect(recs[1].category).is("mutation_survivor")
			expect(recs[2].category).is("uncovered_function")
			expect(recs[3].file).is("src/a.luau")
			expect(recs[4].file).is("src/b.luau")
		end)

		test("caps at ten but reports the true total", function()
			local file = emptyFile("src/a.luau")
			for i = 1, 14 do
				table.insert(file.fnEntries, { name = `M.f{i}`, line = i, hits = 0, isPrivate = false })
			end
			local recs, total = Recommend.build(mergedWith({ files = { file } }) :: any, { tally = GREEN })
			expect(#recs).is(10)
			expect(total).is(14)
		end)

		test("long condition sources are truncated in the action text", function()
			local file = emptyFile("src/a.luau")
			file.partials = {
				{ file = "src/a.luau", line = 1, ctx = "if", src = string.rep("x", 60), missing = "never true" },
			}
			local recs = Recommend.build(mergedWith({ files = { file } }) :: any, { tally = GREEN })
			expect(recs[1].action:find(string.rep("x", 37) .. "...", 1, true)).exists()
			expect(recs[1].action:find(string.rep("x", 41), 1, true)).never_exists()
		end)
	end)
end
