--!strict
-- Authors: Logan Hunt (Raildex)
-- Save callback management for PlayerProfileManager

--// Imports //--
const Types = require(script.Parent.Types)
const Logger = require(script.Parent.Logger)

type Profile = Types.Profile
type SaveCallback = Types.SaveCallback
type SaveCallbackType = Types.SaveCallbackType
type SaveCallbackBuckets = Types.SaveCallbackBuckets
type SaveCallbackConnection = Types.SaveCallbackConnection
type Logger = Logger.Logger

export type SaveCallbackManager = {
	_callbacks: { [number]: SaveCallbackBuckets },
	_logger: Logger,
	-- Methods
	AddCallback: (
		self: SaveCallbackManager,
		userId: number,
		callbackType: SaveCallbackType,
		callback: (profile: Profile) -> (),
		priority: number
	) -> SaveCallbackConnection,
	ExecuteCallbacks: (
		self: SaveCallbackManager,
		userId: number,
		callbackType: SaveCallbackType,
		profile: Profile?
	) -> (),
	ClearCallbacks: (self: SaveCallbackManager, userId: number) -> (),
}

local SaveCallbackManager = {}
SaveCallbackManager.__index = SaveCallbackManager

--[[
	Creates a new SaveCallbackManager instance.
]]
function SaveCallbackManager.new(logger: Logger): SaveCallbackManager
	local self = setmetatable({}, SaveCallbackManager)
	self._callbacks = {}
	self._logger = logger
	return (self :: any) :: SaveCallbackManager
end

--[[
	Creates a new save callback storage for a user.
]]
local function createCallbackStorage(): SaveCallbackBuckets
	return {
		OnSave = {},
		OnLastSave = {},
	}
end

--[[
	Registers a prioritized save callback for a user and returns a removable connection.
]]
function SaveCallbackManager.AddCallback(
	self: SaveCallbackManager,
	userId: number,
	callbackType: SaveCallbackType,
	callback: (profile: Profile) -> (),
	priority: number
): SaveCallbackConnection
	if not self._callbacks[userId] then
		self._callbacks[userId] = createCallbackStorage()
	end

	local callbackData = {
		callback = callback,
		priority = priority,
	}

	table.insert(self._callbacks[userId][callbackType], callbackData)

	local connection = {
		Disconnect = function()
			local callbackBuckets = self._callbacks[userId]
			if not callbackBuckets then
				return
			end

			local callbacks = callbackBuckets[callbackType]
			local idx = table.find(callbacks, callbackData)
			if idx then
				table.remove(callbacks, idx)
			end
		end,
		Destroy = function()
			-- Alias for janitor-style cleanup compatibility
		end,
	}

	connection.Destroy = connection.Disconnect
	return connection
end

--[[
	Runs registered save callbacks for a user in descending priority order.
]]
function SaveCallbackManager.ExecuteCallbacks(
	self: SaveCallbackManager,
	userId: number,
	callbackType: SaveCallbackType,
	profile: Profile?
)
	if not profile then
		return
	end

	local callbackBuckets = self._callbacks[userId]
	if not callbackBuckets then
		return
	end

	local callbacks = callbackBuckets[callbackType]
	if #callbacks == 0 then
		return
	end

	-- Highest priority runs first
	table.sort(callbacks, function(a, b)
		return a.priority > b.priority
	end)

	for _, callbackData in ipairs(callbacks) do
		local success, err = pcall(callbackData.callback, profile)
		if not success then
			self._logger:Warn(`{callbackType} callback failed for userId {userId}: {err}`)
		end
	end
end

--[[
	Removes all callbacks for a user.
]]
function SaveCallbackManager.ClearCallbacks(self: SaveCallbackManager, userId: number)
	self._callbacks[userId] = nil
end

return SaveCallbackManager
