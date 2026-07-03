local fs = require("@lune/fs")
local serde = require("@lune/serde")

local CoverageJson = require("../CoverageJson")

local function m(covered: number, total: number)
	return { covered = covered, total = total }
end

local function totals()
	return {
		lines = m(1, 2),
		statements = m(1, 3),
		functions = m(1, 2),
		branches = m(2, 2),
		decisions = m(1, 1),
		conditions = m(0, 0),
	}
end

-- A hand-built Merged report matching the shapes Merge.merge produces.
local function mergedFixture()
	return {
		package = "fixture_pkg",
		mapSha = "cafe",
		totals = totals(),
		files = {
			{
				path = "src/a.luau",
				lines = m(1, 2),
				statements = m(1, 3),
				functions = m(1, 2),
				branches = m(2, 2),
				decisions = m(1, 1),
				conditions = m(0, 0),
				fnEntries = {
					{ name = "M.doThing", line = 5, hits = 0, isPrivate = false },
					{ name = "local hidden", line = 9, hits = 3, isPrivate = true },
				},
				partials = {
					{ file = "src/a.luau", line = 8, ctx = "if", src = "a and b", missing = "never false" },
				},
				condPartials = {
					{ file = "src/a.luau", line = 8, src = "b", missing = "never true" },
				},
			},
		},
		idToSite = { [1] = "stmt:src/a.luau:3:1", [5] = "dec:src/a.luau:8:4" },
		suppressed = {
			ignored = {},
			gated = {
				{ file = "src/a.luau", line = 12, site = "stmt:src/a.luau:12:2", kind = "stmt", label = "", detail = "gate note" },
			},
			dead = {},
		},
		loops = {
			{ file = "src/a.luau", line = 10, ctx = "for", zero = 1, one = 0, many = 0 },
		},
		constCandidates = {},
	}
end

local INFO = {
	classification = "lune",
	classificationReason = "no roblox markers",
	env = "lune",
	duration = 0.5,
	tally = { pass = 3, fail = 0, skipped = 0 },
}

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("CoverageJson.build", function()
		test("emits the versioned schema and run metadata", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			expect(doc.schema).is("tm-coverage-report/1")
			expect(doc.package).is("fixture_pkg")
			expect(doc.run.env).is("lune")
			expect(doc.run.status_tally.pass).is(3)
		end)

		test("computes percentages, with empty metrics reading 100", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			expect(doc.totals.conditions.pct).is(100)
			expect(doc.totals.statements.pct).is(100 * 1 / 3)
			expect(doc.totals.branches.pct).is(100)
		end)

		test("collects findings for partials and never-entered functions", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			local findings = doc.files[1].findings
			local byType = {}
			for _, finding in findings do
				byType[finding.type] = finding
			end
			expect(byType.decision_partial.detail).is("never false")
			expect(byType.condition_never_varied.src).is("b")
			-- Only the zero-hit function is a finding, tagged by visibility.
			expect(byType.function_never_entered.name).is("M.doThing")
			expect(byType.function_never_entered.detail).is("public")
			expect(#findings).is(3)
		end)

		test("const candidates become per-file const_candidate findings", function()
			local merged = mergedFixture()
			merged.constCandidates = {
				{ file = "src/a.luau", line = 4, col = 1, kind = "local", names = { "M" }, site = "const:src/a.luau:4:1" },
				{ file = "src/other.luau", line = 1, col = 1, kind = "local", names = { "X" }, site = "const:src/other.luau:1:1" },
			}
			local doc = CoverageJson.build(merged, INFO)
			-- Only the candidate whose file is in the report lands as a finding.
			local found = {}
			for _, finding in doc.files[1].findings do
				if finding.type == "const_candidate" then
					table.insert(found, finding)
				end
			end
			expect(#found).is(1)
			expect(found[1].line).is(4)
			expect(found[1].kind).is("local")
			expect(found[1].names[1]).is("M")
			expect(found[1].detail).is("never reassigned")
		end)

		test("renames gated suppression to env_gated", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			expect(#doc.suppressed.env_gated).is(1)
			expect(doc.suppressed.env_gated[1].detail).is("gate note")
			expect(#doc.suppressed.ignored).is(0)
			expect(#doc.suppressed.dead).is(0)
		end)

		test("maps loop findings to loops_single_iteration", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			expect(#doc.loops_single_iteration).is(1)
			expect(doc.loops_single_iteration[1].ctx).is("for")
		end)

		test("translates per-test probe ids to site keys, dropping unknown ids", function()
			local perTest = { { id = "suite > t1", status = "pass", probes = { 1, 5, 99 } } }
			local doc = CoverageJson.build(mergedFixture(), INFO, perTest)
			expect(#doc.per_test).is(1)
			expect(doc.per_test[1].id).is("suite > t1")
			expect(doc.per_test[1].sites).is_shallow_equal({ "stmt:src/a.luau:3:1", "dec:src/a.luau:8:4" })
		end)

		test("omits per_test when no attribution is supplied", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			expect(doc.per_test).never_exists()
		end)
	end)

	describe("CoverageJson.write", function()
		test("writes a JSON document that round-trips", function()
			local doc = CoverageJson.build(mergedFixture(), INFO)
			if not fs.isDir(".coverage") then
				fs.writeDir(".coverage")
			end
			local path = ".coverage/spec-write-test.json"
			CoverageJson.write(path, doc)
			local decoded = serde.decode("json", fs.readFile(path))
			fs.removeFile(path)
			expect(decoded.schema).is("tm-coverage-report/1")
			expect(decoded.package).is("fixture_pkg")
			expect(decoded.totals.lines.covered).is(1)
		end)
	end)
end
