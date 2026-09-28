--!strict
--[=[
	Drives the whole coverage flow per package: resolve -> materialize ->
	instrument -> run -> merge -> report. Repo knowledge comes entirely from the
	injected adapter; this module is repo-agnostic.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local adapterMod = require("../adapter")
local Engine = require("./Engine")
local LuneRunner = require("./LuneRunner")
local RobloxRunner = require("./RobloxRunner")
local OpenCloudRunner = require("./OpenCloudRunner")
local OpenCloud = require("../../../ci/OpenCloud")
local Merge = require("./Merge")
local Mutation = require("./Mutation")
local Recommend = require("./Recommend")
local Report = require("./Report")
local CoverageJson = require("./CoverageJson")
local Ignore = require("./Ignore")

type RepoAdapter = adapterMod.RepoAdapter
type PackageSpec = adapterMod.PackageSpec

local Orchestrator = {}

export type Options = {
	json: boolean?,
	perTest: boolean?,
	perFile: boolean?,
	noConditions: boolean?,
	suggestConst: boolean?,
	rebuildEngine: boolean?,
	timeout: number?,
	mutate: boolean?,
	mutateLimit: number?,
	mutateOps: string?,
	mutateTimeout: number?,
	-- Mutants run on this many parallel workers, each in its own build copy.
	mutateJobs: number?,
	-- Comma-separated package-relative paths/globs; only their mutants are run.
	mutateFiles: string?,
	recommend: boolean?,
	luneOnly: boolean?,
	-- Skip Lune-pipeline packages; run only Roblox-pipeline ones (mirror of
	-- luneOnly). Intended for the CI job that runs on real Roblox via Open Cloud.
	robloxOnly: boolean?,
	-- Which transport to use for Roblox-pipeline packages: "opencloud" (real
	-- Roblox via Open Cloud) or "studio" (local Studio via run-in-roblox). When
	-- nil, defaults to "opencloud" if an Open Cloud API key is configured, else
	-- "studio".
	robloxRunner: string?,
}

export type RunSummary = {
	-- Total failing tests across every suite that ran.
	failedTests: number,
	-- Packages skipped because --lune-only excluded their pipeline.
	skippedPackages: number,
}

local HITS_SCHEMA = "tm-coverage-hits/1"
local MUTATION_SCHEMA = "tm-coverage-mutation/1"
local MUTANT_RUN_SCRIPT = "tools/coverage/lune/mutant_run.luau"
-- Baseline watchdog when no --mutate-timeout is given; per-mutant runs then
-- use 3x the observed baseline duration.
local BASELINE_TIMEOUT_SECONDS = 300

local function writeHits(path: string, spec: PackageSpec, env: string, run: LuneRunner.RunOutput)
	local cov = run.coverage
	local perTest = cov.per_test
	local hitsDoc = {
		schema = HITS_SCHEMA,
		package = spec.name,
		map_sha = cov.map_sha,
		run = {
			env = env,
			duration = run.duration,
			status_tally = run.tally,
		},
		hits = cov.hits,
		per_test = perTest,
	}
	fs.writeFile(path, serde.encode("json", hitsDoc, true))
end

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

-- Logical CPU count, read without spawning a process: Windows exports it in
-- the environment and Linux lists each processor in /proc/cpuinfo. nil
-- elsewhere (macOS).
local function logicalCores(): number?
	local fromEnv = tonumber(process.env.NUMBER_OF_PROCESSORS)
	if fromEnv ~= nil then
		return fromEnv
	end
	if fs.isFile("/proc/cpuinfo") then
		local count = 0
		for _ in ("\n" .. fs.readFile("/proc/cpuinfo")):gmatch("\nprocessor%s*:") do
			count += 1
		end
		return if count > 0 then count else nil
	end
	return nil
end

-- Default --mutate-jobs: half the logical cores (about one worker per physical
-- core on SMT machines), or 1 when the count is unknown.
local function defaultMutateJobs(): number
	local cores = logicalCores()
	return if cores ~= nil then math.max(1, cores // 2) else 1
end

local function parseOpsCsv(csv: string?): { [string]: boolean }?
	if csv == nil or csv == "" then
		return nil
	end
	local set: { [string]: boolean } = {}
	for op in csv:gmatch("[^,%s]+") do
		set[op] = true
	end
	return set
end

--[=[
	Runs the whole mutation phase for one (Lune-pipeline) package: enumerate
	mutants against a pristine copy, plan against the coverage just measured,
	then per mutant apply -> child suite run -> restore. Each mutant gets a
	fresh `lune` process (cold require cache, and a hung mutant can be killed)
	with a polled timeout. With `--mutate-jobs=<n>`, n workers run mutants
	concurrently, each in its own pristine copy (`mutbuild/`, `mutbuild-2/`, ...),
	and the extra copies are deleted afterwards. Returns the summary embedded in
	coverage.json, or nil when the phase could not run.
]=]
local function runMutation(
	adapter: RepoAdapter,
	spec: PackageSpec,
	workDir: string,
	merged: Merge.Merged,
	options: Options
): { [string]: any }?
	local mutBuild = workDir .. "/mutbuild"
	local mutantsPath = workDir .. "/mutants.json"
	adapter.materialize(spec, mutBuild)
	Engine.mutate(spec, mutBuild, mutantsPath)

	local mutantsDoc = serde.decode("json", fs.readFile(mutantsPath))
	local coveredLines: { [string]: { [number]: boolean } } = {}
	for _, f in merged.files do
		coveredLines[f.path] = f.coveredLines or {}
	end
	local fileGlobs = Mutation.parseFileGlobs(options.mutateFiles)
	local plan = Mutation.plan(Mutation.flatten(mutantsDoc), coveredLines, {
		ops = parseOpsCsv(options.mutateOps),
		limit = options.mutateLimit,
		ignoredFiles = merged.ignoredFiles,
		files = fileGlobs,
	})
	if fileGlobs ~= nil and #plan.toRun + #plan.noCoverage == 0 then
		print(
			`[mutation] warning: --mutate-files={options.mutateFiles} matched no mutants (paths are package-relative, e.g. src/Foo.luau)`
		)
	end

	-- Worker 1 mutates the historical `mutbuild/`; workers 2..n get copies.
	local jobs = math.max(1, math.min(options.mutateJobs or defaultMutateJobs(), #plan.toRun))
	local function workerBuild(worker: number): string
		return if worker == 1 then mutBuild else `{mutBuild}-{worker}`
	end
	local function removeWorkerCopies()
		for _, entry in fs.readDir(workDir) do
			if entry:match("^mutbuild%-%d+$") then
				fs.removeDir(`{workDir}/{entry}`)
			end
		end
	end

	-- Poll-based watchdog: task.delay + task.cancel leaves Lune's scheduler
	-- waiting out the full delay after the work is done (the process lingers at
	-- exit for minutes), so the wait/kill decision is a task.wait poll instead —
	-- nothing outlives the child. Parallel workers each poll their own child.
	local function runSuite(timeoutSec: number?, buildDir: string): Mutation.ChildOutcome
		local start = os.clock()
		local child = process.create("lune", {
			"run",
			MUTANT_RUN_SCRIPT,
			"buildDir=" .. buildDir,
			"sourceRoot=" .. spec.sourceRoot,
		})
		local timedOut = false
		local done = false
		local stdout = ""
		local exitOk = false
		task.spawn(function()
			-- readToEnd yields until the child exits (or is killed below); the
			-- mutated file must not be restored while the child can still run.
			stdout = child.stdout:readToEnd()
			local status = child:status()
			exitOk = status.ok
			done = true
		end)
		while not done do
			task.wait(0.05)
			if timeoutSec ~= nil and not timedOut and os.clock() - start > timeoutSec then
				timedOut = true
				pcall(function()
					child:kill()
				end)
			end
		end
		return {
			timedOut = timedOut,
			ok = exitOk,
			tally = Mutation.parseSentinel(stdout, function(json)
				return serde.decode("json", json)
			end),
			duration = os.clock() - start,
		}
	end

	print(`[mutation] {spec.name}: baseline run (unmutated)...`)
	local baseline = runSuite(options.mutateTimeout or BASELINE_TIMEOUT_SECONDS, mutBuild)
	local baseTally = baseline.tally
	if not baseline.ok or baseTally == nil or baseTally.fail > 0 then
		print("[mutation] baseline suite is not green -- skipping mutation; scores on a red suite are meaningless")
		return nil
	end

	local timeoutSec = options.mutateTimeout or math.max(5, 3 * baseline.duration)
	print(
		`[mutation] {#plan.toRun} mutant(s) to run; {#plan.noCoverage} on uncovered lines, {#plan.sampledOut} over the --mutate-limit budget`
	)

	-- Early exit: touching this file stops the loop after the current mutant;
	-- everything run so far is still summarized and written out.
	local stopPath = workDir .. "/mutation.stop"
	if fs.isFile(stopPath) then
		fs.removeFile(stopPath) -- stale from a previous run
	end
	print(`[mutation] to stop early and keep partial results: create {stopPath}`)

	-- Stale copies from an interrupted run would be harmless but waste disk.
	removeWorkerCopies()
	for worker = 2, jobs do
		fs.copy(mutBuild, workerBuild(worker))
	end
	local jobsNote = if options.mutateJobs == nil then " (default; set --mutate-jobs=<n>)" else ""
	print(`[mutation] running on {jobs} worker(s){jobsNote}`)

	local loopStart = os.clock()
	local outcomes: { Mutation.MutantOutcome }, stopped = {}, false
	local deps: Mutation.RunDeps = {
		jobs = jobs,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		wait = function()
			task.wait(0.05)
		end,
		filePath = function(rel: string, worker: number)
			return workerBuild(worker) .. "/" .. rel
		end,
		readFile = fs.readFile,
		writeFile = fs.writeFile,
		applyMutant = function(id: number, worker: number)
			return Engine.applyMutant(mutantsPath, id, workerBuild(worker))
		end,
		runSuite = function(worker: number)
			return runSuite(timeoutSec, workerBuild(worker))
		end,
		progress = function(completed: number, total: number, outcome: Mutation.MutantOutcome)
			local elapsed = os.clock() - loopStart
			local eta = elapsed / completed * (total - completed)
			print(
				string.format(
					"[mutation] %d/%d  %-8s %s:%d %s  (%.1fs, ~%.0fs left)",
					completed,
					total,
					outcome.status,
					outcome.mutant.file,
					outcome.mutant.line,
					outcome.mutant.op,
					outcome.duration,
					eta
				)
			)
		end,
		shouldStop = function()
			return fs.isFile(stopPath)
		end,
	}
	local ok, err = pcall(function()
		outcomes, stopped = Mutation.run(plan.toRun, deps)
	end)
	-- The copies go even when the loop threw; worker 1's mutbuild/ stays pristine.
	removeWorkerCopies()
	if not ok then
		error(err, 0)
	end
	if stopped then
		fs.removeFile(stopPath)
		print(`[mutation] stopped early via {stopPath}; summarizing the {#outcomes} mutant(s) already run`)
	end

	local totals = Mutation.summarize(plan, outcomes)
	local survivors = Mutation.survivors(outcomes)

	local records = {}
	for _, o in outcomes do
		table.insert(records, {
			id = o.mutant.id,
			op = o.mutant.op,
			file = o.mutant.file,
			line = o.mutant.line,
			original = o.mutant.original,
			replacement = o.mutant.replacement,
			site = o.mutant.site,
			status = o.status,
			duration = o.duration,
		})
	end
	fs.writeFile(
		workDir .. "/mutation.json",
		serde.encode("json", {
			schema = MUTATION_SCHEMA,
			package = spec.name,
			baseline = {
				pass = baseTally.pass,
				fail = baseTally.fail,
				skipped = baseTally.skipped,
				duration = baseline.duration,
			},
			totals = totals,
			mutants = records,
		}, true)
	)

	Report.mutation(spec.name, totals, survivors)

	local survivorDocs = {}
	for _, s in survivors do
		table.insert(survivorDocs, {
			file = s.file,
			line = s.line,
			op = s.op,
			original = s.original,
			replacement = s.replacement,
			site = s.site,
		})
	end
	return { totals = totals, survivors = survivorDocs }
end

function Orchestrator.run(adapter: RepoAdapter, selector: string, options: Options): RunSummary
	Engine.ensure(options.rebuildEngine)

	local summary: RunSummary = { failedTests = 0, skippedPackages = 0 }

	local specs = adapter.resolvePackages(selector)
	if #specs == 0 then
		print("No auditable packages found.")
		return summary
	end

	local jsonResults: { any } = {}

	for _, spec in specs do
		if spec.skipReason ~= nil then
			print(`[coverage] skipped {spec.name} ({spec.skipReason})`)
			summary.skippedPackages += 1
			continue
		end
		if options.luneOnly and spec.pipeline ~= "lune" then
			print(`[coverage] skipped {spec.name} (--lune-only; {spec.pipelineReason})`)
			summary.skippedPackages += 1
			continue
		end
		if options.robloxOnly and spec.pipeline ~= "roblox" then
			print(`[coverage] skipped {spec.name} (--roblox-only; {spec.pipelineReason})`)
			summary.skippedPackages += 1
			continue
		end

		local workDir = adapter.workDir(spec)
		ensureDir(workDir)
		local buildDir = workDir .. "/build"
		local mapOut = workDir .. "/map.json"
		local hitsOut = workDir .. "/hits.json"

		adapter.materialize(spec, buildDir)
		Engine.instrument(spec, buildDir, mapOut, options.noConditions, options.suggestConst)

		local env: string
		local run: LuneRunner.RunOutput
		if spec.pipeline == "roblox" then
			local runner = options.robloxRunner
			if runner == nil then
				runner = if OpenCloud.isConfigured() then "opencloud" else "studio"
			end
			if runner == "opencloud" then
				env = "roblox-opencloud"
				run = OpenCloudRunner.run(adapter, spec, buildDir, workDir, { perTest = options.perTest })
			else
				env = "roblox-edit"
				run = RobloxRunner.run(adapter, spec, buildDir, workDir, { perTest = options.perTest })
			end
		else
			env = "lune"
			run = LuneRunner.run(spec, buildDir, { timeout = options.timeout })
		end
		writeHits(hitsOut, spec, env, run)
		summary.failedTests += run.tally.fail

		local rules = Ignore.load(spec.root, spec.ignoreFiles)
		local merged = Merge.merge(mapOut, run.coverage, rules)
		Report.console(merged, {
			pipeline = spec.pipeline,
			pipelineReason = spec.pipelineReason,
			tally = run.tally,
			duration = run.duration,
			perFile = options.perFile,
		})

		local mutationSummary: { [string]: any }? = nil
		if options.mutate then
			if spec.pipeline == "roblox" then
				print(
					`[mutation] skipped for {spec.name} ({spec.pipelineReason}): the Studio pipeline would need one Studio launch per mutant`
				)
			else
				mutationSummary = runMutation(adapter, spec, workDir, merged, options)
			end
		end

		local recs: { Recommend.Recommendation }? = nil
		local recsTotal = 0
		if options.recommend then
			recs, recsTotal = Recommend.build(merged, {
				tally = run.tally,
				survivors = if mutationSummary ~= nil then mutationSummary.survivors else nil,
			})
			Report.recommendations(recs :: { Recommend.Recommendation }, recsTotal)
		end

		local doc = CoverageJson.build(merged, {
			classification = spec.pipeline,
			classificationReason = spec.pipelineReason,
			env = env,
			duration = run.duration,
			tally = run.tally,
		}, if options.perTest then run.coverage.per_test else nil)
		if mutationSummary ~= nil then
			doc.mutation = mutationSummary
		end
		if recs ~= nil then
			doc.recommendations = recs
		end
		CoverageJson.write(workDir .. "/coverage.json", doc)

		if options.json then
			table.insert(jsonResults, doc)
		end
	end

	if options.json then
		print(serde.encode("json", jsonResults, true))
	end

	return summary
end

return Orchestrator
