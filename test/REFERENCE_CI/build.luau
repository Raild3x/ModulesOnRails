--[[
	tests/ci/build.luau

	Builds a self-contained Roblox test place (`Tests.rbxl`) that can be run on
	real Roblox via the Open Cloud Luau Execution API (see
	`.github/workflows/unit-tests.yml`).

	Why this exists:
	The codebase requires modules with short `@Alias/...` paths (resolved by the
	custom Rojo-For-Eleons Studio plugin at sync time). A plain `rojo build` does
	NOT resolve those, so the built place would have unresolved requires. This
	script reproduces that resolution as a build-time transform:

		1. Generate Rojo's authoritative file -> instance sourcemap from
		   `test.src.project.json` (which points at the real source dirs).
		2. Mirror the needed source trees into `dist/`, rewriting every
		   `require("@Alias/...")` into a native instance require
		   (e.g. `require(game:GetService("ReplicatedStorage")["Framework"]...)`).
		3. `rojo build test.project.json` (which points at `dist/`) -> Tests.rbxl.

	The rewrite is regex-based (it only needs to find `require("@...")` calls),
	so it does not parse Luau and is unaffected by the `const` keyword that the
	codebase uses but older parsers reject.

	Run locally:
		lune run tests/ci/build
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local REPO_ROOT = process.cwd

-- Source trees mirrored into dist/. Order is irrelevant.
local COPY_ROOTS = {
	{ from = "src/Framework", to = "dist/Framework" },
	{ from = "Packages", to = "dist/Packages" },
	{ from = "tests", to = "dist/tests" },
}

-- First path-segment aliases that must never be alias-resolved.
local RESERVED_FIRST_SEGMENTS = {
	game = true, -- @game/... canonical DataModel path
	self = true, -- @self/... relative-to-self
	lune = true, -- @lune/... Lune builtin (inert in Roblox)
}

local TEXT_EXTENSIONS = { [".luau"] = true, [".lua"] = true }

-- `.luaurc` is the local source of truth for aliases but is .gitignore'd, so it
-- is not present in CI checkouts. We keep a committed snapshot of just the
-- alias table here: local runs (where `.luaurc` exists) refresh it, and CI runs
-- (where it doesn't) fall back to it. Commit this file whenever aliases change.
local ALIAS_SNAPSHOT_PATH = "tests/ci/aliases.snapshot.json"

--
-- Small helpers
--

local function readFile(path: string): string
	return fs.readFile(path)
end

local function fileExists(path: string): boolean
	return fs.isFile(path)
end

-- Create `path` and all missing parent directories.
local function mkdirp(path: string)
	local parts = string.split(path, "/")
	local accumulated = ""
	for _, part in parts do
		if part == "" then
			continue
		end
		accumulated = if accumulated == "" then part else `{accumulated}/{part}`
		if not fs.isDir(accumulated) then
			-- writeDir is a no-op if the directory already exists.
			pcall(fs.writeDir, accumulated)
		end
	end
end

local function dirname(path: string): string
	local lastSlash = nil
	for i = #path, 1, -1 do
		if string.sub(path, i, i) == "/" then
			lastSlash = i
			break
		end
	end
	if lastSlash == nil then
		return ""
	end
	return string.sub(path, 1, lastSlash - 1)
end

local function extensionOf(path: string): string
	local dot = nil
	for i = #path, 1, -1 do
		local c = string.sub(path, i, i)
		if c == "." then
			dot = i
			break
		elseif c == "/" then
			break
		end
	end
	if dot == nil then
		return ""
	end
	return string.sub(path, dot)
end

--
-- .luaurc alias table
--

local function stripJsoncComments(text: string): string
	-- The .luaurc only uses // line comments outside string literals.
	return (string.gsub(text, "//[^\n]*", ""))
end

local function normalizeAliases(aliases: { [string]: any }): { [string]: string }
	-- Normalize backslashes, and self-heal workspace-absolute paths back to
	-- relative so the committed snapshot can never bake in machine-specific
	-- paths. Absolute paths OUTSIDE the workspace are a hard error (they break
	-- require resolution and are not portable across machines / CI).
	local rootPrefix = (string.gsub(REPO_ROOT, "\\", "/"))
	if string.sub(rootPrefix, -1) ~= "/" then
		rootPrefix = rootPrefix .. "/"
	end

	local result: { [string]: string } = {}
	for key, value in aliases do
		local normalized = (string.gsub(value, "\\", "/"))
		if string.sub(normalized, 1, #rootPrefix) == rootPrefix then
			normalized = string.sub(normalized, #rootPrefix + 1)
		elseif string.sub(normalized, 1, 1) == "/" then
			error(
				`Alias "{key}" is an absolute path outside the workspace: {value}. `
					.. `Aliases must be workspace-relative (e.g. "src/Framework/Foo.luau").`,
				0
			)
		end
		result[key] = normalized
	end
	return result
end

local function loadAliases(): { [string]: string }
	if fileExists(".luaurc") then
		local raw = readFile(".luaurc")
		local decoded = serde.decode("json", stripJsoncComments(raw))
		local aliases = normalizeAliases(decoded.aliases or {})
		-- Refresh the committed snapshot so CI (which lacks `.luaurc`) stays in
		-- sync with whatever a developer last built against locally.
		pcall(fs.writeFile, ALIAS_SNAPSHOT_PATH, serde.encode("json", aliases, true))
		print("[build] Loaded aliases from .luaurc (refreshed snapshot).")
		return aliases
	end

	if fileExists(ALIAS_SNAPSHOT_PATH) then
		print(`[build] .luaurc not found; using committed alias snapshot ({ALIAS_SNAPSHOT_PATH}).`)
		return normalizeAliases(serde.decode("json", readFile(ALIAS_SNAPSHOT_PATH)))
	end

	error(
		`No alias source found: neither ".luaurc" nor "{ALIAS_SNAPSHOT_PATH}" exists. `
			.. `Run this build once locally (with .luaurc present) to generate the snapshot.`,
		0
	)
end

--
-- Sourcemap -> file path -> instance path segments
--

-- Returns a map from a normalized source file path (forward slashes) to an
-- array of instance-name segments (excluding the DataModel root), e.g.
--   "src/Framework/Helpers/Utils/UtilTable.luau" ->
--       { "ReplicatedStorage", "Framework", "Helpers", "Utils", "UtilTable" }
local function buildFileToInstance(sourcemapPath: string): { [string]: { string } }
	local raw = readFile(sourcemapPath)
	local root = serde.decode("json", raw)
	local map: { [string]: { string } } = {}

	local function walk(node: any, ancestry: { string })
		local segments = ancestry
		if node.name ~= nil and #ancestry >= 0 and node ~= root then
			segments = table.clone(ancestry)
			table.insert(segments, node.name)
		end

		if node.filePaths ~= nil and node ~= root then
			for _, filePath in node.filePaths do
				local normalized = string.gsub(filePath, "\\", "/")
				-- Only index real Luau source files (skip .meta.json etc.).
				if TEXT_EXTENSIONS[extensionOf(normalized)] then
					map[normalized] = segments
				end
			end
		end

		if node.children ~= nil then
			for _, child in node.children do
				walk(child, segments)
			end
		end
	end

	-- Root's children start the segment chain (skip the DataModel node itself).
	if root.children ~= nil then
		for _, child in root.children do
			walk(child, {})
		end
	end

	return map
end

--
-- Alias resolution: "@Framework/Helpers/Utils/UtilTable" -> instance segments
--

local function parseShortPath(path: string): { string }?
	local cleaned: { string } = {}
	for _, seg in string.split(string.sub(path, 2), "/") do
		if seg ~= "" then
			table.insert(cleaned, seg)
		end
	end
	if #cleaned == 0 or RESERVED_FIRST_SEGMENTS[cleaned[1]] then
		return nil
	end
	return cleaned
end

-- Candidate source-file suffixes tried (in order) for a resolved base path.
local CANDIDATE_SUFFIXES = {
	"",
	".luau",
	".lua",
	"/init.luau",
	"/init.lua",
	".server.luau",
	".server.lua",
	".client.luau",
	".client.lua",
}

local function resolveRequire(
	atPath: string,
	aliases: { [string]: string },
	fileToInstance: { [string]: { string } }
): { string }?
	local segments = parseShortPath(atPath)
	if segments == nil then
		return nil
	end

	local aliasKey = segments[1]
	local aliasValue = aliases[aliasKey]
	if aliasValue == nil then
		return nil
	end

	-- Build the base source path from the alias value plus the remaining
	-- segments. If the alias points directly at a file, its directory is the
	-- base for any trailing segments.
	local restCount = #segments - 1
	local base: string
	local aliasExt = extensionOf(aliasValue)
	if TEXT_EXTENSIONS[aliasExt] then
		if restCount == 0 then
			-- Alias is a direct file reference; use it as-is.
			if fileToInstance[aliasValue] ~= nil then
				return fileToInstance[aliasValue]
			end
			base = string.sub(aliasValue, 1, #aliasValue - #aliasExt)
		else
			base = dirname(aliasValue)
			for i = 2, #segments do
				base = `{base}/{segments[i]}`
			end
		end
	else
		base = aliasValue
		for i = 2, #segments do
			base = `{base}/{segments[i]}`
		end
	end

	for _, suffix in CANDIDATE_SUFFIXES do
		local candidate = base .. suffix
		local instance = fileToInstance[candidate]
		if instance ~= nil then
			return instance
		end
	end

	return nil
end

local function instanceExpression(segments: { string }): string
	-- First segment is a service (ReplicatedStorage / ServerScriptService).
	local expr = `game:GetService("{segments[1]}")`
	for i = 2, #segments do
		expr ..= string.format("[%q]", segments[i])
	end
	return `require({expr})`
end

--
-- Comment-aware source segmentation (ported from the Rojo plugin's
-- resolveAtPath.segmentSource) so we never rewrite inside comments.
--

type Segment = { text: string, isComment: boolean }

local function segmentSource(source: string): { Segment }
	local segments: { Segment } = {}
	local pos = 1
	local codeStart = 1
	local len = #source

	local function skipQuotedString(quote: string, startPos: number): number
		local p = startPos + 1
		while p <= len do
			local c = string.sub(source, p, p)
			if c == "\\" then
				p += 2
			elseif c == quote then
				return p + 1
			else
				p += 1
			end
		end
		return p
	end

	local function flushCode(upTo: number)
		if upTo > codeStart then
			table.insert(segments, { text = string.sub(source, codeStart, upTo - 1), isComment = false })
		end
	end

	while pos <= len do
		local c = string.sub(source, pos, pos)

		if c == "-" and string.sub(source, pos + 1, pos + 1) == "-" then
			flushCode(pos)
			local longOpen = string.match(string.sub(source, pos), "^%-%-%[=*%[")
			if longOpen then
				local eqCount = #longOpen - 4
				local closePattern = "%]" .. string.rep("=", eqCount) .. "%]"
				local _, closeEnd = string.find(source, closePattern, pos + #longOpen)
				local commentEnd = closeEnd or len
				table.insert(segments, { text = string.sub(source, pos, commentEnd), isComment = true })
				pos = commentEnd + 1
			else
				local nlPos = string.find(source, "\n", pos, true)
				local commentEnd = if nlPos then nlPos - 1 else len
				table.insert(segments, { text = string.sub(source, pos, commentEnd), isComment = true })
				pos = commentEnd + 1
			end
			codeStart = pos
		elseif c == '"' or c == "'" or c == "`" then
			pos = skipQuotedString(c, pos)
		elseif c == "[" then
			local longOpen = string.match(string.sub(source, pos), "^%[=*%[")
			if longOpen then
				local eqCount = #longOpen - 2
				local closePattern = "%]" .. string.rep("=", eqCount) .. "%]"
				local _, closeEnd = string.find(source, closePattern, pos + #longOpen)
				pos = (closeEnd or len) + 1
			else
				pos += 1
			end
		else
			pos += 1
		end
	end

	if codeStart <= len then
		table.insert(segments, { text = string.sub(source, codeStart), isComment = false })
	end

	return segments
end

local REQUIRE_PATTERNS = {
	{ pattern = 'require%s*%(%s*"(@[^"]+)"%s*%)', quote = '"' },
	{ pattern = "require%s*%(%s*'(@[^']+)'%s*%)", quote = "'" },
	{ pattern = "require%s*%(%s*`(@[^`]+)`%s*%)", quote = "`" },
}

-- Returns (rewrittenSource, numRewritten, numUnresolved).
local function transformSource(
	source: string,
	aliases: { [string]: string },
	fileToInstance: { [string]: { string } }
): (string, number, number)
	local rewritten = 0
	local unresolved = 0
	local parts: { string } = {}

	for _, segment in segmentSource(source) do
		if segment.isComment then
			table.insert(parts, segment.text)
			continue
		end

		local text = segment.text
		local out: { string } = {}
		local p = 1
		while true do
			local bestS, bestE, bestPath, bestQuote = nil, nil, nil, nil
			for _, entry in REQUIRE_PATTERNS do
				local s, e, path = string.find(text, entry.pattern, p)
				if s ~= nil and (bestS == nil or s < bestS) then
					bestS, bestE, bestPath, bestQuote = s, e, path, entry.quote
				end
			end

			if bestS == nil then
				table.insert(out, string.sub(text, p))
				break
			end

			table.insert(out, string.sub(text, p, bestS - 1))
			local resolved = resolveRequire(bestPath, aliases, fileToInstance)
			if resolved ~= nil then
				table.insert(out, instanceExpression(resolved))
				rewritten += 1
			else
				-- Leave the original require untouched. It targets a module not
				-- present in the test place (or a reserved/builtin path).
				table.insert(out, string.sub(text, bestS, bestE))
				if parseShortPath(bestPath) ~= nil then
					unresolved += 1
				end
			end
			p = bestE + 1
		end
		table.insert(parts, table.concat(out))
	end

	return table.concat(parts), rewritten, unresolved
end

--
-- File-tree mirroring (transforming Luau sources on the way through)
--

local function mirrorTree(
	from: string,
	to: string,
	aliases: { [string]: string },
	fileToInstance: { [string]: { string } },
	stats: { files: number, rewritten: number, unresolved: number }
)
	if fs.isFile(from) then
		mkdirp(dirname(to))
		if TEXT_EXTENSIONS[extensionOf(from)] then
			local source = readFile(from)
			local out, rewritten, unresolved = transformSource(source, aliases, fileToInstance)
			fs.writeFile(to, out)
			stats.files += 1
			stats.rewritten += rewritten
			stats.unresolved += unresolved
		else
			fs.writeFile(to, fs.readFile(from))
		end
		return
	end

	if not fs.isDir(from) then
		return
	end

	mkdirp(to)
	for _, entry in fs.readDir(from) do
		mirrorTree(`{from}/{entry}`, `{to}/{entry}`, aliases, fileToInstance, stats)
	end
end

--
-- Orchestration
--

local function run(program: string, args: { string })
	print(`$ {program} {table.concat(args, " ")}`)
	local result = process.spawn(program, args)
	if result.stdout ~= "" then
		print(result.stdout)
	end
	if result.stderr ~= "" then
		print(result.stderr)
	end
	if not result.ok then
		error(`Command failed ({result.code}): {program} {table.concat(args, " ")}`)
	end
end

print("[build] Generating sourcemap from test.src.project.json...")
run("rojo", { "sourcemap", "test.src.project.json", "-o", "test.sourcemap.json" })

print("[build] Loading aliases + sourcemap...")
local aliases = loadAliases()
local fileToInstance = buildFileToInstance("test.sourcemap.json")

print("[build] Cleaning dist/...")
if fs.isDir("dist") then
	fs.removeDir("dist")
end
fs.writeDir("dist")

print("[build] Mirroring + transforming source trees into dist/...")
local stats = { files = 0, rewritten = 0, unresolved = 0 }
for _, root in COPY_ROOTS do
	if fs.isDir(root.from) or fs.isFile(root.from) then
		mirrorTree(root.from, root.to, aliases, fileToInstance, stats)
	else
		print(`[build] (skipping missing root: {root.from})`)
	end
end
print(
	`[build] Transformed {stats.files} Luau file(s): {stats.rewritten} require(s) rewritten, `
		.. `{stats.unresolved} left unresolved (modules outside the test place).`
)

print("[build] Building Tests.rbxl from test.project.json...")
run("rojo", { "build", "test.project.json", "-o", "Tests.rbxl" })

print(`[build] Done. (cwd: {REPO_ROOT})`)
