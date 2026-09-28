--!strict
--[=[
	Runs a package's instrumented spec suite in-process under Lune, using
	`tiniest_for_lune` with the coverage plugin attached. Spec collection is
	rooted at the materialized build dir, so each spec's own relative requires
	resolve to the instrumented sources.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")

local tiniest_coverage = require("@tiniest/tiniest_coverage")

local adapter = require("../adapter")
type PackageSpec = adapter.PackageSpec

-- Require paths are resolved relative to THIS file. Repo root is four levels up
-- from tools/coverage/lune/core/.
local ROOT = "../../../../"

local LuneRunner = {}

export type RunOutput = {
	coverage: tiniest_coverage.CoverageResult,
	tally: { pass: number, fail: number, skipped: number },
	duration: number,
}

local function collectSpecs(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			if entry ~= "_Index" then
				collectSpecs(full, out)
			end
		elseif entry:match("%.spec%.luau$") then
			table.insert(out, full)
		end
	end
end

-- Probe hits while collecting, for mutation test selection (Mutation.Collect):
-- inside each spec's describe bodies, and everywhere else (module init, spec top level).
export type Collect = { outside: { number }, bySpec: { [string]: { number } } }

--[=[
	Runs the instrumented suite in `buildDir`. Returns coverage + tally, and the
	collect-time hits.
]=]
function LuneRunner.run(spec: PackageSpec, buildDir: string, options: { timeout: number? }?): (RunOutput, Collect)
	local dynRequire: any = require

	-- The emitted runtime module (same cached instance the instrumented
	-- sources require, since Lune caches by resolved path).
	local covPath = ROOT .. buildDir .. "/" .. spec.sourceRoot .. "/_cov"
	local runtime = dynRequire(covPath)

	local coveragePlugin = tiniest_coverage.configure {
		runtime = runtime,
		enable_per_test = true,
	}

	local tiniest = dynRequire(ROOT .. "test/tiniest/tiniest_for_lune").configure {
		snapshot_path = "./test/__snapshots__",
		-- Opt-in only: `SAVE_SNAPSHOTS=1` writes new/changed snapshots to disk. Never set in CI;
		-- mutant_run stays read-only so a mutant can never overwrite a golden.
		save_snapshots = process.env.SAVE_SNAPSHOTS == "1",
		plugins = { coveragePlugin },
		pretty = {
			trim_duplicate_trace = true,
			hide_passed_tests = false,
		},
	}

	local specFiles: { string } = {}
	collectSpecs(buildDir .. "/" .. spec.sourceRoot, specFiles)

	-- Collect-time attribution: specs get a tiniest whose `describe` drains the
	-- counters on entering and leaving each top-level describe body, so setup done
	-- there is filed under that spec and everything else under `outside`. Its own
	-- baseline leaves the plugin's per-test deltas untouched.
	local collectBaseline = runtime.new_baseline()
	local outside: { number } = {}
	local bySpec: { [string]: { number } } = {}
	local currentSpec = ""
	local depth = 0
	local function drain(into: { number })
		for _, id in runtime.delta(collectBaseline) do
			table.insert(into, id)
		end
	end
	local specApi = setmetatable({
		describe = function(label: string, inner: (...any) -> ())
			tiniest.describe(label, function(...)
				if depth == 0 then
					drain(outside)
				end
				depth += 1
				inner(...)
				depth -= 1
				if depth == 0 then
					bySpec[currentSpec] = bySpec[currentSpec] or {}
					drain(bySpec[currentSpec])
				end
			end)
		end,
	}, { __index = tiniest })

	local buildPrefix = buildDir .. "/"
	local tests = tiniest.collect_tests(function()
		local describe = tiniest.describe
		for _, file in specFiles do
			local requirePath = ROOT .. (file:gsub("%.luau$", ""))
			-- Label with the spec path relative to the build dir (drop the
			-- ".coverage/<pkg>/build/" prefix and ".luau" suffix).
			local label = (file:gsub("^" .. buildPrefix:gsub("([%-%.%+])", "%%%1"), ""):gsub("%.luau$", ""))
			describe(label, function()
				currentSpec = label
				dynRequire(requirePath)(specApi)
			end)
		end
	end)
	drain(outside)

	local runOptions: any = { safe_mode = true }
	if options and options.timeout then
		runOptions.timeout_seconds = options.timeout
	end

	local start = os.clock()
	local result = tiniest.run_tests(tests, runOptions)
	local duration = os.clock() - start

	return {
		coverage = result.coverage,
		tally = result.status_tally,
		duration = duration,
	}, { outside = outside, bySpec = bySpec }
end

return LuneRunner
