--!strict
--[=[
	@module core/Orchestrator

	Drives the whole coverage flow per package: resolve -> materialize ->
	instrument -> run -> merge -> report. Repo knowledge comes entirely from the
	injected adapter; this module is repo-agnostic.
]=]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local adapterMod = require("../adapter")
local Engine = require("./Engine")
local LuneRunner = require("./LuneRunner")
local RobloxRunner = require("./RobloxRunner")
local Merge = require("./Merge")
local Report = require("./Report")
local CoverageJson = require("./CoverageJson")

type RepoAdapter = adapterMod.RepoAdapter
type PackageSpec = adapterMod.PackageSpec

local Orchestrator = {}

export type Options = {
	json: boolean?,
	perTest: boolean?,
	noConditions: boolean?,
	rebuildEngine: boolean?,
	timeout: number?,
}

local HITS_SCHEMA = "tm-coverage-hits/1"

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
		Engine.instrument(spec, buildDir, mapOut, options.noConditions)

		local env: string
		local run: LuneRunner.RunOutput
		if spec.pipeline == "roblox" then
			env = "roblox-edit"
			run = RobloxRunner.run(adapter, spec, buildDir, workDir)
		else
			env = "lune"
			run = LuneRunner.run(spec, buildDir, { timeout = options.timeout })
		end
		writeHits(hitsOut, spec, env, run)

		local merged = Merge.merge(mapOut, run.coverage)
		Report.console(merged, {
			pipeline = spec.pipeline,
			pipelineReason = spec.pipelineReason,
			tally = run.tally,
			duration = run.duration,
		})

		local doc = CoverageJson.build(merged, {
			classification = spec.pipeline,
			classificationReason = spec.pipelineReason,
			env = env,
			duration = run.duration,
			tally = run.tally,
		}, if options.perTest then run.coverage.per_test else nil)
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
