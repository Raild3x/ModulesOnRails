--!strict
--[=[
	Mutation-testing child entry: runs a package's spec suite (uninstrumented,
	no coverage plugin) in a fresh Lune process and reports the tally on one
	sentinel stdout line. A fresh process per mutant is what makes mutation runs
	correct: Lune's require cache is keyed by resolved path (the mutated file at
	the same path would come back cached in-process), and a busy-looping mutant
	can only be stopped by killing the process from outside.

	Usage (spawned by core/Orchestrator, not by hand):
	  lune run tools/coverage/lune/mutant_run.luau buildDir=<dir> sourceRoot=<src>

	Output: `[[TM-MUT]]{"pass":N,"fail":N,"skipped":N}` on success; a missing
	sentinel or nonzero exit means the suite itself crashed (the parent
	classifies that mutant as an error, which counts as detected).
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

-- Require paths resolve relative to THIS file; repo root is three levels up
-- from tools/coverage/lune/. Spec collection paths are cwd-relative (the
-- orchestrator spawns us from the repo root).
local ROOT = "../../../"

local buildDir: string? = nil
local sourceRoot = "src"
for _, arg in process.args or {} do
	if arg:sub(1, #"buildDir=") == "buildDir=" then
		buildDir = arg:sub(#"buildDir=" + 1)
	elseif arg:sub(1, #"sourceRoot=") == "sourceRoot=" then
		sourceRoot = arg:sub(#"sourceRoot=" + 1)
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

local tiniest = dynRequire(ROOT .. "test/tiniest/tiniest_for_lune").configure {
	snapshot_path = "./test/__snapshots__",
	save_snapshots = false,
	pretty = {
		trim_duplicate_trace = true,
		hide_passed_tests = true,
	},
}

local specFiles: { string } = {}
collectSpecs((buildDir :: string) .. "/" .. sourceRoot, specFiles)

local tests = tiniest.collect_tests(function()
	local describe = tiniest.describe
	for _, file in specFiles do
		local requirePath = ROOT .. (file:gsub("%.luau$", ""))
		describe(file, function()
			dynRequire(requirePath)(tiniest)
		end)
	end
end)

local results = tiniest.run_tests(tests, { safe_mode = true })

print("[[TM-MUT]]" .. serde.encode("json", results.status_tally))
