--!strict
--[=[
	@module tools/ci/PlaceTree

	Builds the rojo project "tree" that mounts this repo's packages for running
	tests inside Roblox. A single source of truth shared by:
	  * the standalone plain test runner (`tools/ci/run_tests.luau`), which mounts
	    every `lib/<pkg>` from its real source, and
	  * the coverage system's Roblox scaffold
	    (`tools/coverage/lune/adapters/modules_on_rails.luau`), which points the
	    package under test at its instrumented `build/` copy instead.

	The tree mirrors the repo's own Studio project (`default.project.json`):
	`lib/*` -> `ReplicatedStorage.src.*` and `test/tiniest` ->
	`ReplicatedStorage.test.tiniest`. Mounting ALL of `lib/` (not just one package)
	is deliberate: `tablereplicator` requires `tablemanager` via a relative
	cross-package require, and the extra siblings are inert for isolated packages.
]=]

local fs = require("@lune/fs")

local LIB_ROOT = "lib"

local PlaceTree = {}

export type Config = {
	-- Relative path from the rojo project.json's directory to the repo root, with
	-- a trailing slash, e.g. "../../" when the project lives in ".coverage/<pkg>/".
	repoPrefix: string,
	-- Optionally point one package at a different `$path` (relative to the project
	-- dir) instead of its real `lib/<name>` source -- used by coverage to mount an
	-- instrumented build.
	override: { package: string, path: string }?,
}

--[=[
	Returns the rojo project tree (the value of a project's "tree" key).
]=]
function PlaceTree.build(config: Config): { [string]: any }
	local override = config.override

	local srcTree: { [string]: any } = { ["$className"] = "Folder" }
	for _, entry in fs.readDir(LIB_ROOT) do
		if fs.isDir(`{LIB_ROOT}/{entry}/src`) then
			if override ~= nil and entry == override.package then
				srcTree[entry] = { ["$path"] = override.path }
			else
				srcTree[entry] = { ["$path"] = `{config.repoPrefix}{LIB_ROOT}/{entry}` }
			end
		end
	end

	return {
		["$className"] = "DataModel",
		ReplicatedStorage = {
			["$className"] = "ReplicatedStorage",
			src = srcTree,
			test = {
				["$className"] = "Folder",
				tiniest = { ["$path"] = `{config.repoPrefix}test/tiniest` },
			},
		},
	}
end

return PlaceTree
