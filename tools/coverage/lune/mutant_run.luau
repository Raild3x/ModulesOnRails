--!strict
--[=[
	Mutation-testing child entry: runs a package's spec suite (uninstrumented,
	no coverage plugin) in a fresh Lune process and reports the tally on one
	sentinel stdout line. A fresh process per mutant is what makes mutation runs
	correct: Lune's require cache is keyed by resolved path (the mutated file at
	the same path would come back cached in-process), and a busy-looping mutant
	can only be stopped by killing the process from outside.

	Usage (spawned by core/Orchestrator, not by hand):
	  lune run tools/coverage/lune/mutant_run.luau buildDir=<dir> sourceRoot=<src> [tests=<json>] [failFast=1]

	`tests=` names a JSON array of test ids (labels joined by " > "); only those
	tests run, in collection order. Every spec is still collected, so
	require-time and describe-time code runs exactly as in a full run.
	`failFast=1` reports and exits at the first failing test: one failure is
	enough to kill a mutant.

	Output: `[[TM-MUT]]{"pass":N,"fail":N,"skipped":N}` on success; a missing
	sentinel or nonzero exit means the suite itself crashed (the parent
	classifies that mutant as an error, which counts as detected).
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

-- Require paths resolve relative to THIS file; repo root is three levels up
-- from tools/coverage/lune/. Spec collection paths are cwd-relative (the
-- orchestrator spawns us from the repo root).
local ROOT = "../../../"

local buildDir: string? = nil
local sourceRoot = "src"
local testsFile: string? = nil
local failFast = false
for _, arg in process.args or {} do
	if arg:sub(1, #"buildDir=") == "buildDir=" then
		buildDir = arg:sub(#"buildDir=" + 1)
	elseif arg:sub(1, #"sourceRoot=") == "sourceRoot=" then
		sourceRoot = arg:sub(#"sourceRoot=" + 1)
	elseif arg:sub(1, #"tests=") == "tests=" then
		testsFile = arg:sub(#"tests=" + 1)
	elseif arg == "failFast=1" then
		failFast = true
	end
end
assert(buildDir ~= nil and buildDir ~= "", "mutant_run: missing buildDir=<dir>")

-- Mirrors LuneRunner's spec collection (skip _Index, match *.spec.luau).
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

local dynRequire: any = require

local function sentinel(tally: { pass: number, fail: number, skipped: number })
	stdio.write("[[TM-MUT]]" .. serde.encode("json", tally) .. "\n")
end

-- Fail fast: the first failing test decides the mutant, so report and exit.
local passed = 0
local failFastPlugin = {
	is_tiniest_plugin = true,
	after_test = function(_test: any, result: any)
		if result.status ~= "pass" then
			sentinel { pass = passed, fail = 1, skipped = 0 }
			process.exit(0)
		end
		passed += 1
	end,
}

local tiniest = dynRequire(ROOT .. "test/tiniest/tiniest_for_lune").configure {
	snapshot_path = "./test/__snapshots__",
	save_snapshots = false,
	plugins = if failFast then { failFastPlugin } else nil,
	pretty = {
		trim_duplicate_trace = true,
		hide_passed_tests = true,
	},
}

local specFiles: { string } = {}
collectSpecs((buildDir :: string) .. "/" .. sourceRoot, specFiles)

-- Label specs relative to the build dir (e.g. "src/Tests/X.spec"), exactly as LuneRunner
-- does: tiniest snapshot keys are derived from test labels, so a different label here makes
-- every snapshot() look new and turns the mutation baseline red.
local buildPrefix = (buildDir :: string) .. "/"
local tests = tiniest.collect_tests(function()
	local describe = tiniest.describe
	for _, file in specFiles do
		local requirePath = ROOT .. (file:gsub("%.luau$", ""))
		local label = (file:gsub("^" .. buildPrefix:gsub("([%-%.%+])", "%%%1"), ""):gsub("%.luau$", ""))
		describe(label, function()
			dynRequire(requirePath)(tiniest)
		end)
	end
end)

if testsFile ~= nil then
	local wanted: { [string]: boolean } = {}
	for _, id in serde.decode("json", fs.readFile(testsFile)) do
		wanted[id] = true
	end
	local kept = {}
	for _, t in tests do
		if wanted[table.concat(t.labels, " > ")] then
			table.insert(kept, t)
		end
	end
	tests = kept
end

local results = tiniest.run_tests(tests, { safe_mode = true })

sentinel(results.status_tally)
