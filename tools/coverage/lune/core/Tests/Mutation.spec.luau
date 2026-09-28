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

		test("mutants in whole-file-ignored files are dropped, not counted as no-coverage", function()
			local plan = Mutation.plan({
				mutant(1, "src/a.luau", 3),
				mutant(2, "src/fixtures.luau", 1), -- ignored file
				mutant(3, "src/fixtures.luau", 2),
			}, COVERED, { ignoredFiles = { ["src/fixtures.luau"] = true } })
			expect(#plan.toRun).is(1)
			expect(#plan.noCoverage).is(0)
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
			expect(ids).is_shallow_equal { 2, 9, 5 }
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
			expect(plan.filesFilter).never_exists()
		end)

		test("a files filter drops other files entirely, before no-coverage and the limit", function()
			local plan = Mutation.plan({
				mutant(1, "src/a.luau", 3),
				mutant(2, "src/a.luau", 50), -- uncovered, but in a kept file
				mutant(3, "src/b.luau", 1), -- covered, but filtered out
				mutant(4, "src/c.luau", 1), -- uncovered and filtered out
			}, COVERED, { files = { "src/a.luau" }, limit = 5 })
			expect(#plan.toRun).is(1)
			expect(plan.toRun[1].id).is(1)
			expect(#plan.noCoverage).is(1)
			expect(plan.noCoverage[1].id).is(2)
			expect(#plan.sampledOut).is(0)
			expect(plan.filesFilter).is_shallow_equal { "src/a.luau" }
		end)
	end)

	describe("Mutation.parseFileGlobs", function()
		test("splits the csv, trims, and normalizes ./ and backslashes", function()
			expect(Mutation.parseFileGlobs(" src/Tiles.luau, ./src/Snap.luau ,src\\Deep\\*.luau")).is_shallow_equal {
				"src/Tiles.luau",
				"src/Snap.luau",
				"src/Deep/*.luau",
			}
		end)

		test("nil or an empty list means no filter", function()
			expect(Mutation.parseFileGlobs(nil)).never_exists()
			expect(Mutation.parseFileGlobs("")).never_exists()
			expect(Mutation.parseFileGlobs(" , ")).never_exists()
		end)
	end)

	describe("Mutation.matchesFile", function()
		test("a plain path matches only itself", function()
			expect(Mutation.matchesFile({ "src/Snap.luau" }, "src/Snap.luau")).is_true()
			expect(Mutation.matchesFile({ "src/Snap.luau" }, "src/SnapX.luau")).never_is_true()
			expect(Mutation.matchesFile({ "src/Snap.luau" }, "src/sub/Snap.luau")).never_is_true()
			-- `.` and `-` are literal, not pattern magic.
			expect(Mutation.matchesFile({ "src/a-b.luau" }, "src/a-b.luau")).is_true()
			expect(Mutation.matchesFile({ "src/a.luau" }, "src/aXluau")).never_is_true()
		end)

		test("* and ? stay inside one segment", function()
			expect(Mutation.matchesFile({ "src/*.luau" }, "src/Tiles.luau")).is_true()
			expect(Mutation.matchesFile({ "src/*.luau" }, "src/Tests/X.luau")).never_is_true()
			expect(Mutation.matchesFile({ "src/Ti?es.luau" }, "src/Tiles.luau")).is_true()
			expect(Mutation.matchesFile({ "src/Ti?es.luau" }, "src/Tis.luau")).never_is_true()
		end)

		test("** spans zero or more directories", function()
			expect(Mutation.matchesFile({ "src/**/*.luau" }, "src/Tiles.luau")).is_true()
			expect(Mutation.matchesFile({ "src/**/*.luau" }, "src/a/b/Tiles.luau")).is_true()
			expect(Mutation.matchesFile({ "**/Snap.luau" }, "src/deep/Snap.luau")).is_true()
			expect(Mutation.matchesFile({ "src/**" }, "src/a/b.luau")).is_true()
			expect(Mutation.matchesFile({ "src/**/*.luau" }, "lib/Tiles.luau")).never_is_true()
		end)

		test("any glob in the list is enough", function()
			local globs = { "src/Tiles.luau", "src/Clearance.luau" }
			expect(Mutation.matchesFile(globs, "src/Clearance.luau")).is_true()
			expect(Mutation.matchesFile(globs, "src/Snap.luau")).never_is_true()
		end)
	end)

	describe("Mutation.classify", function()
		local PASS = { pass = 5, fail = 0, skipped = 0 }
		local FAIL = { pass = 4, fail = 1, skipped = 0 }

		test("a timed-out child is a timeout even though its exit is bad", function()
			expect(Mutation.classify { timedOut = true, ok = false, tally = nil, duration = 5 }).is("timeout")
		end)

		test("a crashed child (bad exit or missing sentinel) is an error", function()
			expect(Mutation.classify { timedOut = false, ok = false, tally = PASS, duration = 1 }).is("error")
			expect(Mutation.classify { timedOut = false, ok = true, tally = nil, duration = 1 }).is("error")
		end)

		test("failing tests kill the mutant; a green suite lets it survive", function()
			expect(Mutation.classify { timedOut = false, ok = true, tally = FAIL, duration = 1 }).is("killed")
			expect(Mutation.classify { timedOut = false, ok = true, tally = PASS, duration = 1 }).is("survived")
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
			local deps, calls = fakeDeps {}
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3), mutant(2, "src/b.luau", 1) }, deps)
			expect(#outcomes).is(2)
			expect(outcomes[1].status).is("killed")
			expect(calls.suites).is(2)
			expect(calls.applied).is_shallow_equal { 1, 2 }
			-- Every mutant restored its file's pristine bytes.
			expect(#calls.writes).is(2)
			expect(calls.writes[1].path).is("BUILD/src/a.luau")
			expect(calls.writes[1].contents).is("ORIGINAL:BUILD/src/a.luau")
		end)

		test("an invalid mutant skips the suite but still restores", function()
			local deps, calls = fakeDeps {
				applyMutant = function()
					return "invalid"
				end,
			}
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(outcomes[1].status).is("invalid")
			expect(calls.suites).is(0)
			expect(#calls.writes).is(1)
		end)

		test("an error thrown mid-mutant is caught, marked, and still restores", function()
			local deps, calls = fakeDeps {
				runSuite = function()
					error("engine exploded")
				end,
			}
			local outcomes = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(outcomes[1].status).is("error")
			expect(#calls.writes).is(1)
		end)

		test("shouldStop halts the loop before the next mutant, keeping results", function()
			local deps, calls = fakeDeps {}
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
			local deps = fakeDeps {}
			local _, stopped = Mutation.run({ mutant(1, "src/a.luau", 3) }, deps)
			expect(stopped).never_is_true()
		end)

		test("progress fires once per mutant with the outcome", function()
			local seen = {}
			local deps = fakeDeps {}
			deps.progress = function(index, total, outcome)
				table.insert(seen, { index = index, total = total, status = outcome.status })
			end
			Mutation.run({ mutant(1, "src/a.luau", 3), mutant(2, "src/b.luau", 1) }, deps)
			expect(#seen).is(2)
			expect(seen[2].index).is(2)
			expect(seen[2].total).is(2)
		end)
	end)

	describe("Mutation.run with jobs > 1", function()
		-- A deterministic cooperative scheduler standing in for task.spawn /
		-- task.wait: spawn runs a worker until its first yield, and each wait
		-- resumes every live worker once.
		local function scheduler()
			local threads: { thread } = {}
			local function resume(co: thread)
				local ok, err = coroutine.resume(co)
				assert(ok, err)
			end
			return {
				spawn = function(fn: () -> ())
					local co = coroutine.create(fn)
					table.insert(threads, co)
					resume(co)
				end,
				wait = function()
					for _, co in table.clone(threads) do
						if coroutine.status(co) == "suspended" then
							resume(co)
						end
					end
				end,
			}
		end

		-- Suite runs that take `ticks[id]` scheduler turns and end in `status[id]`,
		-- tracking which worker's build each mutant was applied in and restored to.
		local function parallelDeps(jobs: number, ticks: { [number]: number }, statusOf: { [number]: string })
			local sched = scheduler()
			local current: { [number]: number } = {}
			local log = { finished = {}, appliedBy = {}, restoredBy = {}, maxInFlight = 0 }
			local inFlight = 0
			local deps = {
				jobs = jobs,
				spawn = sched.spawn,
				wait = sched.wait,
				filePath = function(rel, worker)
					return `W{worker}/{rel}`
				end,
				readFile = function(path)
					return "ORIGINAL:" .. path
				end,
				writeFile = function(path, contents)
					expect(contents).is("ORIGINAL:" .. path)
					table.insert(log.restoredBy, path)
				end,
				applyMutant = function(id, worker)
					current[worker] = id
					log.appliedBy[id] = worker
					return "ok"
				end,
				runSuite = function(worker)
					local id = current[worker]
					inFlight += 1
					log.maxInFlight = math.max(log.maxInFlight, inFlight)
					for _ = 1, ticks[id] do
						coroutine.yield()
					end
					inFlight -= 1
					table.insert(log.finished, id)
					local tally = { pass = 1, fail = if statusOf[id] == "killed" then 1 else 0, skipped = 0 }
					return { timedOut = false, ok = true, tally = tally, duration = ticks[id] }
				end,
			}
			return deps, log
		end

		local MUTANTS = {
			mutant(1, "src/a.luau", 1),
			mutant(2, "src/a.luau", 2),
			mutant(3, "src/b.luau", 1),
			mutant(4, "src/b.luau", 2),
			mutant(5, "src/c.luau", 1),
		}
		local TICKS = { [1] = 5, [2] = 1, [3] = 1, [4] = 3, [5] = 1 }
		local STATUS = { [1] = "killed", [2] = "survived", [3] = "killed", [4] = "survived", [5] = "killed" }

		test("outcomes merge back in plan order, identical to a serial run", function()
			-- The serial run's suites yield too, so drive it to completion in its own thread.
			local serial = {}
			local co = coroutine.create(function()
				serial = Mutation.run(MUTANTS, (parallelDeps(1, TICKS, STATUS)))
			end)
			repeat
				local ok, err = coroutine.resume(co)
				assert(ok, err)
			until coroutine.status(co) == "dead"
			expect(#serial).is(5)
			local deps, log = parallelDeps(3, TICKS, STATUS)
			local parallel, stopped = Mutation.run(MUTANTS, deps)
			expect(stopped).never_is_true()
			-- Workers really overlapped and finished out of order...
			expect(log.maxInFlight).is(3)
			expect(log.finished[1] ~= 1).is_true()
			-- ...yet the merged result is the serial one, mutant for mutant.
			expect(#parallel).is(#serial)
			for i, o in serial do
				expect(parallel[i].mutant.id).is(o.mutant.id)
				expect(parallel[i].status).is(o.status)
			end
		end)

		test("each mutant is applied and restored inside one worker's own build", function()
			local deps, log = parallelDeps(2, TICKS, STATUS)
			Mutation.run(MUTANTS, deps)
			expect(#log.restoredBy).is(5)
			local restored = {}
			for _, path in log.restoredBy do
				restored[path] = (restored[path] or 0) + 1
			end
			for _, m in MUTANTS do
				local worker = log.appliedBy[m.id]
				expect(worker == 1 or worker == 2).is_true()
				expect(restored[`W{worker}/{m.file}`] ~= nil).is_true()
			end
		end)

		test("more jobs than mutants spawns only as many workers as needed", function()
			local deps, log = parallelDeps(8, TICKS, STATUS)
			local outcomes = Mutation.run({ MUTANTS[1], MUTANTS[2] }, deps)
			expect(#outcomes).is(2)
			expect(log.maxInFlight).is(2)
		end)

		test("a stop keeps a plan-order prefix: in-flight mutants finish, none are claimed after", function()
			local deps, log = parallelDeps(2, TICKS, STATUS)
			local stop = false
			deps.shouldStop = function()
				return stop
			end
			deps.progress = function()
				stop = true
			end
			local outcomes, stopped = Mutation.run(MUTANTS, deps)
			expect(stopped).is_true()
			-- Worker 2 finished mutant 2 first; worker 1 was still inside mutant 1.
			expect(#outcomes).is(2)
			expect(outcomes[1].mutant.id).is(1)
			expect(outcomes[2].mutant.id).is(2)
			expect(#log.restoredBy).is(2)
		end)

		test("a worker failure outside the per-mutant guard drains the others, then rethrows", function()
			local deps, log = parallelDeps(2, TICKS, STATUS)
			deps.readFile = function(path)
				if path == "W2/src/a.luau" then
					error("disk gone")
				end
				return "ORIGINAL:" .. path
			end
			local ok, err = pcall(Mutation.run, MUTANTS, deps)
			expect(ok).never_is_true()
			expect(tostring(err):find("disk gone", 1, true) ~= nil).is_true()
			-- Worker 1's in-flight mutant still finished and was restored.
			expect(log.restoredBy[1]).is("W1/src/a.luau")
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

	describe("Mutation.selectTests", function()
		-- src/a.luau: line 1 is module level; function 10 spans lines 2-4 (a stmt
		-- on 3, a decision on 4 with false slot 13); function 20 is on line 6 and
		-- its body stmt on line 7; line 9 holds a module-level statement and a
		-- one-line function. src/b.luau line 1 is module level too (another
		-- module initializing).
		local MAP = {
			files = {
				{
					path = "src/a.luau",
					probes = {
						{ id = 1, kind = "stmt", line = 1 },
						{ id = 10, kind = "fn", line = 2 },
						{ id = 11, kind = "stmt", line = 3, fn = 10 },
						{ id = 12, kind = "decision", line = 4, fn = 10, false_id = 13 },
						{ id = 20, kind = "fn", line = 6 },
						{ id = 21, kind = "stmt", line = 7, fn = 20 },
						-- line 9: `local f = function() return x + 1 end`
						{ id = 40, kind = "stmt", line = 9 },
						{ id = 41, kind = "fn", line = 9 },
						{ id = 42, kind = "stmt", line = 9, fn = 41 },
					},
				},
				{ path = "src/b.luau", probes = { { id = 30, kind = "stmt", line = 1 } } },
			},
		}
		local LOAD = { id = "<module load>", probes = { 1, 30 } }
		local T1 = { id = "S1 > one", probes = { 10, 11 } }
		local T2 = { id = "S1 > two", probes = { 20, 21 } }
		local T3 = { id = "S2 > three", probes = { 10, 12 } }
		local T4 = { id = "S2 > four", probes = {} }

		test("picks the tests that entered the mutant's function, in run order", function()
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 3) }, MAP, { LOAD, T3, T1, T2 })
			expect(sel[1]).is_shallow_equal { "S2 > three", "S1 > one" }
		end)

		test("the unit is the function: a test that entered it but skipped the line still runs", function()
			-- T1 never hit line 4's decision, but it entered function 10.
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 4) }, MAP, { T1, T2, T3 })
			expect(sel[1]).is_shallow_equal { "S1 > one", "S2 > three" }
		end)

		test("a module-level line runs the whole suite, even when a function shares it", function()
			local entered = { id = "S1 > f", probes = { 41, 42 } }
			local sel = Mutation.selectTests(
				{ mutant(1, "src/a.luau", 1), mutant(2, "src/a.luau", 9) },
				MAP,
				{ T1, entered }
			)
			expect(sel[1]).never_exists()
			expect(sel[2]).never_exists()
		end)

		test("a line with no probe, or a function no test entered, runs the whole suite", function()
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 99), mutant(2, "src/a.luau", 7) }, MAP, { T1 })
			expect(sel[1]).never_exists()
			expect(sel[2]).never_exists()
		end)

		test("without collect data, a function hit at <module load> runs the whole suite", function()
			local load = { id = "<module load>", probes = { 1, 10, 11 } }
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 3) }, MAP, { load, T1 })
			expect(sel[1]).never_exists()
		end)

		test("with collect data, a describe-time hit selects the whole spec that made it", function()
			local load = { id = "<module load>", probes = { 1, 10, 11 } }
			local collect = { outside = { 1 }, bySpec = { S2 = { 10, 11 } } }
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 3) }, MAP, { load, T1, T2, T3, T4 }, collect)
			-- T1 entered it at run time; S2's tests share the describe-level setup.
			expect(sel[1]).is_shallow_equal { "S1 > one", "S2 > three", "S2 > four" }
		end)

		test("a function hit outside any describe body (module init) runs the whole suite", function()
			local collect = { outside = { 1, 10 }, bySpec = {} }
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 3) }, MAP, { LOAD, T1 }, collect)
			expect(sel[1]).never_exists()
		end)

		test("a describe body that initialized a module runs the whole suite for what it hit", function()
			local collect = { outside = {}, bySpec = { S2 = { 30, 10 } } }
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 3) }, MAP, { T1, T3 }, collect)
			expect(sel[1]).never_exists()
		end)

		test("a test that initialized a module (lazy require) runs the whole suite for what it hit", function()
			local lazy = { id = "S1 > lazy", probes = { 13, 20, 21 } }
			local sel = Mutation.selectTests({ mutant(1, "src/a.luau", 7) }, MAP, { lazy, T2 })
			expect(sel[1]).is_shallow_equal { "S1 > lazy", "S1 > two" }
			local lazyInit = { id = "S1 > lazy", probes = { 30, 20, 21 } }
			expect(Mutation.selectTests({ mutant(1, "src/a.luau", 7) }, MAP, { lazyInit, T2 })[1]).never_exists()
		end)
	end)

	describe("Mutation.resume", function()
		local function record(m, status)
			return {
				id = m.id,
				site = m.site,
				replacement = m.replacement,
				status = status,
				duration = 0.5,
			}
		end

		test("skips decided mutants and keeps their outcomes", function()
			local planned = { mutant(1, "src/a.luau", 1), mutant(2, "src/a.luau", 2), mutant(3, "src/a.luau", 3) }
			local remaining, decided = Mutation.resume(planned, { record(planned[2], "survived") })
			expect(#remaining).is(2)
			expect(remaining[1].id).is(1)
			expect(remaining[2].id).is(3)
			expect(decided[2].status).is("survived")
			expect(decided[2].mutant).is(planned[2])
		end)

		test("a record whose site or replacement changed is run again", function()
			local m = mutant(1, "src/a.luau", 1)
			local moved = record(m, "killed")
			moved.site = "mut:ror:src/a.luau:2:1"
			local swapped = record(m, "killed")
			swapped.replacement = "<"
			local remaining = Mutation.resume({ m }, { moved, swapped })
			expect(#remaining).is(1)
		end)

		test("inPlanOrder merges resumed and new outcomes back into plan order", function()
			-- Plan order is not id order, so neither id nor completion order passes.
			local planned = { mutant(3, "src/a.luau", 1), mutant(1, "src/a.luau", 2), mutant(2, "src/a.luau", 3) }
			local decided = { [1] = outcomeOf("survived", planned[2]) }
			local all = Mutation.inPlanOrder(
				planned,
				decided,
				{ outcomeOf("killed", planned[3]), outcomeOf("killed", planned[1]) }
			)
			expect(#all).is(3)
			expect(all[1].mutant.id).is(3)
			expect(all[2].status).is("survived")
			expect(all[3].mutant.id).is(2)
		end)

		test("inPlanOrder leaves out mutants nothing decided (a stopped run)", function()
			local planned = { mutant(1, "src/a.luau", 1), mutant(2, "src/a.luau", 2) }
			local all = Mutation.inPlanOrder(planned, {}, { outcomeOf("killed", planned[1]) })
			expect(#all).is(1)
		end)
	end)
end
