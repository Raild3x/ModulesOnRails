--!strict
-- Authors: Logan Hunt (Raildex)
-- Logger for PlayerProfileManager

export type Logger = {
	_enabled: boolean,
	_prefix: string,
	_level: number,
	Trace: (self: Logger, ...any) -> (),
	TraceF: (self: Logger, format: string, ...any) -> (),
	Debug: (self: Logger, ...any) -> (),
	DebugF: (self: Logger, format: string, ...any) -> (),
	Info: (self: Logger, ...any) -> (),
	InfoF: (self: Logger, format: string, ...any) -> (),
	Warn: (self: Logger, ...any) -> (),
	WarnF: (self: Logger, format: string, ...any) -> (),
	Error: (self: Logger, ...any) -> (),
	Assert: (self: Logger, condition: boolean, ...any) -> (),
	AssertF: (self: Logger, condition: boolean, format: string, ...any) -> (),
}

local VerbosityLevels = {
	Trace = 0,
	Debug = 1,
	Info = 2,
	Warn = 3,
	Error = 4,
}

local Logger = {}
Logger.__index = Logger
Logger.VerbosityLevels = VerbosityLevels

--[[
	Creates a new Logger instance.
	@param level number -- Verbosity level (use Logger.VerbosityLevels)
	@param prefix string? -- Optional prefix for all log messages (defaults to "[👤]")
]]
function Logger.new(level: number, prefix: string?): Logger
	local self = setmetatable({}, Logger)
	self._level = level
	self._prefix = prefix or "[👤]"
	self._enabled = level <= VerbosityLevels.Debug
	return (self :: any) :: Logger
end

--[[
	Gets the caller's source location (file:line).
	@param stackLevel number -- Stack level to inspect (default 3)
]]
local function getSourceLocation(stackLevel: number?): string
	local level = stackLevel or 3
	local source, line = debug.info(level, "sl")
	if source and line then
		-- Extract just the filename from the full path
		local filename = string.match(source, "([^/\\]+)$") or source
		return `{filename}:{line}`
	end
	return "unknown"
end

--[[
	Prints a trace message if verbosity level is Trace or lower.
]]
function Logger.Trace(self: Logger, ...: any)
	if self._level <= VerbosityLevels.Trace then
		local location = getSourceLocation()
		print(self._prefix, `[TRACE] [{location}]`, ...)
	end
end

--[[
	Prints a formatted trace message if verbosity level is Trace or lower.
]]
function Logger.TraceF(self: Logger, format: string, ...: any)
	if self._level <= VerbosityLevels.Trace then
		local location = getSourceLocation()
		print(self._prefix, `[TRACE] [{location}]`, string.format(format, ...))
	end
end

--[[
	Prints a debug message if verbosity level is Debug or lower.
]]
function Logger.Debug(self: Logger, ...: any)
	if self._level <= VerbosityLevels.Debug then
		local location = getSourceLocation()
		print(self._prefix, `[DEBUG] [{location}]`, ...)
	end
end

--[[
	Prints a formatted debug message if verbosity level is Debug or lower.
]]
function Logger.DebugF(self: Logger, format: string, ...: any)
	if self._level <= VerbosityLevels.Debug then
		local location = getSourceLocation()
		print(self._prefix, `[DEBUG] [{location}]`, string.format(format, ...))
	end
end

--[[
	Prints an info message if verbosity level is Info or lower.
]]
function Logger.Info(self: Logger, ...: any)
	if self._level <= VerbosityLevels.Info then
		local location = getSourceLocation()
		print(self._prefix, `[INFO] [{location}]`, ...)
	end
end

--[[
	Prints a formatted info message if verbosity level is Info or lower.
]]
function Logger.InfoF(self: Logger, format: string, ...: any)
	if self._level <= VerbosityLevels.Info then
		local location = getSourceLocation()
		print(self._prefix, `[INFO] [{location}]`, string.format(format, ...))
	end
end

--[[
	Prints a warning message if verbosity level is Warn or lower.
]]
function Logger.Warn(self: Logger, ...: any)
	if self._level <= VerbosityLevels.Warn then
		local location = getSourceLocation()
		warn(self._prefix, `[WARN] [{location}]`, ...)
	end
end

--[[
	Prints a formatted warning message if verbosity level is Warn or lower.
]]
function Logger.WarnF(self: Logger, format: string, ...: any)
	if self._level <= VerbosityLevels.Warn then
		local location = getSourceLocation()
		warn(self._prefix, `[WARN] [{location}]`, string.format(format, ...))
	end
end

--[[
	Throws an error with the logger's prefix (always executed).
]]
function Logger.Error(self: Logger, ...: any)
	local location = getSourceLocation()
	error(`{self._prefix} [ERROR] [{location}] {...}`)
end

--[[
	Asserts a condition and throws an error if false.
]]
function Logger.Assert(self: Logger, condition: boolean, ...: any)
	if not condition then
		local location = getSourceLocation()
		error(`{self._prefix} [ASSERT] [{location}] {...}`)
	end
end

--[[
	Asserts a condition and throws a formatted error if false.
]]
function Logger.AssertF(self: Logger, condition: boolean, format: string, ...: any)
	if not condition then
		local location = getSourceLocation()
		error(`{self._prefix} [ASSERT] [{location}] {string.format(format, ...)}`)
	end
end

return Logger
