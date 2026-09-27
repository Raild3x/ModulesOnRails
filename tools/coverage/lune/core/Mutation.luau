--!strict
--[=[
	Mutation-testing logic: plan which mutants to run (coverage filter, operator
	and file filters, deterministic budget sampling), classify child-run
	outcomes, and summarize scores. Pure — all IO (applying mutants, spawning the
	child suite, stashing/restoring files, and the worker threads of a parallel
	run) is injected through `RunDeps`, so the whole loop is testable without
	processes.

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
	-- The `--mutate-files` globs the plan was restricted to, when any.
	filesFilter: { string }?,
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
	-- The `--mutate-files` globs (comma-joined) when the scores cover only a
	-- filtered subset of the package's mutants.
	files_filter: string?,
}

-- `worker` (1..jobs) names the pristine build copy an IO call must touch: a
-- worker only ever applies, runs, and restores inside its own copy, so
-- parallel workers never race on a file.
export type RunDeps = {
	-- Joined path of a mutant's file inside the worker's pristine mutation build.
	filePath: (rel: string, worker: number) -> string,
	readFile: (path: string) -> string,
	writeFile: (path: string, contents: string) -> (),
	-- Applies one mutant in place; "invalid" when the engine refused (exit 3).
	applyMutant: (id: number, worker: number) -> string,
	-- Runs the suite in a fresh child process, honoring the configured timeout.
	runSuite: (worker: number) -> ChildOutcome,
	-- Optional progress callback after each mutant, in completion order.
	progress: ((completed: number, total: number, outcome: MutantOutcome) -> ())?,
	-- Optional early-exit check, polled before each mutant. Returning true stops
	-- the loop cleanly: results so far are kept and summarized.
	shouldStop: (() -> boolean)?,
	-- Worker count (default 1). Above 1, `spawn` and `wait` are required.
	jobs: number?,
	-- Starts a worker thread that runs concurrently with the caller (Lune: task.spawn).
	spawn: ((fn: () -> ()) -> ())?,
	-- Yields the coordinator so running workers can make progress (Lune: task.wait).
	wait: (() -> ())?,
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
	Parses a `--mutate-files` csv into its globs (nil when empty). A leading
	`./` and Windows backslashes are normalized away so globs compare against
	the engine's `/`-separated package-relative paths.
]=]
function Mutation.parseFileGlobs(csv: string?): { string }?
	if csv == nil then
		return nil
	end
	local globs: { string } = {}
	for raw in csv:gmatch("[^,]+") do
		local glob = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/"):gsub("^%./", "")
		if glob ~= "" then
			table.insert(globs, glob)
		end
	end
	return if #globs > 0 then globs else nil
end

-- One glob segment -> an anchored Lua pattern: `*` and `?` stay inside the segment.
local function segmentPattern(segment: string): string
	local escaped = segment:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
	return "^" .. escaped:gsub("%*", "[^/]*"):gsub("%?", "[^/]") .. "$"
end

local function matchSegments(glob: { string }, gi: number, path: { string }, pi: number): boolean
	if gi > #glob then
		return pi > #path
	end
	if glob[gi] == "**" then
		-- `**` spans zero or more whole segments.
		for k = pi, #path + 1 do
			if matchSegments(glob, gi + 1, path, k) then
				return true
			end
		end
		return false
	end
	return pi <= #path and path[pi]:match(segmentPattern(glob[gi])) ~= nil and matchSegments(glob, gi + 1, path, pi + 1)
end

--[=[
	True when the package-relative `path` matches any glob. Segments are
	`/`-separated: `*` and `?` match within one segment, a whole `**` segment
	matches any number of segments, and a glob without wildcards is an exact path.
]=]
function Mutation.matchesFile(globs: { string }, path: string): boolean
	local segments = path:split("/")
	for _, glob in globs do
		if matchSegments(glob:split("/"), 1, segments, 1) then
			return true
		end
	end
	return false
end

--[=[
	Splits mutants into run / no-coverage / sampled-out buckets.

	@param coveredLines -- file path -> { line -> true } from the coverage run
	@param opts.ops -- optional allow-set of operator names
	@param opts.files -- optional `--mutate-files` globs; mutants in other files are dropped
	@param opts.ignoredFiles -- optional set of whole-file-ignored paths; their mutants are dropped
	@param opts.limit -- optional budget; excess mutants are dropped by
	  deterministic stride sampling over the (file, line, id)-sorted list, so a
	  capped run still spreads across files instead of saturating the first one.
]=]
function Mutation.plan(
	mutants: { Mutant },
	coveredLines: { [string]: { [number]: boolean } },
	opts: {
		ops: { [string]: boolean }?,
		limit: number?,
		ignoredFiles: { [string]: boolean }?,
		files: { string }?,
	}
): Plan
	local toRun: { Mutant } = {}
	local noCoverage: { Mutant } = {}
	for _, m in mutants do
		if opts.ops ~= nil and not opts.ops[m.op] then
			continue
		end
		if opts.files ~= nil and not Mutation.matchesFile(opts.files, m.file) then
			continue
		end
		-- Files excluded whole by a `.coverage-ignore` file rule are not scored at all.
		if opts.ignoredFiles ~= nil and opts.ignoredFiles[m.file] then
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

	return { toRun = toRun, noCoverage = noCoverage, sampledOut = sampledOut, filesFilter = opts.files }
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

	With `deps.jobs` > 1, that many workers pull mutants from one shared queue
	in plan order, each inside its own build copy. Outcomes are merged back in
	plan order whatever order they finished in, so a parallel run returns
	exactly what a serial one would. A worker failure outside the per-mutant
	guard lets the other workers finish (and restore) their current mutant,
	then rethrows.

	Returns the outcomes plus whether the loop was stopped early via
	`deps.shouldStop`; partial outcomes are still valid for summarizing.
]=]
function Mutation.run(toRun: { Mutant }, deps: RunDeps): ({ MutantOutcome }, boolean)
	local jobs = math.max(1, math.min(deps.jobs or 1, #toRun))
	local results: { [number]: MutantOutcome } = {}
	local nextIndex = 1
	local completed = 0
	local finished = 0
	local stopped = false
	local failure: any = nil

	local function runOne(m: Mutant, worker: number): MutantOutcome
		local path = deps.filePath(m.file, worker)
		local original = deps.readFile(path)
		local ok, result = pcall(function(): MutantOutcome
			if deps.applyMutant(m.id, worker) ~= "ok" then
				return { mutant = m, status = "invalid", duration = 0 }
			end
			local outcome = deps.runSuite(worker)
			return { mutant = m, status = Mutation.classify(outcome), duration = outcome.duration }
		end)
		-- Restore before anything else; a mutant must never leak into the next
		-- run (or into a later coverage pass over the same build).
		deps.writeFile(path, original)
		return if ok then result :: MutantOutcome else { mutant = m, status = "error", duration = 0 }
	end

	local function work(worker: number)
		local ok, err = pcall(function()
			while failure == nil and not stopped do
				if deps.shouldStop ~= nil and (deps.shouldStop :: any)() then
					stopped = true
					break
				end
				-- Claim the next mutant with no yield between the check and the
				-- claim, so two workers can never take the same one.
				if nextIndex > #toRun then
					break
				end
				local index = nextIndex
				nextIndex += 1
				local outcome = runOne(toRun[index], worker)
				results[index] = outcome
				completed += 1
				if deps.progress ~= nil then
					(deps.progress :: any)(completed, #toRun, outcome)
				end
			end
		end)
		if not ok and failure == nil then
			failure = err
		end
		finished += 1
	end

	if jobs == 1 then
		work(1)
	else
		assert(deps.spawn ~= nil and deps.wait ~= nil, "Mutation.run: jobs > 1 needs spawn and wait")
		for worker = 1, jobs do
			deps.spawn(function()
				work(worker)
			end)
		end
		while finished < jobs do
			deps.wait()
		end
	end
	if failure ~= nil then
		error(failure, 0)
	end

	-- Mutants are claimed in plan order and every claimed one completes, so
	-- the results are a prefix of the plan; walk it in order.
	local outcomes: { MutantOutcome } = {}
	for index = 1, #toRun do
		if results[index] ~= nil then
			table.insert(outcomes, results[index])
		end
	end
	-- A stop signal seen after the queue was already drained stopped nothing.
	return outcomes, stopped and #outcomes < #toRun
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
		files_filter = if plan.filesFilter ~= nil then table.concat(plan.filesFilter, ",") else nil,
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
