--!strict
-- Authors: Logan Hunt (Raildex)
-- Retry utility with configurable backoff strategies
--
-- Provides synchronous and asynchronous retry mechanisms with simple backoff strategies:
-- - Constant: Fixed delay between retries (baseDelay)
-- - Linear: Delay increases linearly (baseDelay * attempt)
-- - Exponential: Delay doubles each attempt (baseDelay * 2^(attempt-1))
--
-- Alternatively, provide a custom backoff function for complete control.

--// Imports //--
local Packages = script.Parent.Parent
local Promise = require(Packages.Promise)

--// Types //--
export type BackoffStrategy = "Constant" | "Linear" | "Exponential"
export type BackoffFunction = (baseDelay: number, attempt: number) -> number

export type RetryConfig = {
	-- Maximum number of retry attempts (default: 3)
	maxAttempts: number?,
	-- Base delay in seconds before first retry (default: 0.5)
	baseDelay: number?,
	-- Maximum delay cap in seconds (default: 30)
	maxDelay: number?,
	-- Backoff strategy: predefined name or custom function (default: "Exponential")
	-- Predefined: "Constant" | "Linear" | "Exponential"
	-- Custom: (baseDelay, attempt) -> delay
	backoff: (BackoffStrategy | BackoffFunction)?,
	-- Custom function to determine if retry should continue
	-- Returns true to retry, false to stop
	shouldRetry: ((attempt: number, error: any) -> boolean)?,
}

type ReconciledConfig = {
	maxAttempts: number,
	baseDelay: number,
	maxDelay: number,
	backoff: BackoffStrategy | BackoffFunction,
	shouldRetry: ((attempt: number, error: any) -> boolean)?,
}

type Promise<T...> = Promise.TypedPromise<T...>

--// Constants //--
local DEFAULT_MAX_ATTEMPTS = 5
local DEFAULT_BASE_DELAY = 1
local DEFAULT_MAX_DELAY = 32
local DEFAULT_STRATEGY: BackoffStrategy = "Exponential"

--// Backoff Calculation Functions //--
local function calculateConstantBackoff(baseDelay: number, _attempt: number): number
	return baseDelay
end

local function calculateLinearBackoff(baseDelay: number, attempt: number): number
	return baseDelay * attempt
end

local function calculateExponentialBackoff(baseDelay: number, attempt: number): number
	return baseDelay * (2 ^ (attempt - 1))
end

local BACKOFF_STRATEGIES = {
	Constant = calculateConstantBackoff,
	Linear = calculateLinearBackoff,
	Exponential = calculateExponentialBackoff,
}

--// Helper Functions //--
local function reconcileConfig(config: RetryConfig?): ReconciledConfig
	local cfg = config or {} :: RetryConfig
	return {
		maxAttempts = cfg.maxAttempts or DEFAULT_MAX_ATTEMPTS,
		baseDelay = cfg.baseDelay or DEFAULT_BASE_DELAY,
		maxDelay = cfg.maxDelay or DEFAULT_MAX_DELAY,
		backoff = cfg.backoff or DEFAULT_STRATEGY,
		shouldRetry = cfg.shouldRetry,
	}
end

--// Module //--
local RetryWithBackoff = {}

--[[
	Calculates the delay for a given attempt using a backoff strategy or function.

	@param backoff Backoff strategy name or custom function
	@param baseDelay The base delay in seconds
	@param attempt The current attempt number (1-indexed)
	@param maxDelay The maximum delay cap in seconds
	@return The calculated delay in seconds, capped at maxDelay
]]
function RetryWithBackoff.calculateDelay(
	backoff: BackoffStrategy | BackoffFunction,
	baseDelay: number,
	attempt: number,
	maxDelay: number
): number
	local calculator: BackoffFunction

	if type(backoff) == "function" then
		calculator = backoff
	else
		calculator = BACKOFF_STRATEGIES[backoff]
		if not calculator then
			error(`Invalid backoff strategy: {backoff}`)
		end
	end

	local delay = calculator(baseDelay, attempt)
	return math.min(delay, maxDelay)
end

--[[
	Retries a function synchronously with configurable backoff.
	Executes the function and retries on failure according to the provided configuration.
	Uses pcall internally to catch errors and retry based on the backoff strategy or function.

	@param fn The function to retry (wrapped in pcall)
	@param config Optional retry configuration
	@return Tuple of (success: boolean, result: any)

	```lua
	-- Using a predefined strategy:
	local success, result = RetryWithBackoff.retryAsync(function()
		return riskyOperation()
	end, { maxAttempts = 5, backoff = "Exponential" })

	-- Using a custom backoff function:
	local success, result = RetryWithBackoff.retryAsync(function()
		return riskyOperation()
	end, {
		maxAttempts = 5,
		backoff = function(baseDelay, attempt)
			return baseDelay * (attempt ^ 1.5) -- Custom polynomial backoff
		end
	})
	```
]]
function RetryWithBackoff.retryAsync<T...>(fn: () -> T..., config: RetryConfig?): (boolean, T...)
	local cfg = reconcileConfig(config)

	local attempt = 1
	while attempt <= cfg.maxAttempts do
		local results = { pcall(fn) }
		local success = table.remove(results, 1)

		if success then
			return true, table.unpack(results) :: any
		end

		if attempt >= cfg.maxAttempts then
			return false, table.unpack(results) :: any
		end

		if cfg.shouldRetry and not cfg.shouldRetry(attempt, table.unpack(results)) then
			return false, table.unpack(results) :: any
		end

		local delay = RetryWithBackoff.calculateDelay(cfg.backoff, cfg.baseDelay, attempt, cfg.maxDelay)
		task.wait(delay)
		attempt += 1
	end

	return false, nil :: any
end

--[[
	Retries an async function (Promise-returning or regular) with configurable backoff.
	Executes the function and retries on rejection/error according to the provided configuration.
	Automatically wraps non-Promise functions in Promise.try() for compatibility.

	@param fn The function to retry - can return a Promise or regular values
	@param config Optional retry configuration
	@return A Promise that resolves with the function's result or rejects with the final error

	```lua
	-- Using a predefined strategy:
	RetryWithBackoff.retryPromise(function()
		return DataStore:UpdateAsync(key, transform)
	end, { maxAttempts = 5, backoff = "Exponential" }):andThen(function(result)
		print("Success:", result)
	end)

	-- Using a custom backoff function:
	RetryWithBackoff.retryPromise(function()
		return someOperation()
	end, {
		maxAttempts = 3,
		backoff = function(baseDelay, attempt)
			-- Custom backoff: add jitter to prevent thundering herd
			local jitter = math.random() * 0.1 * baseDelay
			return baseDelay * attempt + jitter
		end
	})
	```
]]
function RetryWithBackoff.retryPromise<T...>(fn: () -> Promise<T...>, config: RetryConfig?): Promise<T...>
	local cfg = reconcileConfig(config)

	return Promise.new(function(resolve, reject)
		local attempt = 1

		local function tryAttempt()
			-- Use Promise.try to handle both Promise-returning and regular functions
			Promise.try(fn)
				:andThen(function(...)
					resolve(...)
				end)
				:catch(function(err)
					if attempt >= cfg.maxAttempts then
						reject(err)
						return
					end

					if cfg.shouldRetry and not cfg.shouldRetry(attempt, err) then
						reject(err)
						return
					end

					local delay = RetryWithBackoff.calculateDelay(cfg.backoff, cfg.baseDelay, attempt, cfg.maxDelay)
					attempt += 1

					task.delay(delay, tryAttempt)
				end)
		end

		tryAttempt()
	end) :: any
end

return RetryWithBackoff
