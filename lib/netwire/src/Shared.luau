-- Logan Hunt [Raildex]
-- NetWire Shared Constants and Utilities
--[=[
	@class NetWireShared
	@ignore
	
	Centralized shared constants and utilities for the NetWire library.
	This file only exports symbols and utilities that are used across multiple files.
]=]

local Packages = script.Parent.Parent
local Symbol = require(Packages.Symbol)

--------------------------------------------------------------------------------
-- SHARED SYMBOLS
--------------------------------------------------------------------------------

-- Internal symbols for NetWire implementation (used across Server and Client)
local NAME_KEY = Symbol("NAME")
local COMM_KEY = Symbol("COMM")
local JANI_KEY = Symbol("JANITOR")
local SIG_KEY = Symbol("NEW_IDX_SIG")

--------------------------------------------------------------------------------
-- SHARED UTILITIES
--------------------------------------------------------------------------------

--[=[
	@within NetWireShared
	Validates that a given operation is being performed in the correct context.
	
	@param serverOnly boolean -- Whether the operation requires server context
	@param operationName string -- Name of the operation (for error messages)
]=]
local function validateContext(serverOnly: boolean, operationName: string)
	local RunService = game:GetService("RunService")
	if serverOnly and not RunService:IsServer() then
		error(`{operationName} can only be called on the server`)
	elseif not serverOnly and not RunService:IsClient() then
		error(`{operationName} can only be called on the client`)
	end
end

--------------------------------------------------------------------------------
-- EXPORTS
--------------------------------------------------------------------------------

return {
	-- Shared symbols (used across multiple files)
	NAME_KEY = NAME_KEY,
	COMM_KEY = COMM_KEY,
	JANI_KEY = JANI_KEY,
	SIG_KEY = SIG_KEY,

	-- Shared utilities
	validateContext = validateContext,
}
