--!strict
--[=[
	@module core/RobloxRunner

	Runs a package's instrumented suite inside Roblox Studio (edit mode) via
	run-in-roblox. The generic mechanics -- write project, rojo build, launch,
	decode -- live here; the rojo tree shape and runner source are adapter-owned.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local adapterMod = require("../adapter")
local StdoutCodec = require("./StdoutCodec")

type RepoAdapter = adapterMod.RepoAdapter
type PackageSpec = adapterMod.PackageSpec

local RobloxRunner = {}

export type RunOutput = {
	coverage: any,
	tally: { pass: number, fail: number, skipped: number },
	duration: number,
}

-- run-in-roblox captures everything Studio prints. Forward the test framework's
-- own output (tree / failure report, formatted per the runner's `pretty` config)
-- to the CLI verbatim, dropping only the coverage sentinel-protocol lines.
--
-- Forwarding whole lines is safe: the "Can't convert to JSON" hazard was specific
-- to byte-SLICING the base64 payload (which could split a multibyte char); a
-- valid-UTF-8 print line -- box-drawing, non-ASCII test names and all --
-- re-JSONEncodes fine. Blank lines are preserved so tree formatting survives.
local function forwardStudioOutput(output: string)
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

function RobloxRunner.run(adapter: RepoAdapter, spec: PackageSpec, buildDir: string, workDir: string): RunOutput
	local scaffold = adapter.robloxScaffold(spec, buildDir)

	local projectPath = workDir .. "/place.project.json"
	fs.writeFile(
		projectPath,
		serde.encode("json", { name = "coverage-" .. spec.name, tree = scaffold.projectTree }, true)
	)

	local runnerPath = workDir .. "/runner.server.luau"
	fs.writeFile(runnerPath, scaffold.runnerSource)

	local placePath = workDir .. "/place.rbxl"
	print("[roblox] rojo build...")
	local build = process.exec("rojo", { "build", projectPath, "-o", placePath })
	if not build.ok then
		error("[roblox] rojo build failed:\n" .. build.stderr)
	end

	print("[roblox] launching Studio via run-in-roblox (this opens and closes Studio)...")
	local start = os.clock()
	local run = process.exec("run-in-roblox", { "--place", placePath, "--script", runnerPath })
	local duration = os.clock() - start

	local output = (run.stdout or "") .. "\n" .. (run.stderr or "")

	-- Surface the framework's own test output (respecting the runner's pretty
	-- settings) before we consume the coverage payload.
	forwardStudioOutput(output)

	if output:find("[[TM-COV-ERROR]]", 1, true) then
		local msg = output:match("%[%[TM%-COV%-ERROR%]%](.-)\n") or "unknown error"
		error("[roblox] runner errored inside Studio: " .. msg)
	end

	local payload = StdoutCodec.decode(output)
	if payload == nil then
		error(
			"[roblox] no coverage output captured. run-in-roblox output was:\n"
				.. output:sub(1, 2000)
		)
	end

	return {
		coverage = payload.coverage,
		tally = payload.tally,
		duration = duration,
	}
end

return RobloxRunner
