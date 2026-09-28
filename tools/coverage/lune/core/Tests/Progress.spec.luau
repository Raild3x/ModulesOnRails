local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Progress = require("../Progress")

local function counts(k: number, s: number, t: number, e: number, i: number)
	return { killed = k, survived = s, timeout = t, error = e, invalid = i }
end

local function input(overrides: { [string]: any }?): any
	local base: { [string]: any } = {
		package = "pkg",
		phase = "mutating",
		startedAt = 1000,
		now = 1100,
		total = 50,
		resumed = 0,
		counts = counts(0, 0, 0, 0, 0),
		current = {},
		jobs = 4,
	}
	if overrides ~= nil then
		for key, value in overrides do
			base[key] = value
		end
	end
	return base
end

-- Scratch dir under the gitignored .coverage/, removed after each use.
local SCRATCH = ".coverage/_progress_spec"

local function withScratch(fn: (dir: string) -> ())
	if fs.isDir(SCRATCH) then
		fs.removeDir(SCRATCH)
	end
	fs.writeDir(SCRATCH)
	local ok, err = pcall(fn, SCRATCH)
	fs.removeDir(SCRATCH)
	if not ok then
		error(err, 0)
	end
end

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Progress.snapshot", function()
		test("counts every decided mutant and scores detected over run", function()
			local doc = Progress.snapshot(input { counts = counts(6, 2, 1, 1, 3) })
			expect(doc.done).is(13)
			expect(doc.killed).is(6)
			expect(doc.invalid).is(3)
			-- detected 8 of 10 run (invalid is not run)
			expect(doc.score).is(80)
			expect(doc.elapsed).is(100)
			expect(doc.heartbeat).is(1100)
		end)

		test("the eta extrapolates this run's pace over what is left", function()
			-- 10 done in 100s -> 10s each; 40 left
			local doc = Progress.snapshot(input { counts = counts(10, 0, 0, 0, 0) })
			expect(doc.eta_seconds).is(400)
		end)

		test("resumed mutants count as done but do not set the pace", function()
			-- 30 resumed + 10 run here in 100s -> 10s each; 10 left
			local doc = Progress.snapshot(input { counts = counts(35, 5, 0, 0, 0), resumed = 30 })
			expect(doc.done).is(40)
			expect(doc.resumed).is(30)
			expect(doc.eta_seconds).is(100)
		end)

		test("score and eta are absent before anything is decided", function()
			local doc = Progress.snapshot(input {})
			expect(doc.score).never_exists()
			expect(doc.eta_seconds).never_exists()
			expect(doc.current).never_exists()
		end)
	end)

	describe("Progress.line", function()
		test("one line with counts, score, elapsed, eta and the current files", function()
			local doc = Progress.snapshot(input {
				counts = counts(7, 3, 0, 0, 0),
				now = 1000 + 125,
				current = { "src/A.luau", "src/B.luau" },
			})
			expect(Progress.line(doc)).is(
				"[mutation] 10/50  killed 7  survived 3  timeout 0  error 0  score 70.0%  elapsed 2m05s  eta 8m20s  [src/A.luau, src/B.luau]"
			)
		end)

		test("hours show once a run is that long, and unknowns print as placeholders", function()
			local doc = Progress.snapshot(input { now = 1000 + 3 * 3600 + 7 * 60 })
			expect(Progress.line(doc)).is(
				"[mutation] 0/50  killed 0  survived 0  timeout 0  error 0  score -  elapsed 3h07m  eta ?"
			)
		end)
	end)

	describe("Progress files", function()
		test("writeAtomic leaves the whole new file and no temp file behind", function()
			withScratch(function(dir)
				local path = dir .. "/progress.json"
				fs.writeFile(path, "old contents that are longer than the new ones")
				Progress.writeAtomic(path, "new")
				expect(fs.readFile(path)).is("new")
				expect(fs.isFile(path .. ".tmp")).never_is_true()
			end)
		end)

		test("write then read round-trips the document", function()
			withScratch(function(dir)
				local path = dir .. "/progress.json"
				local doc = Progress.snapshot(input { counts = counts(1, 1, 0, 0, 0), current = { "src/A.luau" } })
				Progress.write(path, doc)
				local back = Progress.read(path) :: any
				expect(back).exists()
				expect(back.done).is(2)
				expect(back.current[1]).is("src/A.luau")
			end)
		end)

		test("read returns nil for a missing file, bad json, or another schema", function()
			withScratch(function(dir)
				expect(Progress.read(dir .. "/missing.json")).never_exists()
				fs.writeFile(dir .. "/bad.json", "{ not json")
				expect(Progress.read(dir .. "/bad.json")).never_exists()
				fs.writeFile(dir .. "/other.json", serde.encode("json", { schema = "something-else/1" }))
				expect(Progress.read(dir .. "/other.json")).never_exists()
			end)
		end)
	end)

	describe("Progress staleness", function()
		test("a running phase with an old heartbeat is stale; a fresh one is not", function()
			local doc = Progress.snapshot(input { now = 1000 })
			expect(Progress.isStale(doc, 1000 + Progress.STALE_SECONDS)).never_is_true()
			expect(Progress.isStale(doc, 1000 + Progress.STALE_SECONDS + 1)).is_true()
			local baseline = Progress.snapshot(input { phase = "baseline", now = 1000 })
			expect(Progress.isStale(baseline, 5000)).is_true()
		end)

		test("a finished run is never stale", function()
			for _, phase in { "done", "stopped", "failed" } do
				local doc = Progress.snapshot(input { phase = phase, now = 1000 })
				expect(Progress.isStale(doc, 99999)).never_is_true()
			end
		end)

		test("describe flags a dead run and still shows its last counts", function()
			local doc = Progress.snapshot(input { now = 1000, counts = counts(1, 0, 0, 0, 0) })
			local text = Progress.describe(doc, 1100)
			expect(text:find("DEAD? (mutating, no heartbeat for 100s)", 1, true)).exists()
			expect(text:find("[mutation] 1/50", 1, true)).exists()
			expect(Progress.describe(doc, 1005):find("DEAD", 1, true)).never_exists()
		end)
	end)
end
