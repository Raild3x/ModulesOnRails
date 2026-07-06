--!strict
--[=[
	tools/ci/run_tests.luau

	Standalone "run the specs on real Roblox" entry point, independent of the
	coverage system. Builds a plain (uninstrumented) test place from every package
	under lib/, runs it via Open Cloud (`OpenCloud.execute`), streams the tiniest
	report, and exits non-zero if the run did not complete successfully.

	Usage (from the repo root):
		ROBLOX_API_KEY=... ROBLOX_UNIVERSE_ID=... ROBLOX_PLACE_ID=... \
			lune run tools/ci/run_tests.luau [<package>]

	With no argument it runs every package's specs; pass a package name (e.g.
	`tablemanager`) to scope the run to that one lib/<package>. Scoping keeps an
	unrelated package's unresolved deps from aborting the whole run.

	This is the fast CI check for datamodel/`const` packages that the Lune pipeline
	cannot run. The coverage system reuses the same OpenCloud driver for its own
	instrumented runs (see tools/coverage/lune/core/OpenCloudRunner.luau).
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local OpenCloud = require("./OpenCloud")
local PlaceTree = require("./PlaceTree")

local WORK_DIR = ".ci"
local PROJECT_PATH = WORK_DIR .. "/place.project.json"
local PLACE_PATH = WORK_DIR .. "/place.rbxl"
local RUNNER_SCRIPT = "test/ci/runTests.luau"

-- Build the plain place: mount every lib/<pkg> from its real source plus the
-- tiniest framework. The project lives in `.ci/`, one level below the repo root.
if not fs.isDir(WORK_DIR) then
	fs.writeDir(WORK_DIR)
end

local projectTree = PlaceTree.build({ repoPrefix = "../" })
fs.writeFile(PROJECT_PATH, serde.encode("json", { name = "ci-tests", tree = projectTree }, true))

print("[ci] rojo build...")
local build = process.exec("rojo", { "build", PROJECT_PATH, "-o", PLACE_PATH })
if not build.ok then
	error("[ci] rojo build failed:\n" .. build.stderr)
end

-- Optional first positional arg scopes the run to one package.
local targetPackage = (process.args[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
if targetPackage ~= "" then
	print(`[ci] scoping run to package '{targetPackage}'.`)
end

local runnerSource = fs.readFile(RUNNER_SCRIPT):gsub("__SCOPE_PACKAGE__", targetPackage)
local result = OpenCloud.execute(PLACE_PATH, runnerSource)

print("")
print("================= Test output =================")
print(result.logs)
print("===============================================")
print("")

if result.state == "COMPLETE" then
	print("[ci] SUCCESS: all tests passed.")
else
	local message = `[ci] FAILURE: task ended in state {result.state}.`
	if result.error ~= nil then
		message ..= `\n  code: {result.error.code}\n  message: {result.error.message}`
	end
	print(message)
	process.exit(1)
end
