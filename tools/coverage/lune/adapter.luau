--!strict
--[=[
	@module adapter

	The portability boundary for the coverage system. The core (engine driver,
	orchestrator, runners, merge/analyze/report, tiniest plugin) is repo-agnostic
	and consumes only these types. Everything that encodes a specific repo's
	conventions -- package discovery, layout, materialization, pipeline choice,
	Studio scaffolding -- lives in a `RepoAdapter` implementation under
	`adapters/`.

	A new repo adopts the system by writing one adapter module plus a thin CLI.
]=]

export type Pipeline = "lune" | "roblox"

--[=[
	A single testable package, fully described for the engine and runners.
]=]
export type PackageSpec = {
	name: string,
	-- Package directory (relative to repo root), e.g. "lib/queue".
	root: string,
	-- Source dir relative to `root`, e.g. "src".
	sourceRoot: string,
	-- Rust-regex string identifying spec files, e.g. "\\.spec\\.luau$".
	specPattern: string,
	-- Instrumentation excludes (glob, relative to `root`), e.g. { "src/_Index/**" }.
	exclude: { string },
	pipeline: Pipeline,
	-- Human-readable justification for the pipeline choice.
	pipelineReason: string,
	-- Suppression files to read at analysis time, most-specific first.
	ignoreFiles: { string },
}

--[=[
	How to bind `tiniest_for_lune` for a package's instrumented copy.
]=]
export type LuneFrameworkConfig = {
	snapshotPath: string?,
	saveSnapshots: boolean?,
}

--[=[
	Roblox pipeline scaffolding for a package's instrumented copy.
]=]
export type RobloxScaffold = {
	-- A rojo project tree (the value of the project's "tree" key).
	projectTree: { [string]: any },
	-- Full source of the generated `runner.server.luau`.
	runnerSource: string,
}

export type RepoAdapter = {
	name: string,
	-- selector: "all" | "last" | "<package-name>"
	resolvePackages: (selector: string) -> { PackageSpec },
	-- Produce a runnable, uninstrumented copy of the package at `buildDir`.
	materialize: (spec: PackageSpec, buildDir: string) -> (),
	luneFramework: (spec: PackageSpec, buildDir: string) -> LuneFrameworkConfig,
	robloxScaffold: (spec: PackageSpec, buildDir: string) -> RobloxScaffold,
	-- The per-package coverage work dir, e.g. ".coverage/<name>".
	workDir: (spec: PackageSpec) -> string,
}

local adapter = {}

--[=[
	Validates that `candidate` implements the RepoAdapter surface. Returns the
	adapter typed, or errors describing the first missing member.
]=]
function adapter.validate(candidate: any): RepoAdapter
	assert(type(candidate) == "table", "adapter must be a table")
	local required = {
		"name",
		"resolvePackages",
		"materialize",
		"luneFramework",
		"robloxScaffold",
		"workDir",
	}
	for _, key in required do
		assert(candidate[key] ~= nil, `adapter is missing required member '{key}'`)
	end
	return candidate :: RepoAdapter
end

return adapter
