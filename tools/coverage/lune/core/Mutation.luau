--!strict
--[=[
	Mutation-testing logic: plan which mutants to run (coverage filter, operator
	filter, deterministic budget sampling), classify child-run outcomes, and
	summarize scores. Pure — all IO (applying mutants, spawning the child suite,
	stashing/restoring files) is injected through `RunDeps`, so the whole loop is
	testable without processes.

	Status vocabulary:
	  killed      the suite failed -> the tests detect this mutation
	  timeout     the suite hung and was killed (counts as detected)
	  error       the suite crashed / no sentinel (counts as detected)
	  survived    every test passed -> a real gap in the tests
	  invalid     the mutant did not parse (engine refused to apply it)
	  no coverage line never executed by any test; not run (auto-undetected)
]=]

local Mutation = {}

export type Tally = { pass: number, fail: number, skipped: number }

export type Mutant = {
	id: number,
	op: string,
	file: string,
	line: number,
	col: number,
	original: string,
	replacement: string,
	site: string,
}

-- What one child suite run looked like from the parent.
export type ChildOutcome = {
	timedOut: boolean,
	ok: boolean,
	tally: Tally?,
	duration: number,
}

export type MutantOutcome = {
	mutant: Mutant,
	status: string, -- "killed" | "survived" | "timeout" | "error" | "invalid"
	duration: number,
}

export type Plan = {
	toRun: { Mutant },
	noCoverage: { Mutant },
	sampledOut: { Mutant },
}

export type Totals = {
	total: number,
	run: number,
	killed: number,
	survived: number,
	timeout: number,
	error: number,
	invalid: number,
	no_coverage: number,
	sampled_out: number,
	-- planned mutants never attempted (the loop was stopped early)
	not_run: number,
	-- percentages 0..100; detected = killed + timeout + error
	score_covered: number, -- detected / run
	score_total: number, -- detected / (run + no_coverage)
}

export type RunDeps = {
	-- Joined path of a mutant's file inside the pristine mutation build.
	filePath: (rel: string) -> string,
	readFile: (path: string) -> string,
	writeFile: (path: string, contents: string) -> (),
	-- Applies one mutant in place; "invalid" when the engine refused (exit 3).
	applyMutant: (id: number) -> string,
	-- Runs the suite in a fresh child process, honoring the configured timeout.
	runSuite: () -> ChildOutcome,
	-- Optional progress callback after each mutant.
	progress: ((index: number, total: number, outcome: MutantOutcome) -> ())?,
	-- Optional early-exit check, polled before each mutant. Returning true stops
	-- the loop cleanly: results so far are kept and summarized.
	shouldStop: (() -> boolean)?,
}

--[=[
	Flattens an engine mutants.json document into one list with `file` stamped
	on every mutant.
]=]
function Mutation.flatten(doc: any): { Mutant }
	local out: { Mutant } = {}
	for _, file in doc.files do
		for _, m in file.mutants do
			table.insert(out, {
				id = m.id,
				op = m.op,
				file = file.path,
				line = m.line,
				col = m.col,
				original = m.original,
				replacement = m.replacement,
				site = m.site,
			})
		end
	end
	return out
end

--[=[
	Splits mutants into run / no-coverage / sampled-out buckets.

	@param coveredLines -- file path -> { line -> true } from the coverage run
	@param opts.ops -- optional allow-set of operator names
	@param opts.limit -- optional budget; excess mutants are dropped by
	  deterministic stride sampling over the (file, line, id)-sorted list, so a
	  capped run still spreads across files instead of saturating the first one.
]=]
function Mutation.plan(
	mutants: { Mutant },
	coveredLines: { [string]: { [number]: boolean } },
	opts: { ops: { [string]: boolean }?, limit: number? }
): Plan
	local toRun: { Mutant } = {}
	local noCoverage: { Mutant } = {}
	for _, m in mutants do
		if opts.ops ~= nil and not opts.ops[m.op] then
			continue
		end
		local lines = coveredLines[m.file]
		if lines ~= nil and lines[m.line] == true then
			table.insert(toRun, m)
		else
			table.insert(noCoverage, m)
		end
	end

	table.sort(toRun, function(a: Mutant, b: Mutant)
		if a.file ~= b.file then
			return a.file < b.file
		end
		if a.line ~= b.line then
			return a.line < b.line
		end
		return a.id < b.id
	end)

	local sampledOut: { Mutant } = {}
	local limit = opts.limit
	if limit ~= nil and limit > 0 and #toRun > limit then
		local sampled: { Mutant } = {}
		local picked: { [number]: boolean } = {}
		local step = #toRun / limit
		for k = 0, limit - 1 do
			local idx = math.floor(k * step) + 1
			table.insert(sampled, toRun[idx])
			picked[idx] = true
		end
		for idx, m in toRun do
			if not picked[idx] then
				table.insert(sampledOut, m)
			end
		end
		toRun = sampled
	end

	return { toRun = toRun, noCoverage = noCoverage, sampledOut = sampledOut }
end

--[=[
	Classifies one child run. Timeout is checked first: a killed child also
	reports a bad exit, and the hang is the finding.
]=]
function Mutation.classify(outcome: ChildOutcome): string
	if outcome.timedOut then
		return "timeout"
	end
	if not outcome.ok or outcome.tally == nil then
		return "error"
	end
	if (outcome.tally :: Tally).fail > 0 then
		return "killed"
	end
	return "survived"
end

--[=[
	Extracts the `[[TM-MUT]]{...}` tally from a child's stdout, or nil when the
	sentinel is missing (the child crashed before printing it).
]=]
function Mutation.parseSentinel(stdout: string, decode: (json: string) -> any): Tally?
	for line in stdout:gmatch("[^\r\n]+") do
		local payload = line:match("^%[%[TM%-MUT%]%](.+)$")
		if payload ~= nil then
			local ok, tally = pcall(decode, payload)
			if ok and type(tally) == "table" and type(tally.fail) == "number" then
				return tally :: Tally
			end
			return nil
		end
	end
	return nil
end

--[=[
	The mutant loop: stash the target file's bytes, apply, run the suite in a
	child process, classify, and ALWAYS restore the pristine bytes before moving
	on — even when something throws mid-mutant.

	Returns the outcomes plus whether the loop was stopped early via
	`deps.shouldStop`; partial outcomes are still valid for summarizing.
]=]
function Mutation.run(toRun: { Mutant }, deps: RunDeps): ({ MutantOutcome }, boolean)
	local outcomes: { MutantOutcome } = {}
	local stopped = false
	for index, m in toRun do
		if deps.shouldStop ~= nil and (deps.shouldStop :: any)() then
			stopped = true
			break
		end
		local path = deps.filePath(m.file)
		local original = deps.readFile(path)
		local ok, result = pcall(function(): MutantOutcome
			if deps.applyMutant(m.id) ~= "ok" then
				return { mutant = m, status = "invalid", duration = 0 }
			end
			local outcome = deps.runSuite()
			return { mutant = m, status = Mutation.classify(outcome), duration = outcome.duration }
		end)
		-- Restore before anything else; a mutant must never leak into the next
		-- run (or into a later coverage pass over the same build).
		deps.writeFile(path, original)
		local outcome: MutantOutcome = if ok
			then result :: MutantOutcome
			else { mutant = m, status = "error", duration = 0 }
		table.insert(outcomes, outcome)
		if deps.progress ~= nil then
			(deps.progress :: any)(index, #toRun, outcome)
		end
	end
	return outcomes, stopped
end

--[=[
	Score math. `run` excludes invalid mutants; `score_total` widens the
	denominator with no-coverage mutants — the gap between the two scores is the
	part of the mutation story explained by plain coverage gaps.
]=]
function Mutation.summarize(plan: Plan, outcomes: { MutantOutcome }): Totals
	local counts: { [string]: number } = { killed = 0, survived = 0, timeout = 0, ["error"] = 0, invalid = 0 }
	for _, o in outcomes do
		counts[o.status] += 1
	end
	local run = counts.killed + counts.survived + counts.timeout + counts["error"]
	local detected = counts.killed + counts.timeout + counts["error"]
	local noCoverage = #plan.noCoverage
	local sampledOut = #plan.sampledOut
	-- Planned but never attempted: the loop was stopped early.
	local notRun = math.max(0, #plan.toRun - #outcomes)
	local function pct(num: number, denom: number): number
		if denom == 0 then
			return 100
		end
		return 100 * num / denom
	end
	return {
		total = run + counts.invalid + noCoverage + sampledOut + notRun,
		run = run,
		killed = counts.killed,
		survived = counts.survived,
		timeout = counts.timeout,
		error = counts["error"],
		invalid = counts.invalid,
		no_coverage = noCoverage,
		sampled_out = sampledOut,
		not_run = notRun,
		score_covered = pct(detected, run),
		score_total = pct(detected, run + noCoverage),
	}
end

--[=[
	The survived mutants from a finished run, in report order.
]=]
function Mutation.survivors(outcomes: { MutantOutcome }): { Mutant }
	local out: { Mutant } = {}
	for _, o in outcomes do
		if o.status == "survived" then
			table.insert(out, o.mutant)
		end
	end
	table.sort(out, function(a: Mutant, b: Mutant)
		if a.file ~= b.file then
			return a.file < b.file
		end
		if a.line ~= b.line then
			return a.line < b.line
		end
		return a.id < b.id
	end)
	return out
end

return Mutation
