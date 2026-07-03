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
	recommend: boolean?,
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
	with a `task.delay` watchdog. Returns the summary embedded in coverage.json,
	or nil when the phase could not run.
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
	local plan = Mutation.plan(Mutation.flatten(mutantsDoc), coveredLines, {
		ops = parseOpsCsv(options.mutateOps),
		limit = options.mutateLimit,
	})

	-- Poll-based watchdog: task.delay + task.cancel leaves Lune's scheduler
	-- waiting out the full delay after the work is done (the process lingers at
	-- exit for minutes), so the wait/kill decision is a task.wait poll instead —
	-- nothing outlives the child.
	local function runSuite(timeoutSec: number?): Mutation.ChildOutcome
		local start = os.clock()
		local child = process.create("lune", {
			"run",
			MUTANT_RUN_SCRIPT,
			"buildDir=" .. mutBuild,
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
	local baseline = runSuite(options.mutateTimeout or BASELINE_TIMEOUT_SECONDS)
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

	local loopStart = os.clock()
	local outcomes, stopped = Mutation.run(plan.toRun, {
		filePath = function(rel: string)
			return mutBuild .. "/" .. rel
		end,
		readFile = fs.readFile,
		writeFile = fs.writeFile,
		applyMutant = function(id: number)
			return Engine.applyMutant(mutantsPath, id, mutBuild)
		end,
		runSuite = function()
			return runSuite(timeoutSec)
		end,
		progress = function(index: number, total: number, outcome: Mutation.MutantOutcome)
			local elapsed = os.clock() - loopStart
			local eta = elapsed / index * (total - index)
			print(string.format(
				"[mutation] %d/%d  %-8s %s:%d %s  (%.1fs, ~%.0fs left)",
				index,
				total,
				outcome.status,
				outcome.mutant.file,
				outcome.mutant.line,
				outcome.mutant.op,
				outcome.duration,
				eta
			))
		end,
		shouldStop = function()
			return fs.isFile(stopPath)
		end,
	})
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

function Orchestrator.run(adapter: RepoAdapter, selector: string, options: Options)
	Engine.ensure(options.rebuildEngine)

	local specs = adapter.resolvePackages(selector)
	if #specs == 0 then
		print("No auditable packages found.")
		return
	end

	local jsonResults: { any } = {}

	for _, spec in specs do
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
			env = "roblox-edit"
			run = RobloxRunner.run(adapter, spec, buildDir, workDir, { perTest = options.perTest })
		else
			env = "lune"
			run = LuneRunner.run(spec, buildDir, { timeout = options.timeout })
		end
		writeHits(hitsOut, spec, env, run)

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
end

return Orchestrator
