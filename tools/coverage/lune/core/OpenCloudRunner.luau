--!strict
--[=[
	Runs a package's instrumented suite on a real Roblox server via Open Cloud's
	Luau Execution API, as a drop-in alternative to RobloxRunner (which drives a
	local Studio via run-in-roblox). Same signature, same `RunOutput`.

	It reuses the adapter's Roblox scaffold (project tree + runner source) and the
	StdoutCodec sentinel protocol -- only the transport differs: the runner source
	is the Luau Execution task body, and its printed output comes back as task logs
	instead of Studio stdout. Because Open Cloud logs paginate, this has no ~1 MB
	payload cap (unlike run-in-roblox), so `--per-test` is safe here.

	Selected over RobloxRunner from the Orchestrator when an Open Cloud API key is
	configured (or forced via `--roblox-runner=opencloud`).
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local adapterMod = require("../adapter")
local StdoutCodec = require("./StdoutCodec")
local OpenCloud = require("../../../ci/OpenCloud")

type RepoAdapter = adapterMod.RepoAdapter
type PackageSpec = adapterMod.PackageSpec

local OpenCloudRunner = {}

export type RunOutput = {
	coverage: any,
	tally: { pass: number, fail: number, skipped: number },
	duration: number,
}

-- Forward the test framework's own output (tree / failure report) to the CLI
-- verbatim, dropping only the coverage sentinel-protocol lines. Mirrors
-- RobloxRunner.forwardStudioOutput; kept separate so the two transports stay
-- independent.
local function forwardOutput(output: string)
	local lines = output:gsub("\r\n", "\n"):gsub("\r", "\n"):split("\n")
	local kept: { string } = {}
	for _, line in lines do
		if not line:find("[[TM-COV", 1, true) then
			table.insert(kept, line)
		end
	end
	while #kept > 0 and kept[1]:match("^%s*$") do
		table.remove(kept, 1)
	end
	while #kept > 0 and kept[#kept]:match("^%s*$") do
		table.remove(kept)
	end
	if #kept > 0 then
		print(table.concat(kept, "\n"))
	end
end

function OpenCloudRunner.run(
	adapter: RepoAdapter,
	spec: PackageSpec,
	buildDir: string,
	workDir: string,
	runOptions: adapterMod.RobloxRunOptions?
): RunOutput
	local scaffold = adapter.robloxScaffold(spec, buildDir, runOptions)

	local projectPath = workDir .. "/place.project.json"
	fs.writeFile(
		projectPath,
		serde.encode("json", { name = "coverage-" .. spec.name, tree = scaffold.projectTree }, true)
	)

	-- Written for parity/debuggability; the Open Cloud task takes the source
	-- directly (as the task body), not a file path.
	fs.writeFile(workDir .. "/runner.server.luau", scaffold.runnerSource)

	local placePath = workDir .. "/place.rbxl"
	print("[open-cloud] rojo build...")
	local build = process.exec("rojo", { "build", projectPath, "-o", placePath })
	if not build.ok then
		error("[open-cloud] rojo build failed:\n" .. build.stderr)
	end

	print("[open-cloud] running instrumented suite via Open Cloud (publishes + runs a task)...")
	local result = OpenCloud.execute(placePath, scaffold.runnerSource)
	local output = result.logs

	-- Surface the framework's own test output before consuming the coverage payload.
	forwardOutput(output)

	if output:find("[[TM-COV-ERROR]]", 1, true) then
		local msg = output:match("%[%[TM%-COV%-ERROR%]%](.-)\n") or "unknown error"
		error("[open-cloud] runner errored inside the task: " .. msg)
	end

	local payload = StdoutCodec.decode(output)
	if payload == nil then
		-- No sentinel means the task never reached the payload emit -- usually a
		-- runtime/compile error in the task. Surface the terminal state + error.
		local detail = `task state {result.state}`
		if result.error ~= nil then
			detail ..= `; error {result.error.code}: {result.error.message}`
		end
		error(
			`[open-cloud] no coverage output captured ({detail}). Task logs were:\n` .. output:sub(1, 2000)
		)
	end

	return {
		coverage = payload.coverage,
		tally = payload.tally,
		duration = result.duration,
	}
end

return OpenCloudRunner
