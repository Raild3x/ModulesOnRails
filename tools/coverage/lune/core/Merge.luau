--!strict
--[=[
	@module core/Merge

	Joins a runtime hit buffer onto a static coverage map, producing per-file and
	package-level metrics. M2 computes line/statement/function coverage; arm,
	decision and condition metrics are added in M3/M4.
]=]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Ignore = require("./Ignore")

local Merge = {}

export type Metric = { covered: number, total: number }

-- A site excluded from the metrics and shown in the suppressed footer instead.
export type SuppressedEntry = {
	file: string,
	line: number,
	site: string,
	kind: string,
	label: string, -- fn name or condition snippet, for the report
	detail: string, -- which rule/marker suppressed it
}

export type Suppressed = {
	ignored: { SuppressedEntry },
	gated: { SuppressedEntry },
	dead: { SuppressedEntry },
}

export type FnEntry = { name: string, line: number, hits: number, isPrivate: boolean }

-- A decision that was reached but only ever went one way.
export type PartialDecision = {
	file: string,
	line: number,
	ctx: string,
	src: string,
	missing: string, -- "never true" | "never false"
}

-- A boolean operand that was evaluated but never varied.
export type PartialCondition = {
	file: string,
	line: number,
	src: string,
	missing: string, -- "never true" | "never false"
}

export type FileReport = {
	path: string,
	lines: Metric,
	statements: Metric,
	functions: Metric,
	branches: Metric,
	decisions: Metric,
	conditions: Metric,
	fnEntries: { FnEntry },
	partials: { PartialDecision },
	condPartials: { PartialCondition },
}

export type Totals = {
	lines: Metric,
	statements: Metric,
	functions: Metric,
	branches: Metric,
	decisions: Metric,
	conditions: Metric,
}

export type Merged = {
	package: string,
	mapSha: string,
	totals: Totals,
	files: { FileReport },
	-- dense probe id -> stable site key, for per-test attribution export
	idToSite: { [number]: string },
	-- sites excluded from the metrics above, grouped by why
	suppressed: Suppressed,
}

local function metric(): Metric
	return { covered = 0, total = 0 }
end

-- The span (gate or dead range) whose inclusive scope covers `line`, or nil.
local function spanForLine(spans: { any }?, line: number): any?
	if spans == nil then
		return nil
	end
	for _, s in spans do
		if line >= s.scope[1] and line <= s.scope[2] then
			return s
		end
	end
	return nil
end

local function addTo(dst: Metric, src: Metric)
	dst.covered += src.covered
	dst.total += src.total
end

--[=[
	@param mapPath -- path to map.json
	@param coverage -- the CoverageResult (hits array indexed by slot id, total, map_sha)
	@param rules -- optional ignore rules; matched sites drop out of the metrics
]=]
function Merge.merge(
	mapPath: string,
	coverage: { hits: { number }, total: number, map_sha: string },
	rules: Ignore.Rules?
): Merged
	local map = serde.decode("json", fs.readFile(mapPath))
	assert(
		map.total_slots == coverage.total,
		`map/hits slot mismatch ({map.total_slots} vs {coverage.total}) -- stale artifacts?`
	)

	local ignoreRules = rules or Ignore.empty()
	local suppressed: Suppressed = { ignored = {}, gated = {}, dead = {} }

	local hits = coverage.hits
	local files: { FileReport } = {}
	local idToSite: { [number]: string } = {}
	for _, file in map.files do
		for _, probe in file.probes do
			idToSite[probe.id] = probe.site
		end
	end
	local pkgTotals: Totals = {
		lines = metric(),
		statements = metric(),
		functions = metric(),
		branches = metric(),
		decisions = metric(),
		conditions = metric(),
	}

	for _, file in map.files do
		local stmts = metric()
		local fns = metric()
		local branches = metric()
		local decisions = metric()
		local conditions = metric()
		local fnEntries: { FnEntry } = {}
		local partials: { Merge.PartialDecision } = {}
		local condPartials: { Merge.PartialCondition } = {}
		-- line coverage derived from statement probes
		local lineHasProbe: { [number]: boolean } = {}
		local lineCovered: { [number]: boolean } = {}

		-- Functions matched by a name rule: their whole body drops out too.
		local ignoredFnIds: { [number]: boolean } = {}
		if not ignoreRules.isEmpty and next(ignoreRules.names) ~= nil then
			for _, probe in file.probes do
				if probe.kind == "fn" and probe.name ~= nil and ignoreRules.names[probe.name] then
					ignoredFnIds[probe.id] = true
				end
			end
		end

		for _, probe in file.probes do
			-- Suppression: excluded from the metrics, listed separately. `probe.fn`
			-- is the enclosing function's id (map field is `fn`), so a name rule
			-- takes the whole body with it.
			local direct = Ignore.matchDirect(ignoreRules, file.path, probe)
			local inherited = probe.fn ~= nil and ignoredFnIds[probe.fn] == true
			if direct ~= nil or inherited then
				if direct ~= nil then
					table.insert(suppressed.ignored, {
						file = file.path,
						line = probe.line,
						site = probe.site,
						kind = probe.kind,
						label = probe.name or probe.src or "",
						detail = direct,
					})
				end
				continue
			end

			-- Env gates and dead code take precedence over counting, but not over
			-- ignore rules.
			local gate = spanForLine(file.gates, probe.line)
			if gate ~= nil then
				table.insert(suppressed.gated, {
					file = file.path,
					line = probe.line,
					site = probe.site,
					kind = probe.kind,
					label = probe.src or probe.name or "",
					detail = gate.note,
				})
				continue
			end

			local dead = spanForLine(file.dead, probe.line)
			if dead ~= nil then
				table.insert(suppressed.dead, {
					file = file.path,
					line = probe.line,
					site = probe.site,
					kind = probe.kind,
					label = probe.src or probe.name or "",
					detail = dead.reason,
				})
				continue
			end

			local count = hits[probe.id] or 0
			if probe.kind == "stmt" then
				stmts.total += 1
				if count > 0 then
					stmts.covered += 1
				end
				lineHasProbe[probe.line] = true
				if count > 0 then
					lineCovered[probe.line] = true
				end
			elseif probe.kind == "fn" then
				fns.total += 1
				if count > 0 then
					fns.covered += 1
				end
				table.insert(fnEntries, {
					name = probe.name or "<anonymous>",
					line = probe.line,
					hits = count,
					isPrivate = probe.is_private == true,
				})
			elseif probe.kind == "decision" then
				-- Two slots: id (true) and id+1 (false). Each is a branch arm.
				local trueHits = hits[probe.id] or 0
				local falseHits = hits[(probe.false_id :: number)] or 0
				branches.total += 2
				if trueHits > 0 then
					branches.covered += 1
				end
				if falseHits > 0 then
					branches.covered += 1
				end
				decisions.total += 1
				if trueHits > 0 and falseHits > 0 then
					decisions.covered += 1
				elseif trueHits > 0 or falseHits > 0 then
					-- reached but one-sided
					table.insert(partials, {
						file = file.path,
						line = probe.line,
						ctx = probe.ctx or "if",
						src = probe.src or "",
						missing = if trueHits > 0 then "never false" else "never true",
					})
				end
			elseif probe.kind == "cond" then
				local trueHits = hits[probe.id] or 0
				local falseHits = hits[(probe.false_id :: number)] or 0
				conditions.total += 1
				if trueHits > 0 and falseHits > 0 then
					conditions.covered += 1
				elseif trueHits > 0 or falseHits > 0 then
					table.insert(condPartials, {
						file = file.path,
						line = probe.line,
						src = probe.src or "",
						missing = if trueHits > 0 then "never false" else "never true",
					})
				end
			end
		end

		local lines = metric()
		for lineNo in lineHasProbe do
			lines.total += 1
			if lineCovered[lineNo] then
				lines.covered += 1
			end
		end

		local fileReport: FileReport = {
			path = file.path,
			lines = lines,
			statements = stmts,
			functions = fns,
			branches = branches,
			decisions = decisions,
			conditions = conditions,
			fnEntries = fnEntries,
			partials = partials,
			condPartials = condPartials,
		}
		table.insert(files, fileReport)
		addTo(pkgTotals.lines, lines)
		addTo(pkgTotals.statements, stmts)
		addTo(pkgTotals.functions, fns)
		addTo(pkgTotals.branches, branches)
		addTo(pkgTotals.decisions, decisions)
		addTo(pkgTotals.conditions, conditions)
	end

	return {
		package = map.package,
		mapSha = map.sha256 or coverage.map_sha,
		totals = pkgTotals,
		files = files,
		idToSite = idToSite,
		suppressed = suppressed,
	}
end

return Merge
