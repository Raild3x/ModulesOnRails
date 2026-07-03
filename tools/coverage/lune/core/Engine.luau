--!strict
--[=[
	@module core/Engine

	Locates (and, if needed, builds) the Rust `coverage-engine` binary, then
	drives its `analyze` / `instrument` subcommands. Repo-agnostic: every layout
	detail is taken from the PackageSpec.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")

local adapter = require("../adapter")
type PackageSpec = adapter.PackageSpec

local Engine = {}

local ENGINE_DIR = "tools/coverage/engine"

local function binaryPath(): string
	local exe = ENGINE_DIR .. "/target/release/coverage-engine"
	if process.os == "windows" then
		exe ..= ".exe"
	end
	return exe
end

--[=[
	Ensures the release binary exists, building it with cargo if missing or if
	`forceRebuild` is set. Returns the path to the binary.
]=]
function Engine.ensure(forceRebuild: boolean?): string
	local exe = binaryPath()
	if forceRebuild or not fs.isFile(exe) then
		print("[engine] building coverage-engine (cargo build --release)...")
		local result = process.exec("cargo", { "build", "--release" }, {
			cwd = ENGINE_DIR,
		})
		if not result.ok then
			print(result.stdout)
			print(result.stderr)
			error("[engine] cargo build failed (exit " .. tostring(result.code) .. ")")
		end
	end
	assert(fs.isFile(exe), "[engine] binary not found after build: " .. exe)
	return exe
end

local function commonArgs(spec: PackageSpec, packageDir: string): { string }
	local args = {
		"--package-dir",
		packageDir,
		"--package-name",
		spec.name,
		"--source-root",
		spec.sourceRoot,
		"--spec-pattern",
		spec.specPattern,
	}
	for _, ex in spec.exclude do
		table.insert(args, "--exclude")
		table.insert(args, ex)
	end
	return args
end

--[=[
	Runs static analysis on `packageDir`, writing map.json to `mapOut`.
]=]
function Engine.analyze(spec: PackageSpec, packageDir: string, mapOut: string, noConditions: boolean?, detectConst: boolean?)
	local exe = Engine.ensure(false)
	local args = { "analyze" }
	for _, a in commonArgs(spec, packageDir) do
		table.insert(args, a)
	end
	table.insert(args, "--out")
	table.insert(args, mapOut)
	if noConditions then
		table.insert(args, "--no-conditions")
	end
	if detectConst then
		table.insert(args, "--detect-const")
	end
	local result = process.exec(exe, args)
	if result.stderr ~= "" then
		print(result.stderr:gsub("%s+$", ""))
	end
	if not result.ok then
		error("[engine] analyze failed for " .. spec.name .. " (exit " .. tostring(result.code) .. ")")
	end
end

--[=[
	Instruments `buildDir` in place (a materialized copy) and writes map.json.
]=]
function Engine.instrument(spec: PackageSpec, buildDir: string, mapOut: string, noConditions: boolean?, detectConst: boolean?)
	local exe = Engine.ensure(false)
	local args = { "instrument" }
	for _, a in commonArgs(spec, buildDir) do
		table.insert(args, a)
	end
	table.insert(args, "--map-out")
	table.insert(args, mapOut)
	if noConditions then
		table.insert(args, "--no-conditions")
	end
	if detectConst then
		table.insert(args, "--detect-const")
	end
	local result = process.exec(exe, args)
	if result.stderr ~= "" then
		print(result.stderr:gsub("%s+$", ""))
	end
	if not result.ok then
		error("[engine] instrument failed for " .. spec.name .. " (exit " .. tostring(result.code) .. ")")
	end
end

--[=[
	Enumerates mutation sites in `packageDir` (a pristine, uninstrumented copy),
	writing mutants.json to `outPath`.
]=]
function Engine.mutate(spec: PackageSpec, packageDir: string, outPath: string)
	local exe = Engine.ensure(false)
	local args = { "mutate" }
	for _, a in commonArgs(spec, packageDir) do
		table.insert(args, a)
	end
	table.insert(args, "--out")
	table.insert(args, outPath)
	local result = process.exec(exe, args)
	if result.stderr ~= "" then
		print(result.stderr:gsub("%s+$", ""))
	end
	if not result.ok then
		error("[engine] mutate failed for " .. spec.name .. " (exit " .. tostring(result.code) .. ")")
	end
end

--[=[
	Applies one mutant in place under `root`. Returns "ok", or "invalid" when
	the engine refused it (the mutated file would not parse, exit 3). Any other
	failure — including the sha guard against stale/unrestored files — errors.
]=]
function Engine.applyMutant(mutantsPath: string, id: number, root: string): string
	local exe = Engine.ensure(false)
	local result = process.exec(exe, { "apply-mutant", "--mutants", mutantsPath, "--id", tostring(id), "--root", root })
	if result.ok then
		return "ok"
	end
	if result.code == 3 then
		return "invalid"
	end
	print(result.stderr:gsub("%s+$", ""))
	error("[engine] apply-mutant " .. tostring(id) .. " failed (exit " .. tostring(result.code) .. ")")
end

return Engine
