--!strict
--[=[
	@module adapters/coverage_self

	RepoAdapter that points the coverage system at its own Lune core, so the
	tool can measure itself:

		lune run coverage.luau package=self --adapter=./tools/coverage/lune/adapters/coverage_self

	One fixed package: root `tools/coverage/lune`, sourceRoot `core`, specs in
	`core/Tests/`. Always the lune pipeline — the core runs under Lune by
	construction. The IO/process-bound modules (Orchestrator, Engine, runners,
	Report) are instrumented but only exercised where specs require them, so
	they read as honest gaps rather than being excluded.
]=]

local fs = require("@lune/fs")

local adapter = require("../adapter")

type PackageSpec = adapter.PackageSpec

local M = {}
M.name = "coverage_self"

local SPEC: PackageSpec = {
	name = "coverage-lune",
	root = "tools/coverage/lune",
	sourceRoot = "core",
	specPattern = "\\.spec\\.luau$",
	exclude = {},
	pipeline = "lune",
	pipelineReason = "the coverage core runs under Lune by construction",
	ignoreFiles = { ".coverage-ignore" },
}

function M.resolvePackages(_selector: string): { PackageSpec }
	return { SPEC }
end

-- Copy the whole lune dir so relative requires (../adapter, ./Ignore, spec ->
-- ../Merge) resolve identically inside the instrumented copy.
function M.materialize(spec: PackageSpec, buildDir: string)
	if fs.isDir(buildDir) then
		fs.removeDir(buildDir)
	end
	fs.copy(spec.root, buildDir)
end

function M.luneFramework(_spec: PackageSpec, _buildDir: string): adapter.LuneFrameworkConfig
	return {
		snapshotPath = "./test/__snapshots__",
		saveSnapshots = false,
	}
end

function M.robloxScaffold(
	_spec: PackageSpec,
	_buildDir: string,
	_runOptions: adapter.RobloxRunOptions?
): adapter.RobloxScaffold
	error("coverage_self never uses the roblox pipeline")
end

function M.workDir(spec: PackageSpec): string
	return `.coverage/{spec.name}`
end

return adapter.validate(M)
