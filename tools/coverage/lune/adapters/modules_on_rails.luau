--!strict
--[=[
	@module adapters/modules_on_rails

	RepoAdapter for the ModulesOnRails monorepo (this repo). Encodes:
	  * package discovery under `lib/` (a dir with `src/` holding a `*.spec.luau`)
	  * pipeline choice: PackageClassifier (datamodel globals -> Studio) plus a
	    `const` scan (Lune 0.10.4 cannot parse `const`, so const users -> Studio)
	  * materialization: copy the whole package dir so relative string requires
	    resolve identically inside the instrumented copy
	  * rojo tree + runner template for the Studio pipeline
]=]

local fs = require("@lune/fs")

local adapter = require("../adapter")
local PlaceTree = require("../../../ci/PlaceTree")

type PackageSpec = adapter.PackageSpec
type Pipeline = adapter.Pipeline

local LIB_ROOT = "lib"
local SPEC_PATTERN = "\\.spec\\.luau$"
local EXCLUDE = { "src/_Index/**" }
local IGNORE_FILES = { ".coverage-ignore", ".covaudit-ignore" }
local LAST_TESTED = "test/last_tested_package.txt"

-- Datamodel touchpoints Lune has no equivalent for. `task`/`buffer`/`string`
-- are deliberately absent -- Lune provides those, so they don't force Studio.
local ROBLOX_MARKERS: { string } = {
	"game:GetService",
	"game.",
	"workspace",
	"Instance.new",
	"script:",
	"script.",
	":GetPropertyChangedSignal",
}

local M = {}
M.name = "modules_on_rails"

-- -- discovery ----------------------------------------------------------------

local function collectLuau(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			if entry ~= "_Index" then
				collectLuau(full, out)
			end
		elseif entry:match("%.luau$") then
			table.insert(out, full)
		end
	end
end

-- A dir under `lib/` is auditable if its `src` holds at least one `*.spec.luau`.
local function hasSpecs(srcPath: string): boolean
	local found = false
	local function scan(dir: string)
		if found then
			return
		end
		for _, entry in fs.readDir(dir) do
			local full = dir .. "/" .. entry
			if fs.isDir(full) then
				if entry ~= "_Index" then
					scan(full)
				end
			elseif entry:match("%.spec%.luau$") then
				found = true
				return
			end
		end
	end
	scan(srcPath)
	return found
end

-- -- setup detection ----------------------------------------------------------

-- Wally sections whose entries mean the package has external dependencies that
-- must be resolved into `_Index/` before it can build/run. Mirrors the same
-- check in scripts/test_package.py so the two stay consistent.
local DEP_SECTIONS: { [string]: boolean } = {
	["[dependencies]"] = true,
	["[server-dependencies]"] = true,
	["[dev-dependencies]"] = true,
}

local function hasWallyDependencies(root: string): boolean
	local wallyPath = `{root}/wally.toml`
	if not fs.isFile(wallyPath) then
		return false
	end
	local inDepSection = false
	for rawLine in fs.readFile(wallyPath):gmatch("[^\r\n]+") do
		local line = rawLine:gsub("#.*", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line == "" then
			continue
		end
		if line:sub(1, 1) == "[" then
			inDepSection = DEP_SECTIONS[line] == true
		elseif inDepSection and line:find("=", 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- A package can't be measured if it declares Wally deps but its `_Index/` folder
-- hasn't been resolved yet (i.e. `npm run setup <name>` hasn't run, or failed).
local function needsSetup(root: string): boolean
	return hasWallyDependencies(root) and not fs.isDir(`{root}/_Index`)
end

-- -- pipeline classification --------------------------------------------------

-- Returns (pipeline, reason). Studio is forced by datamodel usage OR by `const`
-- (which Lune 0.10.4 rejects at parse time).
local function classify(srcPath: string): (Pipeline, string)
	local files: { string } = {}
	collectLuau(srcPath, files)
	local usesConst = false
	for _, file in files do
		local source = fs.readFile(file)
		for _, marker in ROBLOX_MARKERS do
			if source:find(marker, 1, true) ~= nil then
				return "roblox", `uses datamodel global '{marker}'`
			end
		end
		if not usesConst and source:find("\n%s*const%s") ~= nil then
			usesConst = true
		end
		-- also catch a const on the very first line
		if not usesConst and source:match("^%s*const%s") ~= nil then
			usesConst = true
		end
	end
	if usesConst then
		return "roblox", "uses `const` (Lune 0.10.4 cannot parse it)"
	end
	return "lune", "pure Luau, no datamodel globals"
end

local function buildSpec(name: string): PackageSpec
	local root = `{LIB_ROOT}/{name}`
	local srcPath = `{root}/src`
	assert(fs.isDir(srcPath), `package has no src directory: {srcPath}`)
	local pipeline: Pipeline, reason: string = classify(srcPath)
	local spec: PackageSpec = {
		name = name,
		root = root,
		sourceRoot = "src",
		specPattern = SPEC_PATTERN,
		exclude = EXCLUDE,
		pipeline = pipeline,
		pipelineReason = reason,
		ignoreFiles = IGNORE_FILES,
	}
	if needsSetup(root) then
		spec.skipReason = `dependencies not installed — run \`npm run setup {name}\``
	end
	return spec
end

function M.resolvePackages(selector: string): { PackageSpec }
	if selector == "all" then
		local names: { string } = {}
		for _, entry in fs.readDir(LIB_ROOT) do
			-- Skip non-directory entries (e.g. lib/MoonwaveSeparator.luau). Building
			-- a `<file>/src` path and stat-ing it raises ENOTDIR on Linux (on Windows
			-- it just returns false), so guard before touching the child path.
			if not fs.isDir(`{LIB_ROOT}/{entry}`) then
				continue
			end
			local srcPath = `{LIB_ROOT}/{entry}/src`
			if fs.isDir(srcPath) and hasSpecs(srcPath) then
				table.insert(names, entry)
			end
		end
		table.sort(names)
		local specs: { PackageSpec } = {}
		for _, name in names do
			table.insert(specs, buildSpec(name))
		end
		return specs
	elseif selector == "last" then
		assert(fs.isFile(LAST_TESTED), `no last-tested record at {LAST_TESTED}`)
		local name = fs.readFile(LAST_TESTED):gsub("%s+$", "")
		return { buildSpec(name) }
	else
		return { buildSpec(selector) }
	end
end

-- -- materialization ----------------------------------------------------------

-- Copy the entire package dir (src, specs, wally.toml, sibling vendored deps,
-- _Index) so relative string requires resolve identically in the copy.
function M.materialize(spec: PackageSpec, buildDir: string)
	if fs.isDir(buildDir) then
		fs.removeDir(buildDir)
	end
	fs.copy(spec.root, buildDir)
end

function M.luneFramework(_spec: PackageSpec, _buildDir: string): adapter.LuneFrameworkConfig
	-- Snapshot config matching the repo's tiniest setup.
	return {
		snapshotPath = "./test/__snapshots__",
		saveSnapshots = false,
	}
end

-- The Studio-side coverage runner (runs at plugin security, edit mode). Mounts:
--   ReplicatedStorage.src.<pkg>   <- the instrumented build (build/)
--   ReplicatedStorage.test.tiniest <- the framework + coverage plugin
-- A long-bracket template with a __PKG__ placeholder keeps the brace-heavy
-- Roblox source literal (no interpolation/escaping).
local RUNNER_TEMPLATE = [==[
-- Generated by the coverage system. Runs the instrumented __PKG__ suite in
-- Studio (edit mode) and dumps coverage through stdout sentinels.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local pkg = ReplicatedStorage.src:FindFirstChild("__PKG__")
assert(pkg, "coverage: package '__PKG__' not found under ReplicatedStorage.src")
local srcFolder = pkg:FindFirstChild("src") or pkg

local tiniestFolder = ReplicatedStorage.test.tiniest
local tiniest = require(tiniestFolder.tiniest_for_roblox).configure({
	pretty = { 
		-- format = "tree",
		trim_duplicate_trace = true,
		hide_passed_tests = true,
		disable_output = { 
			after_run = false,
		},
	},
	plugins = {
		require(tiniestFolder.tiniest_coverage).configure({
			runtime = require(srcFolder._cov),
			enable_per_test = __PER_TEST__,
		}),
	},
})

local tests = tiniest.collect_tests_from_hierarchy(srcFolder, {
	ignore = function(inst)
		if inst.Name == "_Index" then
			return true, true
		end
		if inst.Name == "_cov" then
			return true, false
		end
		return false, false
	end,
})

local ok, result = pcall(function()
	return tiniest.run_tests(tests, {})
end)

if not ok then
	print("[[TM-COV-ERROR]]" .. tostring(result))
	return
end

-- Full coverage including per-test attribution.
--
-- Transport is base64 over stdout. This is load-bearing, not cosmetic:
-- HttpService:JSONEncode emits non-ASCII (e.g. a test name with a unicode
-- character) as raw multi-byte UTF-8, and run-in-roblox re-JSONEncodes every
-- captured log line to ship it over HTTP. Slicing the JSON on byte boundaries
-- can split a multi-byte sequence, leaving an invalid-UTF-8 fragment in a chunk
-- that run-in-roblox then fails to encode ("Can't convert to JSON"). base64
-- makes every chunk pure ASCII [A-Za-z0-9+/=], immune to that (and to any other
-- byte-level hazard in the log pipeline).
--
-- Note the tree/failure output the framework prints (per the `pretty` config
-- above) does NOT need this treatment: whole valid-UTF-8 print lines re-encode
-- fine in run-in-roblox -- only byte-SLICING the payload could split a multibyte
-- char. RobloxRunner forwards those lines to the CLI verbatim, dropping only the
-- sentinel lines below.
local cov = result.coverage
local payload = {
	coverage = {
		hits = cov.hits,
		total = cov.total,
		map_sha = cov.map_sha,
		per_test = cov.per_test,
	},
	tally = result.status_tally,
}
local json = HttpService:JSONEncode(payload)

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64C = {}
for i = 1, 64 do
	B64C[i - 1] = string.sub(B64, i, i)
end
local function base64encode(s)
	local out = {}
	local len = #s
	for i = 1, len, 3 do
		local b1 = string.byte(s, i)
		local b2 = string.byte(s, i + 1)
		local b3 = string.byte(s, i + 2)
		local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		out[#out + 1] = B64C[(n // 262144) % 64]
			.. B64C[(n // 4096) % 64]
			.. (if b2 then B64C[(n // 64) % 64] else "=")
			.. (if b3 then B64C[n % 64] else "=")
	end
	return table.concat(out)
end

local encoded = base64encode(json)
local CHUNK = 500
local total = math.max(1, math.ceil(#encoded / CHUNK))
-- Sentinel protocol v2: base64 body, each chunk carries its own byte length so
-- the decoder can detect (and pinpoint) a clipped chunk, not just a total-size
-- mismatch.
print(("[[TM-COV-BEGIN v2 enc=base64 chunks=%d bytes=%d]]"):format(total, #encoded))
for i = 1, total do
	local slice = encoded:sub((i - 1) * CHUNK + 1, i * CHUNK)
	print(("[[TM-COV %d/%d len=%d]]%s"):format(i, total, #slice, slice))
end
print("[[TM-COV-END]]")
]==]

local function robloxRunnerSource(pkg: string, perTest: boolean): string
	-- __PKG__ first, then the per-test toggle. Per-test attribution is gated
	-- because it multiplies the payload by the test count, and run-in-roblox caps
	-- the stdout post it ships back (~1 MB); a large suite's per-test matrix blows
	-- that cap and drops the whole payload ("no coverage output captured").
	local src = RUNNER_TEMPLATE:gsub("__PKG__", pkg)
	return (src:gsub("__PER_TEST__", if perTest then "true" else "false"))
end

function M.robloxScaffold(
	spec: PackageSpec,
	_buildDir: string,
	runOptions: adapter.RobloxRunOptions?
): adapter.RobloxScaffold
	-- Project file lives at <workDir>/place.project.json (workDir is .coverage/<pkg>,
	-- two levels below the repo root), so $path values are relative to it. The
	-- shared PlaceTree helper mounts every lib package; the `override` points the
	-- package under test at its instrumented `build/` copy instead of its real
	-- source. See tools/ci/PlaceTree for why all of lib is mounted.
	local projectTree = PlaceTree.build({
		repoPrefix = "../../",
		override = { package = spec.name, path = "build" },
	})
	local perTest = if runOptions ~= nil then runOptions.perTest == true else false
	return {
		projectTree = projectTree,
		runnerSource = robloxRunnerSource(spec.name, perTest),
	}
end

function M.workDir(spec: PackageSpec): string
	return `.coverage/{spec.name}`
end

return adapter.validate(M)
