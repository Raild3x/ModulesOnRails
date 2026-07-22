--!strict
--[=[
	@module core/Recommend

	Turns a merged coverage report (and, when available, mutation results) into
	a short ranked list of concrete next steps. Pure post-processing — no IO —
	consumed by Report (final console section) and CoverageJson.

	Ranking, strongest signal first:
	  1 failing_tests       red suite invalidates everything below
	  2 mutation_survivor   a change the tests provably cannot detect
	  3 uncovered_function  public API never entered
	  4 decision_partial    a branch never taken one way
	  5 condition_partial   a boolean operand that never varied
	  6 loop_iteration      multi-iteration behaviour untested
	  7 const_candidate     hygiene, aggregated into one line
]=]

local Merge = require("./Merge")

local Recommend = {}

-- The console/JSON list is capped so it stays a to-do list, not a dump.
local MAX_RECOMMENDATIONS = 10

export type Recommendation = {
	priority: number,
	category: string,
	file: string?,
	line: number?,
	action: string,
}

export type Context = {
	tally: { pass: number, fail: number, skipped: number },
	-- Mutation survivors ({ file, line, op, original, replacement }), when the
	-- mutation phase ran.
	survivors: { any }?,
}

local function snippet(src: string): string
	if #src > 40 then
		return src:sub(1, 37) .. "..."
	end
	return src
end

--[=[
	Builds the ranked recommendation list. Returns at most MAX_RECOMMENDATIONS
	entries plus the total number generated (for an "N shown of M" header).
]=]
function Recommend.build(merged: Merge.Merged, ctx: Context): ({ Recommendation }, number)
	local recs: { Recommendation } = {}

	if ctx.tally.fail > 0 then
		table.insert(recs, {
			priority = 1,
			category = "failing_tests",
			action = string.format(
				"Fix the %d failing test(s) first -- coverage and mutation numbers on a red suite are unreliable.",
				ctx.tally.fail
			),
		})
	end

	local survivors: { any } = ctx.survivors or {}
	for _, s in survivors do
		local action = if s.replacement == ""
			then string.format("Add an assertion that fails when '%s' is removed (surviving mutant).", s.original)
			else string.format(
				"Add an assertion sensitive to '%s' here -- the tests still pass when it becomes '%s'.",
				s.original,
				s.replacement
			)
		table.insert(recs, {
			priority = 2,
			category = "mutation_survivor",
			file = s.file,
			line = s.line,
			action = action,
		})
	end

	for _, file in merged.files do
		for _, fn in file.fnEntries do
			if fn.hits == 0 and not fn.isPrivate then
				table.insert(recs, {
					priority = 3,
					category = "uncovered_function",
					file = file.path,
					line = fn.line,
					action = string.format(
						"Add a test that calls %s(%s).",
						fn.name,
						table.concat(fn.params or {}, ", ")
					),
				})
			end
		end

		for _, p in file.partials do
			local action: string
			if p.ctx == "while" and p.missing == "never false" then
				action = string.format(
					"Add a test where the while condition '%s' eventually turns false (the loop's exit path is untested).",
					snippet(p.src)
				)
			elseif p.missing == "never true" then
				action = string.format("Add a test where the %s condition '%s' holds.", p.ctx, snippet(p.src))
			else
				action = string.format("Add a test where the %s condition '%s' fails.", p.ctx, snippet(p.src))
			end
			table.insert(recs, {
				priority = 4,
				category = "decision_partial",
				file = file.path,
				line = p.line,
				action = action,
			})
		end

		for _, c in file.condPartials do
			local side = if c.missing == "never true" then "true" else "false"
			table.insert(recs, {
				priority = 5,
				category = "condition_partial",
				file = file.path,
				line = c.line,
				action = string.format(
					"Add a test where the operand '%s' is %s while the rest of the decision still varies.",
					snippet(c.src),
					side
				),
			})
		end
	end

	for _, l in merged.loops do
		table.insert(recs, {
			priority = 6,
			category = "loop_iteration",
			file = l.file,
			line = l.line,
			action = string.format("Add a test where this %s loop runs at least twice.", l.ctx),
		})
	end

	local constCandidates = merged.constCandidates or {}
	if #constCandidates > 0 then
		table.insert(recs, {
			priority = 7,
			category = "const_candidate",
			action = string.format(
				"Hygiene: %d local(s) are never reassigned and could be `const` (see the const-candidates section).",
				#constCandidates
			),
		})
	end

	table.sort(recs, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		local af, bf = a.file or "", b.file or ""
		if af ~= bf then
			return af < bf
		end
		return (a.line or 0) < (b.line or 0)
	end)

	local total = #recs
	if total > MAX_RECOMMENDATIONS then
		local capped = table.move(recs, 1, MAX_RECOMMENDATIONS, 1, {})
		return capped, total
	end
	return recs, total
end

return Recommend
