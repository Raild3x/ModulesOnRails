--!strict
-- Authors: Logan Hunt (Raildex)
-- Wipe lock management for PlayerProfileManager

--// Services //--
const MemoryStoreService = game:GetService("MemoryStoreService")

--// Imports //--
const Types = require(script.Parent.Types)
const Constants = require(script.Parent.Constants)
const Logger = require(script.Parent.Logger)
const RetryWithBackoff = require(script.Parent.RetryWithBackoff)

type WipeLockMap = Types.WipeLockMap
type WipeLockValue = Types.WipeLockValue
type ProfileStore = Types.ProfileStore
type Logger = Logger.Logger

const WIPE_LOCK_TTL_SECONDS = Constants.WIPE_LOCK_TTL_SECONDS
const WIPE_MESSAGE_KIND = Constants.WIPE_MESSAGE_KIND

-- Shared retry config for all MemoryStore lock operations
const LOCK_RETRY_CONFIG: RetryWithBackoff.RetryConfig = {
	maxAttempts = 3,
	baseDelay = 0.5,
	backoff = "Exponential",
}

export type WipeLockManager = {
	_wipeLockMap: WipeLockMap?,
	_wipeLocksAcquired: { [number]: boolean },
	_wipeLockMapName: string,
	_logger: Logger,
	-- Methods
	AcquireLock: (self: WipeLockManager, userId: number) -> boolean,
	IsLocked: (self: WipeLockManager, userId: number) -> boolean,
	ReleaseLock: (self: WipeLockManager, userId: number) -> (),
	ReleaseAllLocks: (self: WipeLockManager) -> (),
	SendResetMessage: (self: WipeLockManager, profileStore: ProfileStore, playerKey: string, userId: number) -> boolean,
}

local WipeLockManager = {}
WipeLockManager.__index = WipeLockManager

--[[
	Creates a new WipeLockManager instance.
]]
function WipeLockManager.new(wipeLockMapName: string, logger: Logger): WipeLockManager
	local self = setmetatable({}, WipeLockManager)
	self._wipeLockMapName = wipeLockMapName
	self._wipeLocksAcquired = {}
	self._logger = logger

	local ok, result = pcall(function()
		return MemoryStoreService:GetHashMap(wipeLockMapName)
	end)
	if ok then
		self._wipeLockMap = (result :: any) :: WipeLockMap
		self._logger:Debug(`Wipe lock MemoryStore initialized: {wipeLockMapName}`)
	else
		self._logger:Warn(`Failed to initialize wipe lock MemoryStore '{wipeLockMapName}': {result}`)
		self._wipeLockMap = nil
	end

	return (self :: any) :: WipeLockManager
end

--[[
	Attempts to acquire a MemoryStore-backed delete-in-progress lock for the given userId.
	Returns true if the lock was successfully acquired, false if already locked.
]]
function WipeLockManager.AcquireLock(self: WipeLockManager, userId: number): boolean
	if not self._wipeLockMap then
		self._logger:Debug(`Failed to acquire wipe lock for userId {userId}: MemoryStore unavailable`)
		return false
	end

	const lockKey = `user_{userId}`
	local didAcquire = false

	const success, finalResult = RetryWithBackoff.retryAsync(function()
		return self._wipeLockMap:UpdateAsync(lockKey, function(existingValue: WipeLockValue?): WipeLockValue
			if existingValue ~= nil then
				return existingValue
			end
			didAcquire = true
			return { acquiredAt = os.time(), initiator = game.JobId }
		end, WIPE_LOCK_TTL_SECONDS)
	end, LOCK_RETRY_CONFIG)

	if success and finalResult ~= nil and didAcquire then
		self._wipeLocksAcquired[userId] = true
		self._logger:Debug(`Acquired wipe lock for userId {userId}`)
		return true
	end
	self._logger:Debug(`Failed to acquire wipe lock for userId {userId}: already locked or MemoryStore error`)
	return false
end

--[[
	Checks if a delete-in-progress lock exists for the given userId.
	Returns true if locked, false if not locked or MemoryStore unavailable.
]]
function WipeLockManager.IsLocked(self: WipeLockManager, userId: number): boolean
	if not self._wipeLockMap then
		return false
	end

	const lockKey = `user_{userId}`
	const success, result = RetryWithBackoff.retryAsync(function()
		return self._wipeLockMap:GetAsync(lockKey)
	end, LOCK_RETRY_CONFIG)

	if success then
		return result ~= nil
	end
	return false
end

--[[
	Releases the delete-in-progress lock for the given userId.
	Safe to call even if lock is not held.
]]
function WipeLockManager.ReleaseLock(self: WipeLockManager, userId: number): ()
	if not self._wipeLockMap then
		return
	end

	self._wipeLocksAcquired[userId] = nil
	const lockKey = `user_{userId}`
	const success = RetryWithBackoff.retryAsync(function()
		self._wipeLockMap:RemoveAsync(lockKey)
	end, LOCK_RETRY_CONFIG)

	if success then
		self._logger:Debug(`Released wipe lock for userId {userId}`)
	else
		self._logger:Warn(`Failed to release wipe lock for userId {userId}`)
	end
end

--[[
	Releases all wipe locks held by the manager.
	Called during cleanup/destroy.
]]
function WipeLockManager.ReleaseAllLocks(self: WipeLockManager)
	for userId in self._wipeLocksAcquired do
		self:ReleaseLock(userId)
	end
end

--[[
	Sends a cross-server reset notification via ProfileStore messaging.
	Called during WipeProfile to alert other servers to kick the user.
]]
function WipeLockManager.SendResetMessage(
	self: WipeLockManager,
	profileStore: ProfileStore,
	playerKey: string,
	userId: number
): boolean
	const message = {
		kind = WIPE_MESSAGE_KIND,
		userId = userId,
		requestId = `{game.JobId}_{os.time()}_{math.random()}`,
		issuedAt = os.time(),
	}

	const ok, result = pcall(function()
		return profileStore:MessageAsync(playerKey, message)
	end)

	if ok and result then
		self._logger:Debug(`Sent wipe reset message for userId {userId}`)
		return true
	end
	self._logger:Debug(`Failed to send wipe reset message for userId {userId}: {if ok then result else "error"}`)
	return false
end

return WipeLockManager
