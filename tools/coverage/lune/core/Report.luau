--!strict
--[=[
	Renders a merged coverage report to the console. M2 shows the metric table
	and the uncovered-function list; ranked branch/decision/condition findings are
	added in M3/M4.
]=]

local Merge = require("./Merge")
type Merged = Merge.Merged
type Metric = Merge.Metric

local Report = {}

local function pct(m: Metric): number
	if m.total == 0 then
		return 100
	end
	return 100 * m.covered / m.total
end

local function bar(p: number): string
	local width = 20
	local filled = math.floor((p / 100) * width + 0.5)
	return string.rep("\u{2588}", filled) .. string.rep("\u{2591}", width - filled)
end

local function metricLine(label: string, m: Metric): string
	return string.format("  %-11s %5d / %-5d  %5.1f%%  %s", label, m.covered, m.total, pct(m), bar(pct(m)))
end

export type RunInfo = {
	pipeline: string,
	pipelineReason: string,
	tally: { pass: number, fail: number, skipped: number },
	duration: number,
	-- When true, a per-file line-coverage breakdown follows the package totals.
	perFile: boolean?,
}

-- `out` is an injection seam for tests; production callers omit it and print.
function Report.console(merged: Merged, info: RunInfo, out: ((...any) -> ())?)
	local emit: (...any) -> () = out or print
	emit("")
	emit(string.format("coverage \u{2014} %s  [%s: %s]", merged.package, info.pipeline, info.pipelineReason))
	emit(
		string.format(
			"  %d tests: %d pass \u{00b7} %d fail \u{00b7} %d skipped \u{00b7} run %.2fs",
			info.tally.pass + info.tally.fail + info.tally.skipped,
			info.tally.pass,
			info.tally.fail,
			info.tally.skipped,
			info.duration
		)
	)
	emit("")
	emit(metricLine("Lines", merged.totals.lines))
	emit(metricLine("Statements", merged.totals.statements))
	emit(metricLine("Functions", merged.totals.functions))
	emit(metricLine("Branches", merged.totals.branches))
	emit(metricLine("Decisions", merged.totals.decisions))
	if merged.totals.conditions.total > 0 then
		emit(metricLine("Conditions", merged.totals.conditions))
	end

	-- Per-file breakdown, worst line coverage first so gaps surface at the top.
	if info.perFile and #merged.files > 0 then
		local sorted = table.clone(merged.files)
		table.sort(sorted, function(a, b)
			local pa, pb = pct(a.lines), pct(b.lines)
			if pa ~= pb then
				return pa < pb
			end
			return a.path < b.path
		end)
		emit("")
		emit("  Per-file lines (worst first):")
		for _, f in sorted do
			emit(
				string.format(
					"    %-36s %5d / %-5d  %5.1f%%  %s",
					f.path,
					f.lines.covered,
					f.lines.total,
					pct(f.lines),
					bar(pct(f.lines))
				)
			)
		end
	end

	-- Uncovered public functions, ranked by file.
	local uncovered: { { file: string, line: number, name: string, priv: boolean } } = {}
	for _, file in merged.files do
		for _, fn in file.fnEntries do
			if fn.hits == 0 then
				table.insert(uncovered, { file = file.path, line = fn.line, name = fn.name, priv = fn.isPrivate })
			end
		end
	end
	table.sort(uncovered, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)

	local publics = {}
	local privates = 0
	for _, u in uncovered do
		if u.priv then
			privates += 1
		else
			table.insert(publics, u)
		end
	end

	if #publics > 0 then
		emit("")
		emit(string.format("  Functions never entered (%d):", #publics))
		for _, u in publics do
			emit(string.format("    %s:%d  %s", u.file, u.line, u.name))
		end
	end
	if privates > 0 then
		emit(string.format("  \u{2026} %d private/local function(s) also uncovered", privates))
	end

	-- One-sided decisions: reached, but the condition never varied.
	local partials: { Merge.PartialDecision } = {}
	for _, file in merged.files do
		for _, p in file.partials do
			table.insert(partials, p)
		end
	end
	table.sort(partials, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)
	if #partials > 0 then
		emit("")
		emit(string.format("  Decisions never taken both ways (%d):", #partials))
		for _, p in partials do
			local snippet = p.src
			if #snippet > 48 then
				snippet = snippet:sub(1, 45) .. "..."
			end
			emit(string.format("    %s:%d  %s '%s' \u{2014} %s", p.file, p.line, p.ctx, snippet, p.missing))
		end
	end

	-- Boolean operands that never varied.
	local condPartials: { Merge.PartialCondition } = {}
	for _, file in merged.files do
		for _, c in file.condPartials do
			table.insert(condPartials, c)
		end
	end
	table.sort(condPartials, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)
	if #condPartials > 0 then
		emit("")
		emit(string.format("  Conditions that never varied (%d):", #condPartials))
		for _, c in condPartials do
			local snippet = c.src
			if #snippet > 48 then
				snippet = snippet:sub(1, 45) .. "..."
			end
			emit(string.format("    %s:%d  '%s' \u{2014} %s", c.file, c.line, snippet, c.missing))
		end
	end

	-- Loops reached but never seen iterating more than once (multi-iteration
	-- behaviour untested). Informational; does not affect the metrics above.
	if #merged.loops > 0 then
		local sorted = table.clone(merged.loops)
		table.sort(sorted, function(a, b)
			if a.file ~= b.file then
				return a.file < b.file
			end
			return a.line < b.line
		end)
		emit("")
		emit(string.format("  Loops never iterated more than once (%d):", #sorted))
		for _, l in sorted do
			local detail = if l.one > 0 and l.zero == 0
				then "always exactly 1 iteration"
				elseif l.one == 0 then "body never ran (0 iterations)"
				else "only 0 or 1 iteration(s)"
			emit(string.format("    %s:%d  %s loop \u{2014} %s", l.file, l.line, l.ctx, detail))
		end
	end

	-- Locals that could be `const` (only present when run with --suggest-const).
	-- Informational hygiene; never part of the metrics.
	local constCandidates: { Merge.ConstCandidate } = merged.constCandidates or {}
	if #constCandidates > 0 then
		local sorted = table.clone(constCandidates)
		table.sort(sorted, function(a, b)
			if a.file ~= b.file then
				return a.file < b.file
			end
			return a.line < b.line
		end)
		emit("")
		emit(string.format("  Const candidates \u{2014} locals never reassigned (%d):", #sorted))
		for _, c in sorted do
			local label = if c.kind == "local_function"
				then "local function " .. tostring(c.names[1])
				else "local " .. table.concat(c.names, ", ")
			emit(string.format("    %s:%d  %s", c.file, c.line, label))
		end
		if info.pipeline == "lune" then
			emit("  (adopting const moves this package to the Roblox pipeline \u{2014} Lune cannot parse const yet)")
		end
	end

	-- Sites excluded from the metrics above (ignore rules / env gates / dead
	-- code). Kept last so hard findings render above the housekeeping.
	local sup = merged.suppressed
	local total = #sup.ignored + #sup.gated + #sup.dead
	if total > 0 then
		emit("")
		emit(string.format("  Suppressed \u{2014} excluded from the metrics above (%d):", total))
		local function line(e: Merge.SuppressedEntry): string
			local label = if e.label ~= "" then e.label else e.kind
			if #label > 48 then
				label = label:sub(1, 45) .. "..."
			end
			return string.format("    %s:%d  %s", e.file, e.line, label)
		end
		if #sup.ignored > 0 then
			emit(string.format("  \u{00b7} ignore rule (%d):", #sup.ignored))
			for _, e in sup.ignored do
				emit(line(e))
			end
		end
		if #sup.gated > 0 then
			emit(string.format("  \u{00b7} env-gated, unreachable in edit mode (%d):", #sup.gated))
			for _, e in sup.gated do
				emit(line(e))
			end
		end
		if #sup.dead > 0 then
			emit(string.format("  \u{00b7} dead code (%d):", #sup.dead))
			for _, e in sup.dead do
				emit(line(e))
			end
		end
	end
end

--[=[
	Renders the mutation-testing summary. Printed separately from the coverage
	report because the mutation phase runs after it (and can take a while).
	`totals`/`survivors` come from core/Mutation; `out` is the test seam.
]=]
function Report.mutation(packageName: string, totals: any, survivors: { any }, out: ((...any) -> ())?)
	local emit: (...any) -> () = out or print
	emit("")
	emit(string.format("mutation \u{2014} %s", packageName))
	emit(
		string.format(
			"  %d mutants: %d run \u{00b7} %d killed \u{00b7} %d survived \u{00b7} %d timeout \u{00b7} %d error",
			totals.total,
			totals.run,
			totals.killed,
			totals.survived,
			totals.timeout,
			totals.error
		)
	)
	emit(string.format("  %-11s %5.1f%%  %s", "Score", totals.score_covered, bar(totals.score_covered)))
	if totals.no_coverage > 0 then
		emit(
			string.format(
				"  %-11s %5.1f%%  incl. %d mutant(s) on lines no test executes",
				"Score (all)",
				totals.score_total,
				totals.no_coverage
			)
		)
	end
	if totals.sampled_out > 0 then
		emit(string.format("  \u{2026} %d mutant(s) sampled out by --mutate-limit", totals.sampled_out))
	end
	if totals.invalid > 0 then
		emit(string.format("  \u{2026} %d mutant(s) did not parse (invalid)", totals.invalid))
	end
	if totals.not_run ~= nil and totals.not_run > 0 then
		emit(string.format("  \u{2026} stopped early: %d planned mutant(s) not run", totals.not_run))
	end

	if #survivors > 0 then
		emit("")
		emit(string.format("  Surviving mutants \u{2014} tests pass despite the change (%d):", #survivors))
		for _, s in survivors do
			local change = if s.replacement == ""
				then string.format("'%s' removed", s.original)
				else string.format("'%s' \u{2192} '%s'", s.original, s.replacement)
			emit(string.format("    %s:%d  %s %s", s.file, s.line, s.op, change))
		end
	end
end

--[=[
	Renders the ranked next-steps list from core/Recommend. `total` is the
	pre-cap count for the "N shown of M" header; `out` is the test seam.
]=]
function Report.recommendations(recs: { any }, total: number, out: ((...any) -> ())?)
	local emit: (...any) -> () = out or print
	if #recs == 0 then
		return
	end
	emit("")
	if total > #recs then
		emit(string.format("  Recommended next steps (top %d of %d):", #recs, total))
	else
		emit(string.format("  Recommended next steps (%d):", #recs))
	end
	for i, r in recs do
		if r.file ~= nil then
			emit(string.format("    %d. %s:%d  %s", i, r.file, r.line or 0, r.action))
		else
			emit(string.format("    %d. %s", i, r.action))
		end
	end
end

return Report
