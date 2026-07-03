local Report = require("../Report")

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

-- A minimal Merged skeleton; tests override the parts they exercise.
local function mergedWith(overrides: { [string]: any })
	local merged = {
		package = "fixture_pkg",
		mapSha = "cafe",
		totals = {
			lines = m(1, 2),
			statements = m(1, 2),
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

local INFO = {
	pipeline = "lune",
	pipelineReason = "pure Luau",
	tally = { pass = 2, fail = 1, skipped = 0 },
	duration = 1.25,
}

-- Renders to a captured line list instead of the console.
local function render(merged, info): { string }
	local lines: { string } = {}
	Report.console(merged, info or INFO, function(...)
		table.insert(lines, table.concat({ ... }, " "))
	end)
	return lines
end

local function perFileInfo()
	local info = table.clone(INFO)
	info.perFile = true
	return info
end

local function anyLineContains(lines: { string }, needle: string): boolean
	for _, line in lines do
		if line:find(needle, 1, true) then
			return true
		end
	end
	return false
end

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Report.console header and metrics", function()
		test("prints the package, pipeline and tally", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "fixture_pkg")).is_true()
			expect(anyLineContains(lines, "[lune: pure Luau]")).is_true()
			expect(anyLineContains(lines, "3 tests: 2 pass")).is_true()
			expect(anyLineContains(lines, "1 fail")).is_true()
		end)

		test("formats metric rows with counts, percentage and bar", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "Lines")).is_true()
			expect(anyLineContains(lines, "1 / 2")).is_true()
			expect(anyLineContains(lines, "50.0%")).is_true()
			-- 50% fills exactly half of the 20-cell bar.
			expect(anyLineContains(lines, string.rep("\u{2588}", 10) .. string.rep("\u{2591}", 10))).is_true()
		end)

		test("hides the conditions row when no conditions were measured", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "Conditions")).never_is_true()
		end)

		test("shows the conditions row when conditions were measured", function()
			local merged = mergedWith({})
			merged.totals.conditions = m(1, 4)
			local lines = render(merged)
			expect(anyLineContains(lines, "Conditions")).is_true()
			expect(anyLineContains(lines, "25.0%")).is_true()
		end)

		test("the per-file breakdown is hidden by default", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "Per-file")).never_is_true()
		end)

		test("--per-file renders one row per file, worst coverage first", function()
			local fileA = emptyFile("src/a.luau")
			fileA.lines = m(9, 10)
			local fileB = emptyFile("src/b.luau")
			fileB.lines = m(1, 4)
			local lines = render(mergedWith({ files = { fileA, fileB } }), perFileInfo())
			expect(anyLineContains(lines, "Per-file lines (worst first):")).is_true()
			expect(anyLineContains(lines, "90.0%")).is_true()
			expect(anyLineContains(lines, "25.0%")).is_true()

			local rows = {}
			for _, line in lines do
				if line:find("^    src/") then
					table.insert(rows, line)
				end
			end
			expect(#rows).is(2)
			expect(rows[1]:find("src/b.luau", 1, true)).exists()
			expect(rows[2]:find("src/a.luau", 1, true)).exists()
		end)

		test("per-file rows with equal coverage sort by path", function()
			local fileA = emptyFile("src/z.luau")
			fileA.lines = m(1, 2)
			local fileB = emptyFile("src/a.luau")
			fileB.lines = m(2, 4)
			local lines = render(mergedWith({ files = { fileA, fileB } }), perFileInfo())
			local rows = {}
			for _, line in lines do
				if line:find("^    src/") then
					table.insert(rows, line)
				end
			end
			expect(rows[1]:find("src/a.luau", 1, true)).exists()
			expect(rows[2]:find("src/z.luau", 1, true)).exists()
		end)

		test("an empty report renders no findings sections", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "Functions never entered")).never_is_true()
			expect(anyLineContains(lines, "Decisions never taken")).never_is_true()
			expect(anyLineContains(lines, "Loops never iterated")).never_is_true()
			expect(anyLineContains(lines, "Suppressed")).never_is_true()
		end)
	end)

	describe("Report.console uncovered functions", function()
		test("lists uncovered publics sorted and summarizes privates", function()
			local fileB = emptyFile("src/b.luau")
			fileB.fnEntries = {
				{ name = "B.late", line = 30, hits = 0, isPrivate = false },
				{ name = "B.early", line = 5, hits = 0, isPrivate = false },
				{ name = "local hidden", line = 9, hits = 0, isPrivate = true },
			}
			local fileA = emptyFile("src/a.luau")
			fileA.fnEntries = {
				{ name = "A.covered", line = 2, hits = 4, isPrivate = false },
				{ name = "A.missed", line = 7, hits = 0, isPrivate = false },
			}
			-- Deliberately out of path order to exercise the sort.
			local lines = render(mergedWith({ files = { fileB, fileA } }))
			expect(anyLineContains(lines, "Functions never entered (3):")).is_true()
			expect(anyLineContains(lines, "src/a.luau:7  A.missed")).is_true()
			expect(anyLineContains(lines, "1 private/local function(s) also uncovered")).is_true()
			expect(anyLineContains(lines, "A.covered")).never_is_true()

			-- Cross-file sort puts a.luau first; same-file sort puts line 5 first.
			local ordered = {}
			for _, line in lines do
				if line:find("^    src/") then
					table.insert(ordered, line)
				end
			end
			expect(ordered[1]:find("src/a.luau:7", 1, true)).exists()
			expect(ordered[2]:find("src/b.luau:5", 1, true)).exists()
			expect(ordered[3]:find("src/b.luau:30", 1, true)).exists()
		end)
	end)

	describe("Report.console partials", function()
		test("renders decision partials across files and truncates long snippets", function()
			local fileA = emptyFile("src/a.luau")
			local longSrc = string.rep("x", 60)
			fileA.partials = {
				{ file = "src/a.luau", line = 8, ctx = "if", src = "a and b", missing = "never false" },
				{ file = "src/a.luau", line = 3, ctx = "while", src = longSrc, missing = "never true" },
			}
			local fileB = emptyFile("src/b.luau")
			fileB.partials = {
				{ file = "src/b.luau", line = 1, ctx = "repeat", src = "done", missing = "never true" },
			}
			-- Out of path order to exercise the cross-file sort.
			local lines = render(mergedWith({ files = { fileB, fileA } }))
			expect(anyLineContains(lines, "Decisions never taken both ways (3):")).is_true()
			expect(anyLineContains(lines, "if 'a and b'")).is_true()
			expect(anyLineContains(lines, string.rep("x", 45) .. "...")).is_true()
			expect(anyLineContains(lines, longSrc)).never_is_true()
		end)

		test("renders condition partials across files and truncates long snippets", function()
			local fileA = emptyFile("src/a.luau")
			local longSrc = string.rep("y", 55)
			fileA.condPartials = {
				{ file = "src/a.luau", line = 8, src = "b", missing = "never true" },
				{ file = "src/a.luau", line = 2, src = longSrc, missing = "never false" },
			}
			local fileB = emptyFile("src/b.luau")
			fileB.condPartials = {
				{ file = "src/b.luau", line = 4, src = "c", missing = "never true" },
			}
			local lines = render(mergedWith({ files = { fileB, fileA } }))
			expect(anyLineContains(lines, "Conditions that never varied (3):")).is_true()
			expect(anyLineContains(lines, "'b'")).is_true()
			expect(anyLineContains(lines, string.rep("y", 45) .. "...")).is_true()
			expect(anyLineContains(lines, longSrc)).never_is_true()
		end)
	end)

	describe("Report.console loops", function()
		test("describes each iteration pattern", function()
			local lines = render(mergedWith({
				-- Two files, out of order, to exercise the cross-file sort.
				loops = {
					{ file = "src/b.luau", line = 10, ctx = "for", zero = 0, one = 3, many = 0 },
					{ file = "src/a.luau", line = 20, ctx = "while", zero = 2, one = 0, many = 0 },
					{ file = "src/a.luau", line = 30, ctx = "repeat", zero = 1, one = 1, many = 0 },
				},
			}))
			expect(anyLineContains(lines, "Loops never iterated more than once (3):")).is_true()
			expect(anyLineContains(lines, "for loop \u{2014} always exactly 1 iteration")).is_true()
			expect(anyLineContains(lines, "while loop \u{2014} body never ran (0 iterations)")).is_true()
			expect(anyLineContains(lines, "repeat loop \u{2014} only 0 or 1 iteration(s)")).is_true()
		end)
	end)

	describe("Report.console const candidates", function()
		local CANDS = {
			{ file = "src/b.luau", line = 4, col = 1, kind = "local", names = { "a", "b" }, site = "const:src/b.luau:4:1" },
			{ file = "src/a.luau", line = 9, col = 1, kind = "local_function", names = { "helper" }, site = "const:src/a.luau:9:1" },
		}

		test("hidden when the run produced no candidates", function()
			local lines = render(mergedWith({}))
			expect(anyLineContains(lines, "Const candidates")).never_is_true()
		end)

		test("lists declarations sorted by file with decl-style labels", function()
			local lines = render(mergedWith({ constCandidates = CANDS }))
			expect(anyLineContains(lines, "Const candidates \u{2014} locals never reassigned (2):")).is_true()
			expect(anyLineContains(lines, "src/a.luau:9  local function helper")).is_true()
			expect(anyLineContains(lines, "src/b.luau:4  local a, b")).is_true()

			local rows = {}
			for _, line in lines do
				if line:find("^    src/") then
					table.insert(rows, line)
				end
			end
			expect(rows[1]:find("src/a.luau", 1, true)).exists()
			expect(rows[2]:find("src/b.luau", 1, true)).exists()
		end)

		test("the lune pipeline gets the const-vs-lune caveat, roblox does not", function()
			local lines = render(mergedWith({ constCandidates = CANDS }))
			expect(anyLineContains(lines, "Lune cannot parse const yet")).is_true()

			local info = table.clone(INFO)
			info.pipeline = "roblox"
			local robloxLines = render(mergedWith({ constCandidates = CANDS }), info)
			expect(anyLineContains(robloxLines, "Lune cannot parse const yet")).never_is_true()
		end)
	end)

	describe("Report.mutation", function()
		local TOTALS = {
			total = 12,
			run = 8,
			killed = 5,
			survived = 2,
			timeout = 1,
			error = 0,
			invalid = 1,
			no_coverage = 2,
			sampled_out = 1,
			not_run = 0,
			score_covered = 75,
			score_total = 60,
		}
		local SURVIVORS = {
			{ file = "src/a.luau", line = 7, op = "ror", original = "<", replacement = "<=" },
			{ file = "src/a.luau", line = 12, op = "not", original = "not", replacement = "" },
		}

		local function renderMutation(totals, survivors): { string }
			local lines: { string } = {}
			Report.mutation("fixture_pkg", totals, survivors, function(...)
				table.insert(lines, table.concat({ ... }, " "))
			end)
			return lines
		end

		test("prints the tallies, score bar and skip notes", function()
			local lines = renderMutation(TOTALS, SURVIVORS)
			expect(anyLineContains(lines, "mutation \u{2014} fixture_pkg")).is_true()
			expect(anyLineContains(lines, "12 mutants: 8 run \u{00b7} 5 killed \u{00b7} 2 survived \u{00b7} 1 timeout \u{00b7} 0 error")).is_true()
			expect(anyLineContains(lines, "75.0%")).is_true()
			expect(anyLineContains(lines, "60.0%")).is_true()
			expect(anyLineContains(lines, "2 mutant(s) on lines no test executes")).is_true()
			expect(anyLineContains(lines, "1 mutant(s) sampled out")).is_true()
			expect(anyLineContains(lines, "1 mutant(s) did not parse")).is_true()
		end)

		test("lists survivors with their change, including removals", function()
			local lines = renderMutation(TOTALS, SURVIVORS)
			expect(anyLineContains(lines, "Surviving mutants \u{2014} tests pass despite the change (2):")).is_true()
			expect(anyLineContains(lines, "src/a.luau:7  ror '<' \u{2192} '<='")).is_true()
			expect(anyLineContains(lines, "src/a.luau:12  not 'not' removed")).is_true()
		end)

		test("omits the survivor section and zero-count notes when clean", function()
			local totals = table.clone(TOTALS)
			totals.survived = 0
			totals.no_coverage = 0
			totals.sampled_out = 0
			totals.invalid = 0
			local lines = renderMutation(totals, {})
			expect(anyLineContains(lines, "Surviving mutants")).never_is_true()
			expect(anyLineContains(lines, "sampled out")).never_is_true()
			expect(anyLineContains(lines, "did not parse")).never_is_true()
			expect(anyLineContains(lines, "no test executes")).never_is_true()
			expect(anyLineContains(lines, "stopped early")).never_is_true()
		end)

		test("an early-stopped run reports its unattempted mutants", function()
			local totals = table.clone(TOTALS)
			totals.not_run = 4
			local lines = renderMutation(totals, {})
			expect(anyLineContains(lines, "stopped early: 4 planned mutant(s) not run")).is_true()
		end)
	end)

	describe("Report.recommendations", function()
		local function renderRecs(recs, total): { string }
			local lines: { string } = {}
			Report.recommendations(recs, total, function(...)
				table.insert(lines, table.concat({ ... }, " "))
			end)
			return lines
		end

		test("prints nothing for an empty list", function()
			expect(#renderRecs({}, 0)).is(0)
		end)

		test("numbers entries, with file:line prefixes when present", function()
			local lines = renderRecs({
				{ priority = 1, category = "failing_tests", action = "Fix the 2 failing test(s) first." },
				{ priority = 3, category = "uncovered_function", file = "src/a.luau", line = 7, action = "Add a test that calls M.add(a, b)." },
			}, 2)
			expect(anyLineContains(lines, "Recommended next steps (2):")).is_true()
			expect(anyLineContains(lines, "1. Fix the 2 failing test(s) first.")).is_true()
			expect(anyLineContains(lines, "2. src/a.luau:7  Add a test that calls M.add(a, b).")).is_true()
		end)

		test("a capped list shows top-N-of-M", function()
			local recs = {}
			for i = 1, 10 do
				table.insert(recs, { priority = 3, category = "uncovered_function", action = `do thing {i}` })
			end
			local lines = renderRecs(recs, 14)
			expect(anyLineContains(lines, "Recommended next steps (top 10 of 14):")).is_true()
		end)
	end)

	describe("Report.console suppressed", function()
		test("groups entries by suppression kind with a total", function()
			local entry = function(line: number, label: string)
				return { file = "src/a.luau", line = line, site = "s", kind = "stmt", label = label, detail = "d" }
			end
			local lines = render(mergedWith({
				suppressed = {
					ignored = { entry(1, "M.doThing") },
					gated = { entry(2, "service:IsRunning()") },
					dead = { entry(3, "x = 99") },
				},
			}))
			expect(anyLineContains(lines, "Suppressed \u{2014} excluded from the metrics above (3):")).is_true()
			expect(anyLineContains(lines, "ignore rule (1):")).is_true()
			expect(anyLineContains(lines, "env-gated, unreachable in edit mode (1):")).is_true()
			expect(anyLineContains(lines, "dead code (1):")).is_true()
			expect(anyLineContains(lines, "M.doThing")).is_true()
		end)

		test("falls back to the probe kind when an entry has no label", function()
			local lines = render(mergedWith({
				suppressed = {
					ignored = {
						{ file = "src/a.luau", line = 1, site = "s", kind = "stmt", label = "", detail = "d" },
					},
					gated = {},
					dead = {},
				},
			}))
			expect(anyLineContains(lines, "src/a.luau:1  stmt")).is_true()
		end)

		test("truncates long suppressed labels", function()
			local longLabel = string.rep("z", 60)
			local lines = render(mergedWith({
				suppressed = {
					ignored = {},
					gated = {
						{ file = "src/a.luau", line = 2, site = "s", kind = "decision", label = longLabel, detail = "d" },
					},
					dead = {},
				},
			}))
			-- Also exercises rendering with an empty ignored group.
			expect(anyLineContains(lines, "ignore rule")).never_is_true()
			expect(anyLineContains(lines, string.rep("z", 45) .. "...")).is_true()
			expect(anyLineContains(lines, longLabel)).never_is_true()
		end)
	end)
end
