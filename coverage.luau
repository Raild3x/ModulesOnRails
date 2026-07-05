--!strict
-- coverage — AST-instrumented test-coverage for the ModulesOnRails packages.
--
-- Thin CLI: parse args, load the repo adapter, hand off to the repo-agnostic
-- orchestrator core. This is the repo's test runner (tests.luau was removed).
--
-- Usage:
--   lune run coverage.luau package=<name>
--   lune run coverage.luau package=all
--   lune run coverage.luau package=last
--   lune run coverage.luau package=<name> --json --per-test --no-conditions
--   lune run coverage.luau package=<name> --rebuild-engine --timeout=120
--   lune run coverage.luau help

local process = require("@lune/process")

local defaultAdapter = require("./tools/coverage/lune/adapters/modules_on_rails")
local adapterMod = require("./tools/coverage/lune/adapter")
local Orchestrator = require("./tools/coverage/lune/core/Orchestrator")

type Options = {
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

local selector: string? = nil
local options: Options = {
	json = false,
	perTest = false,
	perFile = false,
	noConditions = false,
	suggestConst = false,
	rebuildEngine = false,
	timeout = nil,
	mutate = false,
	mutateLimit = nil,
	mutateOps = nil,
	mutateTimeout = nil,
	recommend = false,
}
local adapterPath: string? = nil

-- Single source of truth for CLI flags: parsing and `help` output both read
-- from this table, so they can't drift out of sync with each other.
type FlagSpec = {
	match: string, -- exact match for boolean flags, prefix for `key=`-style flags
	usage: string, -- display form shown in help text
	description: string,
	takesValue: boolean,
	apply: (value: string?) -> (),
}

local function parseNumberFlag(usage: string, value: string?): number
	local n = value and tonumber(value)
	if n == nil then
		print(("Invalid value for %s: expected a number, got %s"):format(usage, value or "<none>"))
		process.exit(1)
	end
	return n :: number
end

local FLAGS: { FlagSpec } = {
	{
		match = "--json",
		usage = "--json",
		description = "Emit machine-readable JSON coverage output instead of the human-readable report.",
		takesValue = false,
		apply = function()
			options.json = true
		end,
	},
	{
		match = "--per-test",
		usage = "--per-test",
		description = "Attribute coverage to the individual test that hit each line, instead of aggregating across the whole run.",
		takesValue = false,
		apply = function()
			options.perTest = true
		end,
	},
	{
		match = "--per-file",
		usage = "--per-file",
		description = "Show a per-file line-coverage breakdown (worst first) after the package totals.",
		takesValue = false,
		apply = function()
			options.perFile = true
		end,
	},
	{
		match = "--no-conditions",
		usage = "--no-conditions",
		description = "Skip branch/condition coverage; report line coverage only (faster, less detailed).",
		takesValue = false,
		apply = function()
			options.noConditions = true
		end,
	},
	{
		match = "--suggest-const",
		usage = "--suggest-const",
		description = "Report locals never reassigned that could be `const`. Off by default: adopting const moves a package onto the Roblox pipeline (Lune cannot parse const yet).",
		takesValue = false,
		apply = function()
			options.suggestConst = true
		end,
	},
	{
		match = "--mutate",
		usage = "--mutate",
		description = "After the coverage run, mutation-test the package: mutate the source, re-run the suite per mutant, and report which mutations the tests fail to detect. Lune-pipeline packages only.",
		takesValue = false,
		apply = function()
			options.mutate = true
		end,
	},
	{
		match = "--mutate-limit=",
		usage = "--mutate-limit=<n>",
		description = "Cap the number of mutants run (deterministic sampling spread across files). Default: run every mutant on a covered line.",
		takesValue = true,
		apply = function(value)
			options.mutateLimit = parseNumberFlag("--mutate-limit=<n>", value)
		end,
	},
	{
		match = "--mutate-ops=",
		usage = "--mutate-ops=<csv>",
		description = "Only run these mutation operators (comma-separated from: ror, lor, aor, not, lit).",
		takesValue = true,
		apply = function(value)
			options.mutateOps = value
		end,
	},
	{
		match = "--mutate-timeout=",
		usage = "--mutate-timeout=<sec>",
		description = "Per-mutant suite timeout; a hung mutant is killed and counted as detected. Default: 3x the baseline suite duration (min 5s).",
		takesValue = true,
		apply = function(value)
			options.mutateTimeout = parseNumberFlag("--mutate-timeout=<sec>", value)
		end,
	},
	{
		match = "--recommend",
		usage = "--recommend",
		description = "End the report with a ranked list of concrete next steps (mutation survivors, uncovered functions, one-sided decisions, ...).",
		takesValue = false,
		apply = function()
			options.recommend = true
		end,
	},
	{
		match = "--rebuild-engine",
		usage = "--rebuild-engine",
		description = "Force a fresh build of the Rust instrumentation engine before running, even if a cached binary exists.",
		takesValue = false,
		apply = function()
			options.rebuildEngine = true
		end,
	},
	{
		match = "--timeout=",
		usage = "--timeout=<sec>",
		description = "Maximum seconds to let the test run execute before aborting. Defaults to no timeout.",
		takesValue = true,
		apply = function(value)
			options.timeout = parseNumberFlag("--timeout=<sec>", value)
		end,
	},
	{
		match = "--adapter=",
		usage = "--adapter=<path>",
		description = "Load a repo adapter module from this path instead of the built-in ModulesOnRails adapter.",
		takesValue = true,
		apply = function(value)
			adapterPath = value
		end,
	},
}

local function findFlag(arg: string): (FlagSpec?, string?)
	for _, spec in FLAGS do
		if spec.takesValue then
			if arg:sub(1, #spec.match) == spec.match then
				return spec, arg:sub(#spec.match + 1)
			end
		elseif arg == spec.match then
			return spec, nil
		end
	end
	return nil, nil
end

local function printUsage()
	print("Usage:")
	print("  lune run coverage.luau package=<name> [flags]")
	print("  lune run coverage.luau package=all [flags]")
	print("  lune run coverage.luau package=last [flags]")
	print("  lune run coverage.luau help")
	print("")
	print("Package selector:")
	print("  package=<name>   Package under lib/<name> to measure coverage for.")
	print("  package=all      Run coverage for every package in the workspace.")
	print("  package=last     Re-run coverage for whichever package(s) ran last.")
	print("")
	print("Flags:")
	for _, spec in FLAGS do
		print(("  %-20s %s"):format(spec.usage, spec.description))
	end
end

local args = process.args or {}

for _, arg in args do
	if arg == "help" then
		printUsage()
		process.exit(0)
	elseif arg:sub(1, #"package=") == "package=" then
		selector = arg:sub(#"package=" + 1)
	else
		local spec, value = findFlag(arg)
		if spec then
			spec.apply(value)
		else
			print("Unknown argument: " .. arg)
			printUsage()
			process.exit(1)
		end
	end
end

if selector == nil or selector == "" then
	print("Missing required `package=<name>` (or `package=all` / `package=last`).")
	printUsage()
	process.exit(1)
end

local adapter
if adapterPath then
	local loaded: any = require(adapterPath) :: any
	adapter = adapterMod.validate(loaded)
else
	adapter = defaultAdapter
end

Orchestrator.run(adapter, selector :: string, options)
