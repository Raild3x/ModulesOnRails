--!strict
-- coverage — AST-instrumented test-coverage for the ModulesOnRails packages.
--
-- Thin CLI: parse args, load the repo adapter, hand off to the repo-agnostic
-- orchestrator core. Mirrors tests.luau's CLI shape.
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

local function printUsage()
	print("Usage:")
	print("  lune run coverage.luau package=<name>")
	print("  lune run coverage.luau package=all")
	print("  lune run coverage.luau package=last")
	print("  Flags: --json --per-test --no-conditions --rebuild-engine --timeout=<sec> --adapter=<path>")
	print("  lune run coverage.luau help")
end

local args = process.args or {}

local selector: string? = nil
local options = {
	json = false,
	perTest = false,
	noConditions = false,
	rebuildEngine = false,
	timeout = nil :: number?,
}
local adapterPath: string? = nil

for _, arg in args do
	if arg == "help" then
		printUsage()
		process.exit(0)
	elseif arg == "--json" then
		options.json = true
	elseif arg == "--per-test" then
		options.perTest = true
	elseif arg == "--no-conditions" then
		options.noConditions = true
	elseif arg == "--rebuild-engine" then
		options.rebuildEngine = true
	elseif arg:sub(1, #"--timeout=") == "--timeout=" then
		options.timeout = tonumber(arg:sub(#"--timeout=" + 1))
	elseif arg:sub(1, #"--adapter=") == "--adapter=" then
		adapterPath = arg:sub(#"--adapter=" + 1)
	elseif arg:sub(1, #"package=") == "package=" then
		selector = arg:sub(#"package=" + 1)
	else
		print("Unknown argument: " .. arg)
		printUsage()
		process.exit(1)
	end
end

if selector == nil or selector == "" then
	print("Missing required `package=<name>` (or `package=all` / `package=last`).")
	printUsage()
	process.exit(1)
end

local adapter
if adapterPath then
	local loaded: any = require(adapterPath)
	adapter = adapterMod.validate(loaded)
else
	adapter = defaultAdapter
end

Orchestrator.run(adapter, selector :: string, options)
