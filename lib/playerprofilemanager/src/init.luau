--!strict
-- Authors: Logan Hunt (Raildex)
-- January 22, 2024
--[=[
    @class PlayerProfileManager
    @server

    A robust and easy-to-use player profile management system built on top of ProfileStore.
    This class handles player data loading, saving, migration, and cleanup automatically.

    Key Features:
    - Automatic retry logic for failed loads
    - Data migration system with version tracking and chain validation
    - Robust error handling and edge case management
    - Mock support for testing
    - Direct signal fields for profile lifecycle events

    Basic Usage:
    ```lua
    local manager = PlayerProfileManager.new({
        DefaultDataSchema = {
            __VERSION = "1.0.0",
            Coins = 0,
            Level = 1
        }
    })

    -- Get a player's profile
    local profile = manager:GetProfile(player)
    if profile then
        profile.Data.Coins += 100
    end

    -- Listen to lifecycle events
    manager.PlayerProfileReleasing:Connect(function(userId, profile)
        print(userId .. " is leaving")
    end)

    -- Or wait for it to load
    manager:PromiseProfile(player):andThen(function(profile)
        profile.Data.Level += 1
    end)
    ```
]=]

--// Services //--
const Players = game:GetService("Players")

--// Imports //--
const Packages = script.Parent
const ProfileStore = require(Packages.ProfileStore)
const Janitor = require(Packages.Janitor)
const Signal = require(Packages.Signal)
const Promise = require(Packages.Promise)
const T = require(Packages.T)

--// Module Imports //--
const Types = require(script.Types)
const Constants = require(script.Constants)
const Logger = require(script.Logger)
const MigrationSystem = require(script.MigrationSystem)
const SaveCallbackManager = require(script.SaveCallbackManager)
const WipeLockManager = require(script.WipeLockManager)
const RetryWithBackoff = require(script.RetryWithBackoff)

-- Logger verbosity levels
const LogLevel = Logger.VerbosityLevels

--// Types //--
type Janitor = Janitor.Janitor
export type Profile = Types.Profile
export type ProfileStore = Types.ProfileStore
export type DataMigrator<TFrom = any, TTo = any> = Types.DataMigrator<TFrom, TTo>
export type PPM_Config = Types.PPM_Config
export type PlayerProfileManager = Types.PlayerProfileManager

type Promise<T...> = Promise.TypedPromise<T...>
type LoadSuccessSignal = Types.LoadSuccessSignal
type LoadFailureSignal = Types.LoadFailureSignal
type ReleasingSignal = Types.ReleasingSignal
type SaveCallbackType = Types.SaveCallbackType
type SaveCallback = Types.SaveCallback
type SaveCallbackConnection = Types.SaveCallbackConnection
type Logger = Logger.Logger
type SaveCallbackManager = SaveCallbackManager.SaveCallbackManager
type WipeLockManager = WipeLockManager.WipeLockManager

-- Runtime validator table
const ConfigType = {
	DataStoreKey = T.optional(T.string),
	DefaultDataSchema = T.table,
	UseMock = T.optional(T.boolean),
	Migrator = T.optional(T.array(T.table)),
	GetPlayerKeyCallback = T.optional(T.callback),
	ReconcileCallback = T.optional(T.callback),
	OnProfileLoadFailureCallback = T.optional(T.callback),
	Debug = T.optional(T.boolean),
	LogLevel = T.optional(T.number),
	DebugProfileUserId = T.optional(T.number),
}
const ConfigInterface = T.interface(ConfigType)
const IsValidUserId = function(userId: any): boolean
	return T.number(userId) and userId % 1 == 0 and userId ~= 0
end

--[=[
    @type PPM_Internal
    @within PlayerProfileManager
    @private
    Extends `PlayerProfileManager` with private fields and methods.
]=]
type PPM_Internal = PlayerProfileManager & {
	-- fields
	_janitor: Janitor,
	_config: PPM_Config,
	_dataStoreKey: string,
	_isMock: boolean,
	_profileStore: ProfileStore,
	_PlayerProfileStorage: { [number]: Profile },
	_LoadingPlayers: { [number]: boolean },
	_reconcileCallback: (userId: number, profile: Profile) -> (),
	_loadFailureCallback: (userId: number, err: string) -> (),
	_debugUserId: number?,
	_logger: Logger,
	_saveCallbackManager: SaveCallbackManager,
	_wipeLockManager: WipeLockManager,
	-- private methods
	_setupCallbacks: (self: PPM_Internal) -> (),
	_initializeProfileStore: (self: PPM_Internal) -> (),
	_startPlayerManagement: (self: PPM_Internal) -> (),
	_reconcileProfile: (self: PPM_Internal, userId: number, profile: Profile) -> (),
	_generatePlayerKey: (self: PPM_Internal, userId: number) -> string,
	_attemptLoadProfile: (self: PPM_Internal, userId: number, player: Player?) -> Promise<Profile>,
	_createPlayerData: (self: PPM_Internal, playerOrUserId: Player | number) -> Promise<any>,
	_setupProfileSession: (self: PPM_Internal, userId: number, profile: Profile) -> (),
	_endProfileSession: (self: PPM_Internal, userId: number, profile: Profile, reason: string) -> (),
	_getUserId: (self: PPM_Internal, playerOrUserId: Player | number) -> number,
}

--// Constants //--
const RETRY_PROFILE_LOAD_DELAY = Constants.RETRY_PROFILE_LOAD_DELAY
const RETRY_PROFILE_LOAD_ATTEMPTS = Constants.RETRY_PROFILE_LOAD_ATTEMPTS
const VERSION_KEY = Constants.VERSION_KEY
const DEFAULT_DATA_STORE_KEY = Constants.DEFAULT_DATA_STORE_KEY
const WIPE_RETRY_ATTEMPTS = Constants.WIPE_RETRY_ATTEMPTS
const WIPE_RETRY_DELAY = Constants.WIPE_RETRY_DELAY
const WIPE_RESET_KICK_MESSAGE = Constants.WIPE_RESET_KICK_MESSAGE
const WIPE_MESSAGE_KIND = Constants.WIPE_MESSAGE_KIND
const SAVE_PRIORITY = Constants.SAVE_PRIORITY

--------------------------------------------------------------------------------
--// Local State & Utilities //--
--------------------------------------------------------------------------------

-- Tracks which DataStore keys are currently in use
const ACTIVE_DATA_STORE_KEYS = {} :: { [string]: boolean }

--[[
	Resolves a userId to a `Player?` if they are still in-game.
]]
local function resolvePlayer(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

--[[
	Claims a DataStore key, erroring if it's already in use.
]]
local function claimDataStoreKey(dataStoreKey: string)
	assert(
		not ACTIVE_DATA_STORE_KEYS[dataStoreKey],
		`[👤] DataStoreKey '{dataStoreKey}' is already in use by another active PlayerProfileManager. Configure a unique DataStoreKey for each manager instance.`
	)
	ACTIVE_DATA_STORE_KEYS[dataStoreKey] = true
end

--[[
	Releases a DataStore key.
]]
local function releaseDataStoreKey(dataStoreKey: string)
	ACTIVE_DATA_STORE_KEYS[dataStoreKey] = nil
end

--[[
	Hashes a string into a number.
]]
local function hashKeyName(value: string): number
	local hash = 5381
	for index = 1, #value do
		hash = (hash * 33 + string.byte(value, index)) % 2147483647
	end
	return hash
end

--[[
	Builds a unique MemoryStore map name for wipe locks.
]]
local function buildWipeLockMapName(dataStoreKey: string): string
	const sanitizedDataStoreKey = string.gsub(dataStoreKey, "[^%w_%-]", "_")
	const visibleKeyPrefix = string.sub(sanitizedDataStoreKey, 1, 40)
	const WIPE_LOCK_MAP_NAME = Constants.WIPE_LOCK_MAP_NAME
	return `{WIPE_LOCK_MAP_NAME}_{hashKeyName(dataStoreKey)}_{visibleKeyPrefix}`
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

const PlayerProfileManager = {}
PlayerProfileManager.ClassName = "PlayerProfileManager"
PlayerProfileManager.__index = PlayerProfileManager
PlayerProfileManager.SAVE_PRIORITY = SAVE_PRIORITY
PlayerProfileManager.LogLevel = LogLevel

--[=[
    Creates a new PlayerProfileManager. Takes a config table — see `PPM_Config` for details.

    ```lua
    local manager = PlayerProfileManager.new({
        DefaultDataSchema = {
            __VERSION = "0.0.0",
            Currency = 0,
        },
    })
    ```
]=]
function PlayerProfileManager.new(config: PPM_Config): PlayerProfileManager
	assert(ConfigInterface(config), "Invalid configuration provided to PlayerProfileManager.new")

	local self = (setmetatable({}, PlayerProfileManager) :: any) :: PPM_Internal

	self._janitor = Janitor.new()
	self._LoadingPlayers = {} :: { [number]: boolean }
	self._PlayerProfileStorage = {} :: { [number]: Profile }
	self._config = config
	self._dataStoreKey = config.DataStoreKey or DEFAULT_DATA_STORE_KEY
	self._isMock = config.UseMock or false
	self._debugUserId = config.DebugProfileUserId or nil

	-- Determine log level (LogLevel takes precedence, Debug is for backward compatibility)
	local logLevel = config.LogLevel or (config.Debug and LogLevel.Debug or LogLevel.Warn)
	self._logger = Logger.new(logLevel)

	-- Initialize managers
	self._saveCallbackManager = SaveCallbackManager.new(self._logger)
	self._wipeLockManager = WipeLockManager.new(buildWipeLockMapName(self._dataStoreKey), self._logger)
	if self._debugUserId then
		self._logger:Info(
			`DebugProfileUserId is active — all userId lookups return {self._debugUserId} (single-player testing only)`
		)
	end

	-- Lifecycle signals — directly accessible fields with full types
	self.PlayerProfileLoadSuccess = self._janitor:Add(Signal.new() :: any) :: LoadSuccessSignal
	self.PlayerProfileLoadFailure = self._janitor:Add(Signal.new() :: any) :: LoadFailureSignal
	self.PlayerProfileReleasing = self._janitor:Add(Signal.new() :: any) :: ReleasingSignal

	-- Validate migration chain upfront so misconfiguration errors at construction
	if config.Migrator and #config.Migrator > 0 then
		MigrationSystem.validateMigratorChain(config.Migrator, config.DefaultDataSchema[VERSION_KEY])
	end

	local ok, err = pcall(function()
		claimDataStoreKey(self._dataStoreKey)
		self:_setupCallbacks()
		self:_initializeProfileStore()
		self:_startPlayerManagement()
	end)
	if not ok then
		releaseDataStoreKey(self._dataStoreKey)
		self._logger:Error(`Failed to initialize PlayerProfileManager: {err}`)
	end

	self._logger:Info(`PlayerProfileManager initialized with DataStoreKey: {self._dataStoreKey}`)
	return (self :: any) :: PlayerProfileManager
end

--[=[
    @private
	Sets the default reconcile and load-failure callbacks, falling back to
	built-in behavior when the config does not provide overrides.
]=]
function PlayerProfileManager._setupCallbacks(self: PPM_Internal)
	local DEFAULT_RECONCILE_CALLBACK = function(_: number, profile: Profile)
		profile:Reconcile()
	end
	self._reconcileCallback = self._config.ReconcileCallback or DEFAULT_RECONCILE_CALLBACK

	local DEFAULT_LOAD_FAILURE_CALLBACK = function(userId: number, err: string)
		const player = resolvePlayer(userId)
		if player then
			player:Kick(
				"Something went wrong and we failed to load your player data. Please rejoin the game. "
					.. "If this issue persists, please contact the developer.\n"
					.. tostring(err)
			)
		end
	end
	self._loadFailureCallback = self._config.OnProfileLoadFailureCallback or DEFAULT_LOAD_FAILURE_CALLBACK
end

--[=[
    @private
	Creates the ProfileStore instance using the configured DataStore key,
	schema, and mock mode.
]=]
function PlayerProfileManager._initializeProfileStore(self: PPM_Internal)
	const store = ProfileStore.New(self._dataStoreKey, self._config.DefaultDataSchema)
	self._profileStore = ((if self._isMock then store.Mock else store) :: any) :: ProfileStore
	if self._isMock then
		self._logger:Info("Using Mock ProfileStore for testing")
	end
end

--[=[
    @private
	Starts loading profiles for players already in the server and keeps the
	manager in sync as players join.
]=]
function PlayerProfileManager._startPlayerManagement(self: PPM_Internal)
	for _, player in ipairs(Players:GetPlayers()) do
		self._janitor:AddPromise(self:_createPlayerData(player))
	end

	self._janitor:Add(
		Players.PlayerAdded:Connect(function(player: Player)
			self._janitor:AddPromise(self:_createPlayerData(player))
		end),
		"Disconnect"
	)
end

--[=[
    @private
]=]
function PlayerProfileManager._reconcileProfile(self: PPM_Internal, userId: number, profile: Profile)
	local player = resolvePlayer(userId)
	if not player then
		self._logger:Warn(`Skipping reconcile for userId {userId} — player not in game`)
		return
	end
	self._logger:Debug(`Reconciling profile for {player.Name}.`)
	self._reconcileCallback(userId, profile)
end

--[=[
    @private
    Generates the DataStore key for a userId.
]=]
function PlayerProfileManager._generatePlayerKey(self: PPM_Internal, userId: number): string
	if userId == 0 then
		self._logger:Warn(`Invalid userId provided to _generatePlayerKey: {userId}.`)
	end
	return if self._config.GetPlayerKeyCallback then self._config.GetPlayerKeyCallback(userId) else `Player_{userId}`
end

--[=[
    @private
    Single attempt to start a ProfileStore session for the given userId.
]=]
function PlayerProfileManager._attemptLoadProfile(self: PPM_Internal, userId: number, player: Player?): Promise<Profile>
	return Promise.new(function(resolve, reject)
		-- Preflight: check if profile is in the process of being wiped
		if self._wipeLockManager:IsLocked(userId) then
			reject("Profile is being reset — please rejoin in a moment")
			return
		end

		if not player or not player:IsDescendantOf(Players) then
			reject("Player left before profile loading started")
			return
		end

		local playerKey = self:_generatePlayerKey(userId)
		self._logger:Debug(`Attempting to load profile for {player.Name} with key: {playerKey}`)

		local profile = self._profileStore:StartSessionAsync(playerKey, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})

		if not profile then
			reject(`Profile failed to load for {player.Name}`)
			return
		end

		profile:AddUserId(userId)

		if not player:IsDescendantOf(Players) then
			profile:EndSession()
			reject("Player left while profile was loading")
			return
		end

		local success, err = pcall(function()
			MigrationSystem.migrateProfileData(
				self._config.Migrator,
				self._config.DefaultDataSchema[VERSION_KEY],
				userId,
				profile,
				self._logger
			)
			self:_reconcileProfile(userId, profile)
		end)

		if not success then
			profile:EndSession()
			self._logger:Warn(`Failed to process profile data for {player.Name}: {err}`)
			reject(`Failed to process profile data for {player.Name}: {err}`)
			return
		end

		if player.Parent ~= Players then
			profile:EndSession()
			reject("Player left before profile session fully started")
			return
		end
		self._logger:Debug(`Profile successfully loaded for {player.Name}`)
		resolve(profile)
	end)
end

--[=[
    @private
    Loads a player's profile with retry logic. Main entry point from `_startPlayerManagement`.
]=]
function PlayerProfileManager._createPlayerData(self: PPM_Internal, playerOrUserId: Player | number): Promise<any>
	local userId = self:_getUserId(playerOrUserId)
	local player = resolvePlayer(userId)

	if self._LoadingPlayers[userId] then
		self._logger:Debug(`Profile already loading for userId {userId}, skipping duplicate attempt`)
		return Promise.reject("Profile already being loaded")
	end

	self._LoadingPlayers[userId] = true
	self._logger:Debug(`Starting profile load for userId {userId}`)

	return RetryWithBackoff.retryPromise(function()
		local prom = self:_attemptLoadProfile(userId, player)
		prom:catch(function(err)
			self._logger:Warn(`Failed to load profile for userId {userId}: {err}`)
		end)
		return prom
	end, {
		maxAttempts = RETRY_PROFILE_LOAD_ATTEMPTS,
		baseDelay = RETRY_PROFILE_LOAD_DELAY,
		backoff = "Exponential",
	})
		:andThen(function(profile)
			self:_setupProfileSession(userId, profile)
			self._logger:Debug(`Successfully loaded profile for userId {userId}`)
			self.PlayerProfileLoadSuccess:Fire(userId)
		end)
		:catch(function(err)
			self.PlayerProfileLoadFailure:Fire(userId, err)
			self._loadFailureCallback(userId, err)
		end)
		:finally(function()
			self._LoadingPlayers[userId] = nil
		end)
end

--[=[
    @private
    Stores the profile and wires up session-end / player-leaving cleanup handlers.
]=]
function PlayerProfileManager._setupProfileSession(self: PPM_Internal, userId: number, profile: Profile)
	local player = resolvePlayer(userId)

	self._PlayerProfileStorage[userId] = profile
	self._logger:Info(`Profile session established for userId {userId}`)

	local onSaveConnection = profile.OnSave:Connect(function()
		self._logger:Debug(`OnSave triggered for userId {userId}`)
		self._saveCallbackManager:ExecuteCallbacks(userId, "OnSave", self._PlayerProfileStorage[userId])
	end)

	local onLastSaveConnection = profile.OnLastSave:Connect(function()
		self._logger:Debug(`OnLastSave triggered for userId {userId}`)
		self._saveCallbackManager:ExecuteCallbacks(userId, "OnLastSave", self._PlayerProfileStorage[userId])
	end)

	-- Register message handler to process cross-server wipe reset notifications
	profile:MessageHandler(function(message, processed)
		if type(message) == "table" then
			const messageTable = message :: { [string]: any }
			if messageTable.kind == WIPE_MESSAGE_KIND and messageTable.userId == userId then
				self._logger:Debug(`Received wipe reset message for userId {userId} from cross-server`)
				processed() -- Mark message as handled
				if player and player.Parent == Players then
					player:Kick(WIPE_RESET_KICK_MESSAGE)
				end
			end
		end
	end)

	profile.OnSessionEnd:Connect(function()
		onSaveConnection:Disconnect()
		onLastSaveConnection:Disconnect()
		self._logger:Info(`Profile session ended for userId {userId}`)
		-- Guard against double-fire: _endProfileSession may have already released the profile
		if self._PlayerProfileStorage[userId] then
			self.PlayerProfileReleasing:Fire(userId, profile)
			self._PlayerProfileStorage[userId] = nil
		end
		if player and player.Parent == Players then
			self._logger:Warn(`Kicking player userId {userId} due to session end`)
			player:Kick("Profile session ended — please rejoin")
		end
	end)

	-- Use a keyed Add so the connection can be removed from the janitor on player leave,
	-- preventing stale disconnected connections from accumulating over the server lifetime.
	const connKey = `PlayerRemoving_{userId}`
	self._janitor:Add(
		Players.PlayerRemoving:Connect(function(removingPlayer: Player)
			if removingPlayer == player then
				self._janitor:Remove(connKey)
				self._logger:Debug(`Cleaning up profile for leaving player userId {userId}`)
				self:_endProfileSession(userId, profile, "player_leaving")
				if self._isMock then
					self._profileStore:RemoveAsync(self:_generatePlayerKey(userId))
					self._logger:Debug(`Removed mock profile for userId {userId}`)
				end
			end
		end),
		"Disconnect",
		connKey
	)
end

--[=[
    @private
    Extracts a userId from a `Player | number`. When `DebugProfileUserId` is configured,
    always returns that value regardless of the input.
]=]
function PlayerProfileManager._getUserId(self: PPM_Internal, playerOrUserId: Player | number): number
	if self._debugUserId then
		return self._debugUserId
	end
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	end
	return (playerOrUserId :: Player).UserId
end

--[=[
    @private
    Shared session-ending logic that fires PlayerProfileReleasing signal once,
    calls profile:EndSession(), and cleans up in-memory storage.
    This ensures consistent release semantics across player-leave and wipe paths.
]=]
function PlayerProfileManager._endProfileSession(
	self: PPM_Internal,
	userId: number,
	profile: Profile,
	reason: string
): ()
	self._logger:Info(`Ending profile session for userId {userId} (reason: {reason})`)
	self.PlayerProfileReleasing:Fire(userId, profile)
	profile:EndSession()
	self._PlayerProfileStorage[userId] = nil
	self._saveCallbackManager:ClearCallbacks(userId)
	self._logger:Debug(`Profile session cleanup completed for userId {userId}`)
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Destroys the manager, cleans up all signals and connections.
]=]
function PlayerProfileManager.Destroy(self: PPM_Internal)
	self._logger:Info("Destroying PlayerProfileManager")
	-- Release any wipe locks still held by this server instance so they don't
	-- block future loads until the TTL expires.
	self._wipeLockManager:ReleaseAllLocks()
	releaseDataStoreKey(self._dataStoreKey)
	self._janitor:Destroy()
	self._logger:Debug("PlayerProfileManager destroyed successfully")
end

--[=[
    Returns `true` if the player's profile is currently loaded and accessible.

    ```lua
    if manager:IsLoaded(player) then
        manager:GetProfile(player).Data.Coins += 100
    end
    ```

    @param playerOrUserId Player | number
    @return boolean
]=]
function PlayerProfileManager.IsLoaded(self: PPM_Internal, playerOrUserId: Player | number): boolean
	return self._PlayerProfileStorage[self:_getUserId(playerOrUserId)] ~= nil
end

--[=[
    Returns `true` if the player's profile is currently being loaded.

    @param playerOrUserId Player | number
    @return boolean
]=]
function PlayerProfileManager.IsLoading(self: PPM_Internal, playerOrUserId: Player | number): boolean
	return self._LoadingPlayers[self:_getUserId(playerOrUserId)] == true
end

--[=[
    Returns a Promise that resolves once the player's profile is ready.
    Rejects if the load fails or the player leaves before loading completes.

    ```lua
    manager:OnLoaded(player):andThen(function()
        print("Profile ready for " .. player.Name)
    end)
    ```

    @param playerOrUserId Player | number
    @return Promise<()>
]=]
function PlayerProfileManager.OnLoaded(self: PPM_Internal, playerOrUserId: Player | number): Promise<()>
	local userId = self:_getUserId(playerOrUserId)
	if self:IsLoaded(playerOrUserId) then
		return Promise.resolve()
	end
	return Promise.race {
		Promise.fromEvent(self.PlayerProfileLoadSuccess :: any, function(loadedUserId: number)
			return loadedUserId == userId
		end),
		Promise.fromEvent(self.PlayerProfileLoadFailure :: any, function(loadedUserId: number)
			return loadedUserId == userId
		end):andThen(function()
			return Promise.reject("Failed to load profile for userId " .. tostring(userId))
		end),
	}
end

--[=[
    Returns the player's profile if loaded, otherwise `nil`.

    ```lua
    local profile: Profile? = manager:GetProfile(player)
    ```

    @param playerOrUserId Player | number
    @return Profile?
]=]
function PlayerProfileManager.GetProfile(self: PPM_Internal, playerOrUserId: Player | number): Profile?
	self._logger:Assert(self.ClassName == "PlayerProfileManager", "Must be called on a PlayerProfileManager instance.")
	return self._PlayerProfileStorage[self:_getUserId(playerOrUserId)]
end

--[=[
    Returns a Promise that resolves with the player's profile when it is ready.
    Rejects if the load fails or the player leaves.

    ```lua
    manager:PromiseProfile(player):andThen(function(profile: Profile)
        profile.Data.Level += 1
    end)
    ```

    @param playerOrUserId Player | number
    @return Promise<Profile>
]=]
function PlayerProfileManager.PromiseProfile(self: PPM_Internal, playerOrUserId: Player | number): Promise<Profile>
	self._logger:Assert(self.ClassName == "PlayerProfileManager", "Must be called on a PlayerProfileManager instance.")
	return self:OnLoaded(playerOrUserId):andThen(function()
		local profile = self:GetProfile(playerOrUserId)
		if not profile then
			return Promise.reject("Profile was unloaded before it could be returned")
		end
		return profile
	end)
end

--[=[
	Registers a callback for regular profile saves for a specific player.

	Callbacks run in descending priority order. Higher numbers run first.

	@param playerOrUserId Player | number
	@param callback (profile: Profile) -> ()
	@param priority number?
	@return SaveCallbackConnection
]=]
function PlayerProfileManager.OnSave(
	self: PPM_Internal,
	playerOrUserId: Player | number,
	callback: (profile: Profile) -> (),
	priority: number?
): SaveCallbackConnection
	self._logger:Assert(type(callback) == "function", "Expected callback to be a function")
	local userId = self:_getUserId(playerOrUserId)
	self._logger:Assert(IsValidUserId(userId), `Invalid userId: {userId}`)
	self._logger:Debug(
		`Registered OnSave callback for userId {userId} with priority {priority or SAVE_PRIORITY.NORMAL}`
	)
	return self._saveCallbackManager:AddCallback(userId, "OnSave", callback, priority or SAVE_PRIORITY.NORMAL)
end

--[=[
	Registers a callback for final profile save for a specific player.

	Callbacks run in descending priority order. Higher numbers run first.

	This is not guaranteed to run in all cases where a profile is being released 
	(e.g. if the player leaves during loading before the profile session is established, or 
	if the server shuts down abruptly), but will run in the common case of a player leaving 
	while their profile is loaded.

	@param playerOrUserId Player | number
	@param callback (profile: Profile) -> ()
	@param priority number?
	@return SaveCallbackConnection
]=]
function PlayerProfileManager.OnLastSave(
	self: PPM_Internal,
	playerOrUserId: Player | number,
	callback: (profile: Profile) -> (),
	priority: number?
): SaveCallbackConnection
	self._logger:Assert(type(callback) == "function", "Expected callback to be a function")
	local userId = self:_getUserId(playerOrUserId)
	self._logger:Assert(IsValidUserId(userId), `Invalid userId: {userId}`)
	self._logger:Debug(
		`Registered OnLastSave callback for userId {userId} with priority {priority or SAVE_PRIORITY.NORMAL}`
	)
	return self._saveCallbackManager:AddCallback(userId, "OnLastSave", callback, priority or SAVE_PRIORITY.NORMAL)
end

--[=[
    Returns a snapshot of the player's current profile state.

    ```lua
    local status = manager:GetPlayerStatus(player)
    if status.isLoaded then
        print("Ready:", status.profile.Data.Coins)
    elseif status.isLoading then
        print("Still loading...")
    end
    ```

    @param playerOrUserId Player | number
    @return { isLoaded: boolean, isLoading: boolean, profile: Profile? }
]=]
function PlayerProfileManager.GetPlayerStatus(
	self: PPM_Internal,
	playerOrUserId: Player | number
): { isLoaded: boolean, isLoading: boolean, profile: Profile? }
	return {
		isLoaded = self:IsLoaded(playerOrUserId),
		isLoading = self:IsLoading(playerOrUserId),
		profile = self:GetProfile(playerOrUserId),
	}
end

--[=[
    Wipes a player's profile from the DataStore (right-to-erasure / data reset).
    
    This operation:
    - Acquires a delete-in-progress lock to prevent concurrent operations and load races
    - Sends a cross-server notification to kick any active sessions
    - Ends any local active profile session
    - Erases the profile data from the DataStore with bounded retries
    - Releases the lock to allow future loads (or on failure, via finally)
    
    **Returns**: Promise that resolves when the profile is successfully erased, or rejects with error.
    
    **Rejects if**:
    - userId is invalid (zero or non-integer)
    - Delete already in progress (lock exists)
    - Profile is currently loading (would race with StartSessionAsync)
    - RemoveAsync fails after retries

    ```lua
    manager:WipeProfile(userId):andThen(function()
        print("Profile wiped successfully")
    end):catch(function(err)
        warn("Wipe failed:", err)
    end)
    ```

    @param userId number
    @return Promise
]=]
function PlayerProfileManager.WipeProfile(self: PPM_Internal, userId: number): Promise<()>
	-- Validate userId
	if not IsValidUserId(userId) then
		return Promise.reject(`[👤] Invalid userId: {userId}`)
	end

	self._logger:Info(`WipeProfile initiated for userId {userId}`)

	-- Reject if profile is currently loading (would race with StartSessionAsync)
	if self._LoadingPlayers[userId] then
		return Promise.reject(`[👤] Cannot wipe profile for userId {userId}: profile is currently loading`)
	end

	-- Attempt to acquire the delete-in-progress lock
	if not self._wipeLockManager:AcquireLock(userId) then
		return Promise.reject(`[👤] Cannot wipe profile for userId {userId}: delete already in progress`)
	end

	-- Send cross-server wipe reset notification
	self._wipeLockManager:SendResetMessage(self._profileStore, self:_generatePlayerKey(userId), userId)

	-- End local active session if present
	local profile = self._PlayerProfileStorage[userId]
	if profile then
		self._logger:Info(`Ending active profile session for userId {userId} prior to wipe`)
		self:_endProfileSession(userId, profile, "profile_wipe")
	end

	-- Generate the player key for removal
	local playerKey = self:_generatePlayerKey(userId)

	-- RemoveAsync with bounded retries; lock is always released via :finally
	return RetryWithBackoff.retryPromise(function()
		return Promise.new(function(removeResolve, removeReject)
			local ok, result = pcall(function()
				return self._profileStore:RemoveAsync(playerKey)
			end)

			if not ok then
				removeReject(`[👤] RemoveAsync error for userId {userId}: {result}`)
				return
			end

			if result == true then
				self._logger:Debug(`RemoveAsync succeeded for userId {userId}`)
				removeResolve()
			else
				removeReject(`[👤] RemoveAsync returned false for userId {userId}`)
			end
		end)
	end, {
		maxAttempts = WIPE_RETRY_ATTEMPTS,
		baseDelay = WIPE_RETRY_DELAY,
		backoff = "Exponential",
	})
		:tap(function()
			self._logger:Info(`Successfully wiped profile for userId {userId}`)
		end)
		:finally(function()
			self._wipeLockManager:ReleaseLock(userId)
		end)
end

return PlayerProfileManager
