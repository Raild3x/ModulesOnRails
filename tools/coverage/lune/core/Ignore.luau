--!strict
--[=[
	Loads per-package suppression rules from ignore files (`.coverage-ignore`, and
	the legacy `.covaudit-ignore`) and matches them against probes. A matched probe
	is excluded from the coverage denominators and listed in the report's
	suppressed section instead of counting as a gap -- the way to silence a
	known-unreachable finding.

	Rule forms (one per line; blank lines and `#` / `--` comments ignored):
	  * `Qualified.Name`      -- a function's qualified name (also `"quoted name"`);
	                             suppresses that function AND its whole body.
	  * `src/path.luau:LINE`  -- any site anchored on that file + line.
	  * `site:<key>`          -- an exact site key (`<kind>:<relpath>:<line>:<col>`).

	Policy lives here (in Lune); the Rust engine stays ignore-agnostic.
]=]

local fs = require("@lune/fs")

local Ignore = {}

export type Rules = {
	-- qualified function names -> true
	names: { [string]: boolean },
	-- "src/path.luau:LINE" -> true
	fileLines: { [string]: boolean },
	-- exact site keys -> true
	sites: { [string]: boolean },
	-- true when no rules loaded (lets callers skip matching entirely)
	isEmpty: boolean,
}

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Ignore.empty(): Rules
	return { names = {}, fileLines = {}, sites = {}, isEmpty = true }
end

local function parseInto(text: string, rules: Rules)
	for rawLine in text:gmatch("[^\r\n]+") do
		local line = trim(rawLine)
		if line == "" or line:sub(1, 1) == "#" or line:sub(1, 2) == "--" then
			continue
		end
		if line:sub(1, 5) == "site:" then
			rules.sites[trim(line:sub(6))] = true
		elseif line:match("%.luau:%d+$") then
			rules.fileLines[line] = true
		else
			-- bare or quoted qualified function name
			local unquoted = line:match('^"(.*)"$') or line:match("^'(.*)'$") or line
			rules.names[unquoted] = true
		end
	end
end

--[=[
	Loads and merges every ignore file that exists under `root`. `fileNames` is
	the adapter's `spec.ignoreFiles` (most-specific first, though order is
	immaterial since rules union).
]=]
function Ignore.load(root: string, fileNames: { string }): Rules
	local rules = Ignore.empty()
	for _, name in fileNames do
		local path = root .. "/" .. name
		if fs.isFile(path) then
			parseInto(fs.readFile(path), rules)
		end
	end
	rules.isEmpty = next(rules.names) == nil and next(rules.fileLines) == nil and next(rules.sites) == nil
	return rules
end

--[=[
	Whether a probe is matched *directly* by a site or file-line rule, or (for
	`fn` probes) by a name rule. Body statements suppressed by an enclosing
	function's name rule are handled by the caller via `fn_id` -- those are
	excluded but not individually listed. Returns the rule kind that matched (for
	the report), or nil.
]=]
function Ignore.matchDirect(
	rules: Rules,
	filePath: string,
	probe: { site: string, line: number, kind: string, name: string? }
): string?
	if rules.isEmpty then
		return nil
	end
	if rules.sites[probe.site] then
		return "site rule"
	end
	if rules.fileLines[filePath .. ":" .. tostring(probe.line)] then
		return "line rule"
	end
	if probe.kind == "fn" and probe.name and rules.names[probe.name] then
		return "name rule"
	end
	return nil
end

return Ignore
