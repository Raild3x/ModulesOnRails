local Mutation = require("../Mutation")

local function mutant(id: number, file: string, line: number, op: string?)
	return {
		id = id,
		op = op or "ror",
		file = file,
		line = line,
		col = 1,
		original = "==",
		replacement = "~=",
		site = `mut:{op or "ror"}:{file}:{line}:1`,
	}
end

local function outcomeOf(status: string, m)
	return { mutant = m, status = status, duration = 0.1 }
end

-- A trivial JSON-ish decoder for parseSentinel tests (only the shapes the
-- sentinel carries).
local function decodeTally(json: string): any
	local pass, fail, skipped = json:match('"pass":(%d+),"fail":(%d+),"skipped":(%d+)')
	assert(pass ~= nil, "bad tally json")
	return { pass = tonumber(pass), fail = tonumber(fail), skipped = tonumber(skipped) }
end

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Mutation.flatten", function()
		test("stamps each mutant with its file path", function()
			local doc = {
				files = {
					{ path = "src/a.luau", mutants = { mutant(1, "", 3), mutant(2, "", 9) } },
					{ path = "src/b.luau", mutants = { mutant(3, "", 1) } },
				},
			}
			local flat = Mutation.flatten(doc)
			expect(#flat).is(3)
			expect(flat[1].file).is("src/a.luau")
			expect(flat[3].file).is("src/b.luau")
			expect(flat[3].id).is(3)
		end)
	end)

	describe("Mutation.plan", function()
		local COVERED = {
			["src/a.luau"] = { [3] = true, [9] = true },
			["src/b.luau"] = { [1] = true },
		}

		test("mutants on uncovered lines are split out and never run", function()
			local plan = Mutation.plan({
				mutant(1, "src/a.luau", 3),
				mutant(2, "src/a.luau", 50), -- uncovered line
				mutant(3, "src/c.luau", 1), -- file with no coverage at all
			}, COVERED, {})
			expect(#plan.toRun).is(1)
			expect(plan.toRun[1].id).is(1)
			expect(#plan.noCoverage).is(2)
			expect(#plan.sampledOut).is(0)
		end)

		test("the ops filter drops other operators entirely", function()
			local plan = Mutation.plan({
				mutant(1, "src/a.luau", 3, "ror"),
				mutant(2, "src/a.luau", 9, "lit"),
			}, COVERED, { ops = { lit = true } })
			expect(#plan.toRun).is(1)
			expect(plan.toRun[1].op).is("lit")
			expect(#plan.noCoverage).is(0)
		end)

		test("the run list sorts by file, line, id", function()
			local plan = Mutation.plan({
				mutant(5, "src/b.luau", 1),
				mutant(9, "src/a.luau", 9),
				mutant(2, "src/a.luau", 3),
			}, COVERED, {})
			local ids = {}
			for _, m in plan.toRun do
				table.insert(ids, m.id)
			end
			expect(ids).is_shallow_equal({ 2, 9, 5 })
		end)

		test("a limit stride-samples deterministically across the list", function()
			local mutants = {}
			local covered = { ["src/a.luau"] = {}, ["src/b.luau"] = {} }
			for i = 1, 10 do
				table.insert(mutants, mutant(i, "src/a.luau", i))
				covered["src/a.luau"][i] = true
			end
			for i = 11, 20 do
				table.insert(mutants, mutant(i, "src/b.luau", i))
				covered["src/b.luau"][i] = true
			end

			local plan = Mutation.plan(mutants, covered, { limit = 4 })
			expect(#plan.toRun).is(4)
			expect(#plan.sampledOut).is(16)
			-- Deterministic: same input, same sample.
			local again = Mutation.plan(mutants, covered, { limit = 4 })
			for i, m in plan.toRun do
				expect(again.toRun[i].id).is(m.id)
			end
			-- The stride spreads across both files instead of saturating the first.
			local files = {}
			for _, m in plan.toRun do
				files[m.file] = true
			end
			expect(files["src/a.luau"]).is_true()
			expect(files["src/b.luau"]).is_true()
		end)

		test("no limit runs everything covered", function()
			local plan = Mutation.plan({ mutant(1, "src/a.luau", 3), mutant(2, "src/a.luau", 9) }, COVERED, {})
			expect(#plan.toRun).is(2)
			expect(#plan.sampledOut).is(0)
		end)
	end)

	describe("Mutation.classify", function()
		local PASS = { pass = 5, fail = 0, skipped = 0 }
		local FAIL = { pass = 4, fail = 1, skipped = 0 }

		test("a timed-out child is a timeout even though its exit is bad", function()
			expect(Mutation.classify({ timedOut = true, ok = false, tally = nil, duration = 5 })).is("timeout")
		end)

		test("a crashed child (bad exit or missing sentinel) is an error", function()
			expect(Mutation.classify({ timedOut = false, ok = false, tally = PASS, duration = 1 })).is("error")
			expect(Mutation.classify({ timedOut = false, ok = true, tally = nil, duration = 1 })).is("error")
		end)

		test("failing tests kill the mutant; a green suite lets it survive", function()
			expect(Mutation.classify({ timedOut = false, ok = true, tally = FAIL, duration = 1 })).is("killed")
			expect(Mutation.classify({ timedOut = false, ok = true, tally = PASS, duration = 1 })).is("survived")
		end)
	end)

	describe("Mutation.parseSentinel", function()
		test("finds the sentinel among other output lines", function()
			local stdout = 'random tiniest output\n[[TM-MUT]]{"pass":3,"fail":1,"skipped":0}\ntrailing\n'
			local tally = Mutation.parseSentinel(stdout, decodeTally)
			expect(tally).exists()
			expect((tally :: any).fail).is(1)
		end)

		test("returns nil when the sentinel is missing or malformed", function()
			expect(Mutation.parseSentinel("no sentinel here\n", decodeTally)).never_exists()
			expect(Mutation.parseSentinel("[[TM-MUT]]not json\n", decodeTally)).never_exists()
		end)
	end)

	describe("Mutation.run", function()
		local function fakeDeps(overrides: { [string]: any })
			local calls = { applied = {}, writes = {}, reads = {}, suites = 0 }
			local deps = {
				filePath = function(rel)
					return "BUILD/" .. rel
				end,
				readFile = function(path)
					table.insert(calls.reads, path)
					return "ORIGINAL:" .. path
				end,
				writeFile = function(path, contents)
					table.insert(calls.writes, { path = path, contents = contents })
				end,
				applyMutant = function(id)
					table.insert(calls.applied, id)
					return "ok"
				end,
				runSuite = function()
					calls.suites += 1
					return { timedOut = false, ok = true, tally = { pass = 1, fail = 1, skipped = 0 }, duration = 0.2 }
				end,
			}
			for key, value in overrides do
				deps[key] = value
			end
			return deps, calls
		end

		test("applies, runs, classifies and restores per mutant", function()
			local deps, calls = fakeDeps({})
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3), mutant(2, "src/b.luau", 1) }, deps)
			expect(#outcomes).is(2)
			expect(outcomes[1].status).is("killed")
			expect(calls.suites).is(2)
			expect(calls.applied).is_shallow_equal({ 1, 2 })
			-- Every mutant restored its file's pristine bytes.
			expect(#calls.writes).is(2)
			expect(calls.writes[1].path).is("BUILD/src/a.luau")
			expect(calls.writes[1].contents).is("ORIGINAL:BUILD/src/a.luau")
		end)

		test("an invalid mutant skips the suite but still restores", function()
			local deps, calls = fakeDeps({
				applyMutant = function()
					return "invalid"
				end,
			})
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(outcomes[1].status).is("invalid")
			expect(calls.suites).is(0)
			expect(#calls.writes).is(1)
		end)

		test("an error thrown mid-mutant is caught, marked, and still restores", function()
			local deps, calls = fakeDeps({
				runSuite = function()
					error("engine exploded")
				end,
			})
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(outcomes[1].status).is("error")
			expect(#calls.writes).is(1)
		end)

		test("shouldStop halts the loop before the next mutant, keeping results", function()
			local deps, calls = fakeDeps({})
			local stopAfterFirst = false
			deps.shouldStop = function()
				return stopAfterFirst
			end
			deps.progress = function()
				stopAfterFirst = true
			end
			local outcomes, stopped = Mutation.run({
				mutant(1, "src/a.luau", 3),
				mutant(2, "src/b.luau", 1),
				mutant(3, "src/b.luau", 2),
			}, deps)
			expect(stopped).is_true()
			expect(#outcomes).is(1)
			-- The one mutant that ran was still restored.
			expect(#calls.writes).is(1)
		end)

		test("a completed loop reports stopped = false", function()
			local deps = fakeDeps({})
			local _, stopped = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(stopped).never_is_true()
		end)

		test("progress fires once per mutant with the outcome", function()
			local seen = {}
			local deps = fakeDeps({})
			deps.progress = function(index, total, outcome)
				table.insert(seen, { index = index, total = total, status = outcome.status })
			end
			Mutation.run({ mutant(1, "src/a.luau", 3), mutant(2, "src/b.luau", 1) }, deps)
			expect(#seen).is(2)
			expect(seen[2].index).is(2)
			expect(seen[2].total).is(2)
		end)
	end)

	describe("Mutation.summarize", function()
		test("computes counts and both scores", function()
			local plan = {
				toRun = {},
				noCoverage = { mutant(90, "src/a.luau", 99), mutant(91, "src/a.luau", 100) },
				sampledOut = { mutant(92, "src/a.luau", 101) },
			}
			local outcomes = {
				outcomeOf("killed", mutant(1, "src/a.luau", 1)),
				outcomeOf("killed", mutant(2, "src/a.luau", 2)),
				outcomeOf("survived", mutant(3, "src/a.luau", 3)),
				outcomeOf("timeout", mutant(4, "src/a.luau", 4)),
				outcomeOf("error", mutant(5, "src/a.luau", 5)),
				outcomeOf("invalid", mutant(6, "src/a.luau", 6)),
			}
			local totals = Mutation.summarize(plan, outcomes)
			expect(totals.not_run).is(0)
			expect(totals.run).is(5)
			expect(totals.killed).is(2)
			expect(totals.survived).is(1)
			expect(totals.timeout).is(1)
			expect(totals.error).is(1)
			expect(totals.invalid).is(1)
			expect(totals.no_coverage).is(2)
			expect(totals.sampled_out).is(1)
			expect(totals.total).is(9)
			-- detected = 4 of 5 run; of 7 incl. no-coverage.
			expect(totals.score_covered).is(80)
			expect(math.abs(totals.score_total - 100 * 4 / 7) < 1e-9).is_true()
		end)

		test("an empty run scores 100 (nothing to detect)", function()
			local totals = Mutation.summarize({ toRun = {}, noCoverage = {}, sampledOut = {} }, {})
			expect(totals.score_covered).is(100)
			expect(totals.score_total).is(100)
		end)

		test("an early-stopped run counts its unattempted mutants as not_run", function()
			local planned = { mutant(1, "src/a.luau", 1), mutant(2, "src/a.luau", 2), mutant(3, "src/a.luau", 3) }
			local plan = { toRun = planned, noCoverage = {}, sampledOut = {} }
			local outcomes = { outcomeOf("killed", planned[1]) }
			local totals = Mutation.summarize(plan, outcomes)
			expect(totals.not_run).is(2)
			expect(totals.run).is(1)
			expect(totals.total).is(3)
			expect(totals.score_covered).is(100)
		end)
	end)

	describe("Mutation.survivors", function()
		test("returns only survived mutants, sorted by file and line", function()
			local outcomes = {
				outcomeOf("survived", mutant(5, "src/b.luau", 2)),
				outcomeOf("killed", mutant(1, "src/a.luau", 1)),
				outcomeOf("survived", mutant(3, "src/a.luau", 7)),
			}
			local survivors = Mutation.survivors(outcomes)
			expect(#survivors).is(2)
			expect(survivors[1].file).is("src/a.luau")
			expect(survivors[2].file).is("src/b.luau")
		end)
	end)
end
