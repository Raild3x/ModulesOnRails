--!strict
--[=[
	@module core/Report

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
}

function Report.console(merged: Merged, info: RunInfo)
	print("")
	print(string.format("coverage \u{2014} %s  [%s: %s]", merged.package, info.pipeline, info.pipelineReason))
	print(string.format(
		"  %d tests: %d pass \u{00b7} %d fail \u{00b7} %d skipped \u{00b7} run %.2fs",
		info.tally.pass + info.tally.fail + info.tally.skipped,
		info.tally.pass,
		info.tally.fail,
		info.tally.skipped,
		info.duration
	))
	print("")
	print(metricLine("Lines", merged.totals.lines))
	print(metricLine("Statements", merged.totals.statements))
	print(metricLine("Functions", merged.totals.functions))
	print(metricLine("Branches", merged.totals.branches))
	print(metricLine("Decisions", merged.totals.decisions))
	if merged.totals.conditions.total > 0 then
		print(metricLine("Conditions", merged.totals.conditions))
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
		print("")
		print(string.format("  Functions never entered (%d):", #publics))
		for _, u in publics do
			print(string.format("    %s:%d  %s", u.file, u.line, u.name))
		end
	end
	if privates > 0 then
		print(string.format("  \u{2026} %d private/local function(s) also uncovered", privates))
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
		print("")
		print(string.format("  Decisions never taken both ways (%d):", #partials))
		for _, p in partials do
			local snippet = p.src
			if #snippet > 48 then
				snippet = snippet:sub(1, 45) .. "..."
			end
			print(string.format("    %s:%d  %s '%s' \u{2014} %s", p.file, p.line, p.ctx, snippet, p.missing))
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
		print("")
		print(string.format("  Conditions that never varied (%d):", #condPartials))
		for _, c in condPartials do
			local snippet = c.src
			if #snippet > 48 then
				snippet = snippet:sub(1, 45) .. "..."
			end
			print(string.format("    %s:%d  '%s' \u{2014} %s", c.file, c.line, snippet, c.missing))
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
		print("")
		print(string.format("  Loops never iterated more than once (%d):", #sorted))
		for _, l in sorted do
			local detail = if l.one > 0 and l.zero == 0
				then "always exactly 1 iteration"
				elseif l.one == 0 then "body never ran (0 iterations)"
				else "only 0 or 1 iteration(s)"
			print(string.format("    %s:%d  %s loop \u{2014} %s", l.file, l.line, l.ctx, detail))
		end
	end

	-- Sites excluded from the metrics above (ignore rules / env gates / dead code).
	local sup = merged.suppressed
	local total = #sup.ignored + #sup.gated + #sup.dead
	if total > 0 then
		print("")
		print(string.format("  Suppressed \u{2014} excluded from the metrics above (%d):", total))
		local function line(e: Merge.SuppressedEntry): string
			local label = if e.label ~= "" then e.label else e.kind
			if #label > 48 then
				label = label:sub(1, 45) .. "..."
			end
			return string.format("    %s:%d  %s", e.file, e.line, label)
		end
		if #sup.ignored > 0 then
			print(string.format("  \u{00b7} ignore rule (%d):", #sup.ignored))
			for _, e in sup.ignored do
				print(line(e))
			end
		end
		if #sup.gated > 0 then
			print(string.format("  \u{00b7} env-gated, unreachable in edit mode (%d):", #sup.gated))
			for _, e in sup.gated do
				print(line(e))
			end
		end
		if #sup.dead > 0 then
			print(string.format("  \u{00b7} dead code (%d):", #sup.dead))
			for _, e in sup.dead do
				print(line(e))
			end
		end
	end
end

return Report
