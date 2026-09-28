--!strict
--[=[
	Live progress for a long mutation run, readable from the terminal and from
	another process. The orchestrator rewrites `.coverage/<pkg>/progress.json`
	(write a temp file, then rename over the old one, so a reader never sees a
	half-written file) every couple of seconds with a heartbeat timestamp. A
	running phase whose heartbeat stops advancing means the run died.

	`lune run coverage.luau --status package=<name>` prints `Progress.describe`.
]=]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Progress = {}

local SCHEMA = "tm-coverage-progress/1"
-- The heartbeat is rewritten every ~2s; this much silence means the run is gone.
Progress.STALE_SECONDS = 30

export type Counts = {
	killed: number,
	survived: number,
	timeout: number,
	error: number,
	invalid: number,
}

export type Doc = {
	schema: string,
	package: string,
	-- "baseline" | "mutating" | "done" | "stopped" | "failed"
	phase: string,
	started_at: number,
	heartbeat: number,
	elapsed: number,
	-- decided mutants out of the plan; resumed ones are included in done and the counts
	done: number,
	total: number,
	resumed: number,
	killed: number,
	survived: number,
	timeout: number,
	error: number,
	invalid: number,
	-- detected / (killed + survived + timeout + error) so far, 0..100; nil before the first result
	score: number?,
	-- from this run's own pace; nil until a mutant finishes
	eta_seconds: number?,
	-- files the workers are mutating right now (absent when none)
	current: { string }?,
	jobs: number,
}

export type Input = {
	package: string,
	phase: string,
	startedAt: number,
	now: number,
	total: number,
	-- how many of `counts` came from --resume rather than this run (they don't set the pace)
	resumed: number,
	counts: Counts,
	current: { string },
	jobs: number,
}

function Progress.snapshot(input: Input): Doc
	local c = input.counts
	local done = c.killed + c.survived + c.timeout + c.error + c.invalid
	local run = c.killed + c.survived + c.timeout + c.error
	local elapsed = input.now - input.startedAt
	local ranHere = done - input.resumed
	return {
		schema = SCHEMA,
		package = input.package,
		phase = input.phase,
		started_at = input.startedAt,
		heartbeat = input.now,
		elapsed = elapsed,
		done = done,
		total = input.total,
		resumed = input.resumed,
		killed = c.killed,
		survived = c.survived,
		timeout = c.timeout,
		error = c.error,
		invalid = c.invalid,
		score = if run > 0 then 100 * (run - c.survived) / run else nil,
		eta_seconds = if ranHere > 0 then elapsed / ranHere * (input.total - done) else nil,
		current = if #input.current > 0 then input.current else nil,
		jobs = input.jobs,
	}
end

local function clock(seconds: number): string
	local s = math.floor(seconds + 0.5)
	if s >= 3600 then
		return string.format("%dh%02dm", s // 3600, (s % 3600) // 60)
	end
	return string.format("%dm%02ds", s // 60, s % 60)
end

-- The one-line terminal status.
function Progress.line(doc: Doc): string
	local score = if doc.score ~= nil then string.format("%.1f%%", doc.score) else "-"
	local eta = if doc.eta_seconds ~= nil then clock(doc.eta_seconds) else "?"
	local current = if doc.current ~= nil then "  [" .. table.concat(doc.current, ", ") .. "]" else ""
	return string.format(
		"[mutation] %d/%d  killed %d  survived %d  timeout %d  error %d  score %s  elapsed %s  eta %s%s",
		doc.done,
		doc.total,
		doc.killed,
		doc.survived,
		doc.timeout,
		doc.error,
		score,
		clock(doc.elapsed),
		eta,
		current
	)
end

-- Writes `contents` to `path` via a temp file and a rename, so readers only
-- ever see a whole file.
function Progress.writeAtomic(path: string, contents: string)
	local tmp = path .. ".tmp"
	fs.writeFile(tmp, contents)
	fs.move(tmp, path, true)
end

function Progress.write(path: string, doc: Doc)
	Progress.writeAtomic(path, serde.encode("json", doc, true))
end

function Progress.read(path: string): Doc?
	if not fs.isFile(path) then
		return nil
	end
	local ok, doc = pcall(serde.decode, "json" :: any, fs.readFile(path))
	return if ok and type(doc) == "table" and doc.schema == SCHEMA then doc :: Doc else nil
end

-- True when a run claims to be in flight but its heartbeat has stopped.
function Progress.isStale(doc: Doc, now: number): boolean
	local running = doc.phase == "baseline" or doc.phase == "mutating"
	return running and now - doc.heartbeat > Progress.STALE_SECONDS
end

-- The `--status` report for one package.
function Progress.describe(doc: Doc, now: number): string
	local state = doc.phase
	if Progress.isStale(doc, now) then
		state = string.format("DEAD? (%s, no heartbeat for %ds)", doc.phase, now - doc.heartbeat)
	end
	return string.format(
		"%s: %s, heartbeat %ds ago, %d worker(s)\n%s",
		doc.package,
		state,
		now - doc.heartbeat,
		doc.jobs,
		Progress.line(doc)
	)
end

return Progress
