--!strict
--[=[
	@module tools/ci/OpenCloud

	Generic Roblox Open Cloud "Luau Execution Session" driver. Transport only --
	it knows nothing about tests or coverage. Given a built place file and a Luau
	script, it publishes the place, runs the script on a real Roblox server, waits
	for the task to finish, and returns the task's terminal state plus its captured
	log output as one string for the caller to parse.

	Both the standalone test runner (`tools/ci/run_tests.luau`) and the coverage
	system's Open Cloud runner (`tools/coverage/lune/core/OpenCloudRunner.luau`)
	build on this.

	Required environment (see `configFromEnv`):
		ROBLOX_API_KEY     - Open Cloud API key with these scopes for the place:
		                       * universe-places:write
		                       * universe.place.luau-execution-session:write
		                       * universe.place.luau-execution-session:read
		ROBLOX_UNIVERSE_ID - The universe (experience) ID.
		ROBLOX_PLACE_ID    - The place ID within that universe.

	Adapted from a reference driver (`test/REFERENCE_CI/runOpenCloud.luau`); the
	key difference is that this module RETURNS the joined logs instead of printing
	them, so callers can parse a sentinel payload (coverage) or a PASS/FAIL report
	(plain runner) out of them.
]=]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local OpenCloud = {}

local API_BASE = "https://apis.roblox.com"
local POLL_INTERVAL_SECONDS = 5
local POLL_TIMEOUT_SECONDS = 360 -- a little over the 5-minute per-task limit

export type Config = {
	apiKey: string,
	universeId: string,
	placeId: string,
}

export type ExecuteResult = {
	-- One of "COMPLETE" | "FAILED" | "CANCELLED".
	state: string,
	-- Every task log message, in order, joined by "\n".
	logs: string,
	-- Present when the task did not complete successfully.
	error: { code: string?, message: string? }?,
	-- Wall-clock seconds from task creation to terminal state.
	duration: number,
}

--
-- Environment / config
--

--[=[
	True when an Open Cloud API key is present in the environment. Callers use this
	to decide whether the Open Cloud path is available (e.g. the coverage CLI
	defaults to Open Cloud when a key is set, Studio otherwise).
]=]
function OpenCloud.isConfigured(): boolean
	local key = process.env.ROBLOX_API_KEY
	return key ~= nil and key ~= ""
end

--[=[
	Reads and validates the three required env vars, erroring with an actionable
	message if any is missing.
]=]
function OpenCloud.configFromEnv(): Config
	local function requireEnv(name: string): string
		local value = process.env[name]
		if value == nil or value == "" then
			error(`Missing required environment variable: {name}`, 0)
		end
		return value
	end
	return {
		apiKey = requireEnv("ROBLOX_API_KEY"),
		universeId = requireEnv("ROBLOX_UNIVERSE_ID"),
		placeId = requireEnv("ROBLOX_PLACE_ID"),
	}
end

--
-- HTTP helpers
--

local function decode(body: string): any
	return serde.decode("json", body)
end

local function describeResponse(response: any): string
	return `HTTP {response.statusCode} {response.statusMessage}\n{response.body}`
end

--
-- 1. Publish the built place as a new version
--

local function publishPlace(config: Config, placePath: string): number
	if not fs.isFile(placePath) then
		error(`Built place "{placePath}" not found.`, 0)
	end

	print(`[open-cloud] Publishing {placePath} to place {config.placeId}...`)
	local response = net.request({
		url = `{API_BASE}/universes/v1/{config.universeId}/places/{config.placeId}/versions?versionType=Published`,
		method = "POST",
		headers = {
			["x-api-key"] = config.apiKey,
			["Content-Type"] = "application/octet-stream",
		},
		body = fs.readFile(placePath),
	})

	if not response.ok then
		error(`Failed to publish place version: {describeResponse(response)}`, 0)
	end

	local versionNumber = decode(response.body).versionNumber
	print(`[open-cloud] Published place version {versionNumber}.`)
	return versionNumber
end

--
-- 2. Create the Luau Execution task
--

local function createTask(config: Config, scriptSource: string): string
	print("[open-cloud] Creating Luau Execution task...")
	local response = net.request({
		url = `{API_BASE}/cloud/v2/universes/{config.universeId}/places/{config.placeId}/luau-execution-session-tasks`,
		method = "POST",
		headers = {
			["x-api-key"] = config.apiKey,
			["Content-Type"] = "application/json",
		},
		body = serde.encode("json", { script = scriptSource }),
	})

	if not response.ok then
		error(`Failed to create execution task: {describeResponse(response)}`, 0)
	end

	-- `path` is the canonical resource path, e.g.
	-- universes/123/places/456/luau-execution-sessions/<sid>/tasks/<tid>
	local path = decode(response.body).path
	if path == nil then
		error(`Task creation returned no path: {response.body}`, 0)
	end
	print(`[open-cloud] Created task: {path}`)
	return path
end

--
-- 3. Poll until terminal
--

local TERMINAL_STATES = {
	COMPLETE = true,
	FAILED = true,
	CANCELLED = true,
}

local function getTask(config: Config, path: string): any
	local response = net.request({
		url = `{API_BASE}/cloud/v2/{path}`,
		method = "GET",
		headers = { ["x-api-key"] = config.apiKey },
	})
	if not response.ok then
		error(`Failed to get task state: {describeResponse(response)}`, 0)
	end
	return decode(response.body)
end

local function waitForTask(config: Config, path: string): any
	local elapsed = 0
	while true do
		local taskResource = getTask(config, path)
		local state = taskResource.state
		if TERMINAL_STATES[state] then
			print(`[open-cloud] Task reached terminal state: {state}`)
			return taskResource
		end

		if elapsed >= POLL_TIMEOUT_SECONDS then
			error(`Timed out after {POLL_TIMEOUT_SECONDS}s waiting for task (last state: {state}).`, 0)
		end

		print(`[open-cloud] Task state: {state} (waiting {POLL_INTERVAL_SECONDS}s)...`)
		task.wait(POLL_INTERVAL_SECONDS)
		elapsed += POLL_INTERVAL_SECONDS
	end
end

--
-- 4. Fetch logs (paginated) and return them joined
--

local function fetchLogs(config: Config, path: string): string
	local messages: { string } = {}
	local pageToken: string? = nil
	repeat
		local query = "?view=FLAT&maxPageSize=10000"
		if pageToken ~= nil then
			query ..= `&pageToken={pageToken}`
		end

		local response = net.request({
			url = `{API_BASE}/cloud/v2/{path}/logs{query}`,
			method = "GET",
			headers = { ["x-api-key"] = config.apiKey },
		})
		if not response.ok then
			-- A logs fetch failure shouldn't mask the task's own result; surface it
			-- inline and stop paginating.
			table.insert(messages, `[open-cloud] (failed to fetch logs: {describeResponse(response)})`)
			break
		end

		local decoded = decode(response.body)
		for _, logChunk in decoded.luauExecutionSessionTaskLogs or {} do
			for _, message in logChunk.messages or {} do
				table.insert(messages, message)
			end
		end
		pageToken = decoded.nextPageToken
	until pageToken == nil or pageToken == ""

	return table.concat(messages, "\n")
end

--
-- Public entry point
--

--[=[
	Publishes `placePath`, runs `scriptSource` on a real Roblox server via the Luau
	Execution Session API, waits for completion, and returns the terminal state and
	captured logs. Uses `config` if given, otherwise reads it from the environment.

	This never errors on test failure (that is conveyed through `state`/`logs` for
	the caller to interpret); it only errors on transport/setup failures (missing
	place file, HTTP errors, timeout).
]=]
function OpenCloud.execute(placePath: string, scriptSource: string, config: Config?): ExecuteResult
	local cfg = config or OpenCloud.configFromEnv()

	publishPlace(cfg, placePath)

	local start = os.clock()
	local taskPath = createTask(cfg, scriptSource)
	local finalTask = waitForTask(cfg, taskPath)
	local duration = os.clock() - start

	local logs = fetchLogs(cfg, taskPath)

	return {
		state = finalTask.state,
		logs = logs,
		error = finalTask.error,
		duration = duration,
	}
end

return OpenCloud
