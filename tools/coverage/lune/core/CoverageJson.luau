--!strict
--[=[
	@module core/CoverageJson

	Builds the stable, versioned `coverage.json` document from a merged report,
	run metadata, and (optionally) per-test attribution keyed by stable site keys.
]=]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Merge = require("./Merge")
type Merged = Merge.Merged

local CoverageJson = {}

local SCHEMA = "tm-coverage-report/1"

export type BuildInfo = {
	classification: string,
	classificationReason: string,
	env: string,
	duration: number,
	tally: { pass: number, fail: number, skipped: number },
}

local function metricDoc(m: Merge.Metric): { covered: number, total: number, pct: number }
	local pct = if m.total == 0 then 100 else 100 * m.covered / m.total
	return { covered = m.covered, total = m.total, pct = pct }
end

--[=[
	@param merged -- the merged report
	@param info -- run metadata
	@param perTest -- optional { id, status, probes(dense ids) } list to site-key
]=]
function CoverageJson.build(merged: Merged, info: BuildInfo, perTest: { any }?): { [string]: any }
	-- Const candidates live flat on Merged; group them per file for findings.
	local constByFile: { [string]: { Merge.ConstCandidate } } = {}
	local allConstCandidates: { Merge.ConstCandidate } = merged.constCandidates or {}
	for _, c in allConstCandidates do
		local list = constByFile[c.file]
		if list == nil then
			list = {}
			constByFile[c.file] = list
		end
		table.insert(list, c)
	end

	local files = {}
	for _, f in merged.files do
		local findings: { any } = {}
		local fileConstCandidates: { Merge.ConstCandidate } = constByFile[f.path] or {}
		for _, c in fileConstCandidates do
			table.insert(findings, {
				type = "const_candidate",
				line = c.line,
				kind = c.kind,
				names = c.names,
				site = c.site,
				detail = "never reassigned",
			})
		end
		for _, p in f.partials do
			table.insert(findings, {
				type = "decision_partial",
				line = p.line,
				ctx = p.ctx,
				src = p.src,
				detail = p.missing,
			})
		end
		for _, c in f.condPartials do
			table.insert(findings, {
				type = "condition_never_varied",
				line = c.line,
				src = c.src,
				detail = c.missing,
			})
		end
		local fns = {}
		for _, fn in f.fnEntries do
			if fn.hits == 0 then
				table.insert(findings, {
					type = "function_never_entered",
					line = fn.line,
					name = fn.name,
					detail = if fn.isPrivate then "private" else "public",
				})
			end
			table.insert(fns, { name = fn.name, line = fn.line, hits = fn.hits })
		end
		table.insert(files, {
			path = f.path,
			totals = {
				lines = metricDoc(f.lines),
				statements = metricDoc(f.statements),
				functions = metricDoc(f.functions),
				branches = metricDoc(f.branches),
				decisions = metricDoc(f.decisions),
				conditions = metricDoc(f.conditions),
			},
			functions = fns,
			findings = findings,
		})
	end

	local doc: { [string]: any } = {
		schema = SCHEMA,
		package = merged.package,
		classification = info.classification,
		classification_reason = info.classificationReason,
		run = {
			env = info.env,
			duration = info.duration,
			status_tally = info.tally,
		},
		totals = {
			lines = metricDoc(merged.totals.lines),
			statements = metricDoc(merged.totals.statements),
			functions = metricDoc(merged.totals.functions),
			branches = metricDoc(merged.totals.branches),
			decisions = metricDoc(merged.totals.decisions),
			conditions = metricDoc(merged.totals.conditions),
		},
		files = files,
	}

	local function supList(entries: { Merge.SuppressedEntry })
		local out = {}
		for _, e in entries do
			table.insert(out, { file = e.file, line = e.line, site = e.site, kind = e.kind, detail = e.detail })
		end
		return out
	end
	doc.suppressed = {
		ignored = supList(merged.suppressed.ignored),
		env_gated = supList(merged.suppressed.gated),
		dead = supList(merged.suppressed.dead),
	}

	local loops = {}
	for _, l in merged.loops do
		table.insert(loops, {
			file = l.file,
			line = l.line,
			ctx = l.ctx,
			zero = l.zero,
			one = l.one,
			many = l.many,
		})
	end
	doc.loops_single_iteration = loops

	if perTest then
		local out = {}
		for _, t in perTest do
			local sites = {}
			for _, id in t.probes do
				local site = merged.idToSite[id]
				if site then
					table.insert(sites, site)
				end
			end
			table.insert(out, { id = t.id, status = t.status, sites = sites })
		end
		doc.per_test = out
	end

	return doc
end

function CoverageJson.write(path: string, doc: { [string]: any })
	fs.writeFile(path, serde.encode("json", doc, true))
end

return CoverageJson
