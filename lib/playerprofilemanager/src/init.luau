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
const MemoryStoreService = game:GetService("MemoryStoreService")

--// Imports //--
const Packages = script.Parent
const ProfileTypeDef = require(script.ProfileTypeDef)
const ProfileStore = require(Packages.ProfileStore)
const Janitor = require(Packages.Janitor)
const Signal = require(Packages.Signal)
const Promise = require(Packages.Promise)
const T = require(Packages.T)

--// Types //--
type table = { [any]: any }
type Promise = Promise.Promise
type Janitor = Janitor.Janitor
export type Profile = ProfileTypeDef.Profile
export type ProfileStore = ProfileTypeDef.ProfileStore

-- Typed signal aliases used throughout the module
type LoadSuccessSignal = Signal.Signal<(userId: number) -> (), number>
type LoadFailureSignal = Signal.Signal<(userId: number, err: string) -> (), number, string>
type ReleasingSignal = Signal.Signal<(userId: number, profile: Profile) -> (), number, Profile>
type WipeLockValue = {
	acquiredAt: number,
	initiator: string,
}
type WipeLockMap = {
	UpdateAsync: (
		self: WipeLockMap,
		key: string,
		transform: (existingValue: WipeLockValue?) -> WipeLockValue,
		expiration: number
	) -> WipeLockValue?,
	GetAsync: (self: WipeLockMap, key: string) -> WipeLockValue?,
	RemoveAsync: (self: WipeLockMap, key: string) -> (),
}

--[=[
    @interface DataMigrator
    @within PlayerProfileManager
    .FromVersion string | number
    .ToVersion string | number
    .Migrate (profileData: TFrom, userId: number) -> TTo

    Used to transform data from one version to another. Migrators must form a
    complete, unbroken chain from the oldest stored version to the current
    `DefaultDataSchema.__VERSION`. Gaps, duplicates, or a chain that does not
    terminate at the current version will cause an error at construction time.

    ```lua
    -- Convert the deprecated 'Candy' currency into 'Gems' at a 1:10 rate
    local migrator = {
        FromVersion = "0.0.1",
        ToVersion = "0.0.2",
        Migrate = function(data: table, _userId: number)
            data.Gems = (data.Gems or 0) + (data.Candy or 0) * 10
            data.Candy = nil
            return data
        end,
    }
    ```
]=]
type DataVersion = string | number
export type DataMigrator<TFrom = table, TTo = table> = {
	FromVersion: DataVersion,
	ToVersion: DataVersion,
	Migrate: (profileData: TFrom, userId: number) -> TTo,
}

-- Runtime validator table. Fields are T-checker functions — no type casts needed
-- since PPM_Config is declared explicitly below.
const ConfigType = {
	DataStoreKey = T.optional(T.string),
	DefaultDataSchema = T.table,
	UseMock = T.optional(T.boolean),
	Migrator = T.optional(T.array(T.table)),
	GetPlayerKeyCallback = T.optional(T.callback),
	ReconcileCallback = T.optional(T.callback),
	OnProfileLoadFailureCallback = T.optional(T.callback),
	Debug = T.optional(T.boolean),
	DebugProfileUserId = T.optional(T.number),
}
const ConfigInterface = T.interface(ConfigType)
const IsValidUserId = function(userId: any): boolean
	return T.number(userId) and userId % 1 == 0 and userId ~= 0
end

--[=[
    @within PlayerProfileManager
    @interface PPM_Config
    .DefaultDataSchema table
    .UseMock boolean?
    .Migrator {DataMigrator}?
    .DataStoreKey string?
    .GetPlayerKeyCallback ((userId: number) -> string)?
	.ReconcileCallback ((userId: number, profile: Profile) -> ())?
	.OnProfileLoadFailureCallback ((userId: number, err: string) -> ())?
    .Debug boolean?
    .DebugProfileUserId number?

	- **DataStoreKey** — DataStore key for player data. Defaults to `"PPM_PlayerData"`. When multiple PlayerProfileManagers are active at once, each manager must use a unique DataStoreKey.
    - **DefaultDataSchema** — Template used to reconcile and initialize profiles.
    - **UseMock** — Use a mock ProfileStore (useful for testing in Studio).
    - **Migrator** — Ordered chain of DataMigrators. Must be contiguous from oldest version to `DefaultDataSchema.__VERSION`.
    - **GetPlayerKeyCallback** — Override the per-player DataStore key (defaults to `"Player_{userId}"`).
    - **ReconcileCallback** — Called during profile load. Defaults to `profile:Reconcile()`.
    - **OnProfileLoadFailureCallback** — Called when all retries fail. Defaults to kicking the player.
    - **Debug** — Enables verbose debug logging.
    - **DebugProfileUserId** — When set, all userId lookups return this value instead (for testing with a specific profile).
]=]
export type PPM_Config = {
	DataStoreKey: string?,
	DefaultDataSchema: { [string]: any },
	UseMock: boolean?,
	Migrator: { DataMigrator }?,
	GetPlayerKeyCallback: ((userId: number) -> string)?,
	ReconcileCallback: ((userId: number, profile: Profile) -> ())?,
	OnProfileLoadFailureCallback: ((userId: number, err: string) -> ())?,
	Debug: boolean?,
	DebugProfileUserId: number?,
}

--[=[
    @type PlayerProfileManager
    @within PlayerProfileManager
    Public interface for `PlayerProfileManager` instances.
]=]
export type PlayerProfileManager = {
	ClassName: string,
	new: (config: PPM_Config) -> PlayerProfileManager,
	-- lifecycle signals (connect directly on the instance)
	PlayerProfileLoadSuccess: LoadSuccessSignal,
	PlayerProfileLoadFailure: LoadFailureSignal,
	PlayerProfileReleasing: ReleasingSignal,
	-- status
	IsLoaded: (self: PlayerProfileManager, playerOrUserId: Player | number) -> boolean,
	IsLoading: (self: PlayerProfileManager, playerOrUserId: Player | number) -> boolean,
	OnLoaded: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Promise,
	GetPlayerStatus: (
		self: PlayerProfileManager,
		playerOrUserId: Player | number
	) -> {
		isLoaded: boolean,
		isLoading: boolean,
		profile: Profile?,
	},
	-- profile access
	GetProfile: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Profile?,
	PromiseProfile: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Promise,
	WipeProfile: (self: PlayerProfileManager, userId: number) -> Promise,
	-- lifecycle
	Destroy: (self: PlayerProfileManager) -> (),
}

--[=[
    @type PPM_Internal
    @within PlayerProfileManager
    @private
    Extends `PlayerProfileManager` with private fields and methods.
    Use dot syntax with an explicit `self: PPM_Internal` parameter for full type coverage.
    ```lua
    function PlayerProfileManager.SomeMethod(self: PPM_Internal, ...)
        ...
    end
    ```
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
	_wipeLockMapName: string,
	-- private methods
	_setupCallbacks: (self: PPM_Internal) -> (),
	_initializeProfileStore: (self: PPM_Internal) -> (),
	_initializeWipeLocking: (self: PPM_Internal) -> (),
	_startPlayerManagement: (self: PPM_Internal) -> (),
	_reconcileProfile: (self: PPM_Internal, userId: number, profile: Profile) -> (),
	_migrateProfileData: (self: PPM_Internal, userId: number, profile: Profile) -> (),
	_generatePlayerKey: (self: PPM_Internal, userId: number) -> string,
	_attemptLoadProfile: (self: PPM_Internal, userId: number, player: Player?) -> Promise,
	_createPlayerData: (self: PPM_Internal, playerOrUserId: Player | number) -> Promise,
	_setupProfileSession: (self: PPM_Internal, userId: number, profile: Profile) -> (),
	_DebugPrint: (self: PPM_Internal, ...any) -> (),
	_getUserId: (self: PPM_Internal, playerOrUserId: Player | number) -> number,
	-- wipe state tracking
	_wipeLockMap: WipeLockMap?,
	_wipeLocksAcquired: { [number]: boolean },
	-- wipe methods
	_acquireWipeLockAsync: (self: PPM_Internal, userId: number) -> boolean,
	_isWipeLockedAsync: (self: PPM_Internal, userId: number) -> boolean,
	_releaseWipeLockAsync: (self: PPM_Internal, userId: number) -> (),
	_endProfileSession: (self: PPM_Internal, userId: number, profile: Profile, reason: string) -> (),
	_sendWipeResetMessageAsync: (self: PPM_Internal, userId: number) -> boolean,
}

-- Constants
const RETRY_PROFILE_LOAD_DELAY = 3
const RETRY_PROFILE_LOAD_ATTEMPTS = 5
const VERSION_KEY = "__VERSION"
const DEFAULT_DATA_STORE_KEY = "PPM_PlayerData"
const ACTIVE_DATA_STORE_KEYS = {} :: { [string]: boolean }
-- Wipe profile constants
const WIPE_LOCK_TTL_SECONDS = 120
const WIPE_LOCK_MAP_NAME = "PPM_WipeLocks"
const WIPE_RETRY_ATTEMPTS = 3
const WIPE_RETRY_DELAY = 2
const WIPE_RESET_KICK_MESSAGE = "Your player data is being reset. Please rejoin in a moment."
const WIPE_MESSAGE_KIND = "ProfileWipeReset"

--------------------------------------------------------------------------------
--// Local Functions //--
--------------------------------------------------------------------------------

--[[
    Resolves a userId to a `Player?` if they are still in-game.
]]
const function resolvePlayer(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

const function claimDataStoreKey(dataStoreKey: string)
	assert(
		not ACTIVE_DATA_STORE_KEYS[dataStoreKey],
		`[👤] DataStoreKey '{dataStoreKey}' is already in use by another active PlayerProfileManager. Configure a unique DataStoreKey for each manager instance.`
	)
	ACTIVE_DATA_STORE_KEYS[dataStoreKey] = true
end

const function releaseDataStoreKey(dataStoreKey: string)
	ACTIVE_DATA_STORE_KEYS[dataStoreKey] = nil
end

const function hashKeyName(value: string): number
	local hash = 5381
	for index = 1, #value do
		hash = (hash * 33 + string.byte(value, index)) % 2147483647
	end
	return hash
end

const function buildWipeLockMapName(dataStoreKey: string): string
	const sanitizedDataStoreKey = string.gsub(dataStoreKey, "[^%w_%-]", "_")
	const visibleKeyPrefix = string.sub(sanitizedDataStoreKey, 1, 40)
	return `{WIPE_LOCK_MAP_NAME}_{hashKeyName(dataStoreKey)}_{visibleKeyPrefix}`
end

--[[
    Finds the migrator whose FromVersion matches `fromVersion`, or nil if none.
    Duplicate detection is handled upfront by `validateMigratorChain`.
]]
const function lookupMigrator(migrators: { DataMigrator }, fromVersion: DataVersion): DataMigrator?
	for _, migration in ipairs(migrators) do
		if migration.FromVersion == fromVersion then
			return migration
		end
	end
	return nil
end

--[[
    Validates that `migrators` form a complete, linear chain ending at `targetVersion`.
    Errors at construction time so misconfiguration surfaces immediately rather than
    during a live player load.
]]
const function validateMigratorChain(migrators: { DataMigrator }, targetVersion: DataVersion)
	if #migrators == 0 then
		return
	end

	-- Build fromVersion -> migrator map; detect duplicates
	local fromMap: { [DataVersion]: DataMigrator } = {}
	for _, migration in ipairs(migrators) do
		if fromMap[migration.FromVersion] then
			error(
				`[👤] Duplicate migrator for version '{migration.FromVersion}'. Each version must have exactly one migrator.`
			)
		end
		fromMap[migration.FromVersion] = migration
	end

	-- Collect all ToVersions into a set
	local toVersionSet: { [DataVersion]: boolean } = {}
	for _, migration in ipairs(migrators) do
		toVersionSet[migration.ToVersion] = true
	end

	-- Entry point: a FromVersion that is not the ToVersion of any other migrator
	local entryVersion: DataVersion? = nil
	local entryCount = 0
	for fromVersion in fromMap do
		if not toVersionSet[fromVersion] then
			entryVersion = fromVersion
			entryCount += 1
		end
	end

	if entryCount == 0 then
		error("[👤] Migrator chain has a cycle — no entry point found.")
	elseif entryCount > 1 then
		error("[👤] Migrator chain has multiple disconnected entry points. The chain must be linear.")
	end

	-- Walk the chain from entry to end
	local visited: { [DataVersion]: boolean } = {}
	local current: DataVersion = entryVersion :: DataVersion
	while fromMap[current] do
		if visited[current] then
			error(`[👤] Migrator chain has a cycle at version '{current}'.`)
		end
		visited[current] = true
		current = (fromMap[current] :: DataMigrator).ToVersion
	end

	-- Chain must terminate at the target schema version
	if current ~= targetVersion then
		error(
			`[👤] Migrator chain ends at '{current}' but DefaultDataSchema["{VERSION_KEY}"] is '{targetVersion}'. The chain must end at the current schema version.`
		)
	end

	-- All migrators must be reachable (no orphaned branches)
	local visitedCount = 0
	for _ in visited do
		visitedCount += 1
	end
	if visitedCount ~= #migrators then
		error("[👤] Migrator chain has orphaned (unreachable) migrators.")
	end
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

const PlayerProfileManager = {}
PlayerProfileManager.ClassName = "PlayerProfileManager"
PlayerProfileManager.__index = PlayerProfileManager

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
	assert(ConfigInterface(config))

	local self = (setmetatable({}, PlayerProfileManager) :: any) :: PPM_Internal

	self._janitor = Janitor.new()
	self._PlayerProfileStorage = {} :: { [number]: Profile }
	self._LoadingPlayers = {} :: { [number]: boolean }
	self._wipeLocksAcquired = {} :: { [number]: boolean }
	self._config = config
	self._dataStoreKey = config.DataStoreKey or DEFAULT_DATA_STORE_KEY
	self._isMock = config.UseMock or false
	self._debugUserId = config.DebugProfileUserId or nil
	self._wipeLockMapName = buildWipeLockMapName(self._dataStoreKey)
	if self._debugUserId then
		warn(
			`[👤] DebugProfileUserId is active — all userId lookups return {self._debugUserId} (single-player testing only)`
		)
	end

	-- Lifecycle signals — directly accessible fields with full types
	self.PlayerProfileLoadSuccess = (Signal.new() :: any) :: LoadSuccessSignal
	self.PlayerProfileLoadFailure = (Signal.new() :: any) :: LoadFailureSignal
	self.PlayerProfileReleasing = (Signal.new() :: any) :: ReleasingSignal
	self._janitor:Add(self.PlayerProfileLoadSuccess, "Destroy")
	self._janitor:Add(self.PlayerProfileLoadFailure, "Destroy")
	self._janitor:Add(self.PlayerProfileReleasing, "Destroy")

	-- Validate migration chain upfront so misconfiguration errors at construction
	if config.Migrator and #config.Migrator > 0 then
		validateMigratorChain(config.Migrator, config.DefaultDataSchema[VERSION_KEY])
	end

	local ok, err = pcall(function()
		claimDataStoreKey(self._dataStoreKey)
		self:_setupCallbacks()
		self:_initializeProfileStore()
		self:_initializeWipeLocking()
		self:_startPlayerManagement()
	end)
	if not ok then
		releaseDataStoreKey(self._dataStoreKey)
		error(err)
	end

	return (self :: any) :: PlayerProfileManager
end

--[=[
    @private
    Initializes the MemoryStore-backed wipe lock map for delete-in-progress tracking.
]=]
function PlayerProfileManager._initializeWipeLocking(self: PPM_Internal)
	local ok, result = pcall(function()
		return MemoryStoreService:GetHashMap(self._wipeLockMapName)
	end)
	if ok then
		self._wipeLockMap = (result :: any) :: WipeLockMap
		self:_DebugPrint(`Wipe lock MemoryStore initialized: {self._wipeLockMapName}`)
	else
		warn(`[👤] Failed to initialize wipe lock MemoryStore '{self._wipeLockMapName}': {result}`)
		self._wipeLockMap = nil
	end
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
		self:_DebugPrint("Using Mock ProfileStore for testing")
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
		warn(`[👤] Skipping reconcile for userId {userId} — player not in game`)
		return
	end
	self:_DebugPrint(`Reconciling profile for {player.Name}.`)
	self._reconcileCallback(userId, profile)
end

--[=[
    @private
    Walks the migration chain until the profile version matches the schema version.
    Relies on `validateMigratorChain` having verified the chain is complete at construction.
]=]
function PlayerProfileManager._migrateProfileData(self: PPM_Internal, userId: number, profile: Profile)
	if not self._config.Migrator then
		return
	end

	local migrators = self._config.Migrator

	while
		profile.Data[VERSION_KEY] ~= nil
		and profile.Data[VERSION_KEY] ~= self._config.DefaultDataSchema[VERSION_KEY]
	do
		local currentVersion = profile.Data[VERSION_KEY]
		local migrator = lookupMigrator(migrators, currentVersion)

		if not migrator then
			error(`[👤] No migrator found for userId {userId}'s data version '{currentVersion}'.`)
		end

		local nextVersion = migrator.ToVersion
		self:_DebugPrint(`Migrating userId {userId}'s data from {currentVersion} to {nextVersion}`)

		local newData: table?
		local ok, err = pcall(function()
			newData = migrator.Migrate(profile.Data, userId)
			local migratorName = `{currentVersion} -> {nextVersion}`
			if not newData then
				warn(
					`[👤] Migrator[{migratorName}] returned nil — assuming same table. Return the modified table to silence this warning.`
				)
			else
				assert(type(newData) == "table", `[👤] Migrator[{migratorName}] must return a table`)
			end
		end)

		if not ok then
			error(`[👤] Error migrating userId {userId}'s data: {err}`)
		end

		-- Mutate the existing data table in-place so ProfileStore's internal reference stays valid.
		-- If the migrator returned a distinct table, copy its contents back into the original.
		if newData and newData ~= profile.Data then
			for k in profile.Data do
				profile.Data[k] = nil
			end
			for k, v in newData do
				profile.Data[k] = v
			end
		end
		profile.Data[VERSION_KEY] = nextVersion
	end
end

--[=[
    @private
    Generates the DataStore key for a userId.
]=]
function PlayerProfileManager._generatePlayerKey(self: PPM_Internal, userId: number): string
	if userId == 0 then
		warn(`[👤] Invalid userId provided to _generatePlayerKey: {userId}.`)
	end

	return if self._config.GetPlayerKeyCallback then self._config.GetPlayerKeyCallback(userId) else `Player_{userId}`
end

--[=[
    @private
    Single attempt to start a ProfileStore session for the given userId.
]=]
function PlayerProfileManager._attemptLoadProfile(self: PPM_Internal, userId: number, player: Player?): Promise
	return Promise.new(function(resolve, reject)
		-- Preflight: check if profile is in the process of being wiped
		if self:_isWipeLockedAsync(userId) then
			reject("Profile is being reset — please rejoin in a moment")
			return
		end

		if not player or not player:IsDescendantOf(Players) then
			reject("Player left before profile loading started")
			return
		end

		local playerKey = self:_generatePlayerKey(userId)
		self:_DebugPrint(`Attempting to load profile for {player.Name} with key: {playerKey}`)

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
			self:_migrateProfileData(userId, profile)
			self:_reconcileProfile(userId, profile)
		end)

		if not success then
			profile:EndSession()
			reject(`Failed to process profile data for {player.Name}: {err}`)
			return
		end

		if player.Parent ~= Players then
			profile:EndSession()
			reject("Player left before profile session fully started")
			return
		end
		self:_DebugPrint(`Profile successfully loaded for {player.Name}`)
		resolve(profile)
	end)
end

--[=[
    @private
    Loads a player's profile with retry logic. Main entry point from `_startPlayerManagement`.
]=]
function PlayerProfileManager._createPlayerData(self: PPM_Internal, playerOrUserId: Player | number): Promise
	local userId = self:_getUserId(playerOrUserId)
	local player = resolvePlayer(userId)

	if self._LoadingPlayers[userId] then
		self:_DebugPrint(`Profile already loading for userId {userId}, skipping duplicate attempt`)
		return Promise.reject("Profile already being loaded")
	end

	self._LoadingPlayers[userId] = true
	self:_DebugPrint(`Starting profile load for userId {userId}`)

	return Promise.retryWithDelay(function()
		local prom = self:_attemptLoadProfile(userId, player)
		prom:catch(function(err)
			warn(`[👤] Failed to load profile for userId {userId}: {err}`)
			warn(`[👤] Retrying in {RETRY_PROFILE_LOAD_DELAY} seconds...`)
		end)
		return prom
	end, RETRY_PROFILE_LOAD_ATTEMPTS, RETRY_PROFILE_LOAD_DELAY)
		:andThen(function(profile)
			self:_setupProfileSession(userId, profile)
			self:_DebugPrint(`Successfully loaded profile for userId {userId}`)
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

	-- Register message handler to process cross-server wipe reset notifications
	profile:MessageHandler(function(message, processed)
		if type(message) == "table" then
			const messageTable = message :: { [string]: any }
			if messageTable.kind == WIPE_MESSAGE_KIND and messageTable.userId == userId then
				self:_DebugPrint(`Received wipe reset message for userId {userId} from cross-server`)
				processed() -- Mark message as handled
				if player and player.Parent == Players then
					player:Kick(WIPE_RESET_KICK_MESSAGE)
				end
			end
		end
	end)

	profile.OnSessionEnd:Connect(function()
		self:_DebugPrint(`Profile session ended for userId {userId}`)
		-- Guard against double-fire: _endProfileSession may have already released the profile
		if self._PlayerProfileStorage[userId] then
			self.PlayerProfileReleasing:Fire(userId, profile)
			self._PlayerProfileStorage[userId] = nil
		end
		if player and player.Parent == Players then
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
				self:_DebugPrint(`Cleaning up profile for leaving player userId {userId}`)
				self:_endProfileSession(userId, profile, "player_leaving")
				if self._isMock then
					self._profileStore:RemoveAsync(self:_generatePlayerKey(userId))
					self:_DebugPrint(`Removed mock profile for userId {userId}`)
				end
			end
		end),
		"Disconnect",
		connKey
	)
end

function PlayerProfileManager._DebugPrint(self: PPM_Internal, ...)
	if self._config.Debug then
		print("[👤]", ...)
	end
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
    Attempts to acquire a MemoryStore-backed delete-in-progress lock for the given userId.
    Returns true if the lock was successfully acquired, false if already locked.
]=]
function PlayerProfileManager._acquireWipeLockAsync(self: PPM_Internal, userId: number): boolean
	if not self._wipeLockMap then
		self:_DebugPrint(`Failed to acquire wipe lock for userId {userId}: MemoryStore unavailable`)
		return false
	end

	const lockKey = `user_{userId}`
	local didAcquire = false
	const ok, result = pcall(function()
		return self._wipeLockMap:UpdateAsync(lockKey, function(existingValue: WipeLockValue?): WipeLockValue
			-- If already locked, keep the existing value and mark as not acquired.
			if existingValue ~= nil then
				return existingValue
			end
			didAcquire = true
			-- Return the new lock value
			return { acquiredAt = os.time(), initiator = game.JobId }
		end, WIPE_LOCK_TTL_SECONDS)
	end)

	if ok and result ~= nil and didAcquire then
		self._wipeLocksAcquired[userId] = true
		self:_DebugPrint(`Acquired wipe lock for userId {userId}`)
		return true
	end
	self:_DebugPrint(`Failed to acquire wipe lock for userId {userId}: already locked or MemoryStore error`)
	return false
end

--[=[
    @private
    Checks if a delete-in-progress lock exists for the given userId.
    Returns true if locked, false if not locked or MemoryStore unavailable.
]=]
function PlayerProfileManager._isWipeLockedAsync(self: PPM_Internal, userId: number): boolean
	if not self._wipeLockMap then
		return false
	end

	const lockKey = `user_{userId}`
	const ok, result = pcall(function()
		return self._wipeLockMap:GetAsync(lockKey)
	end)

	if ok then
		return result ~= nil
	end
	return false
end

--[=[
    @private
    Releases the delete-in-progress lock for the given userId.
    Safe to call even if lock is not held.
]=]
function PlayerProfileManager._releaseWipeLockAsync(self: PPM_Internal, userId: number): ()
	if not self._wipeLockMap then
		return
	end

	self._wipeLocksAcquired[userId] = nil
	const lockKey = `user_{userId}`
	const ok = pcall(function()
		self._wipeLockMap:RemoveAsync(lockKey)
	end)

	if ok then
		self:_DebugPrint(`Released wipe lock for userId {userId}`)
	else
		warn(`[👤] Failed to release wipe lock for userId {userId}`)
	end
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
	self:_DebugPrint(`Ending profile session for userId {userId} (reason: {reason})`)
	self.PlayerProfileReleasing:Fire(userId, profile)
	profile:EndSession()
	self._PlayerProfileStorage[userId] = nil
end

--[=[
    @private
    Sends a cross-server reset notification via ProfileStore messaging.
    Called during WipeProfile to alert other servers to kick the user.
]=]
function PlayerProfileManager._sendWipeResetMessageAsync(self: PPM_Internal, userId: number): boolean
	const playerKey = self:_generatePlayerKey(userId)
	const message = {
		kind = WIPE_MESSAGE_KIND,
		userId = userId,
		requestId = `{game.JobId}_{os.time()}_{math.random()}`,
		issuedAt = os.time(),
	}

	const ok, result = pcall(function()
		return self._profileStore:MessageAsync(playerKey, message)
	end)

	if ok and result then
		self:_DebugPrint(`Sent wipe reset message for userId {userId}`)
		return true
	end
	self:_DebugPrint(`Failed to send wipe reset message for userId {userId}: {if ok then result else "error"}`)
	return false
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Destroys the manager, cleans up all signals and connections.
]=]
function PlayerProfileManager.Destroy(self: PPM_Internal)
	-- Release any wipe locks still held by this server instance so they don't
	-- block future loads until the TTL expires.
	for userId in self._wipeLocksAcquired do
		self:_releaseWipeLockAsync(userId)
	end
	releaseDataStoreKey(self._dataStoreKey)
	self._janitor:Destroy()
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
function PlayerProfileManager.OnLoaded(self: PPM_Internal, playerOrUserId: Player | number): Promise
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
	assert(self.ClassName == "PlayerProfileManager", "Must be called on a PlayerProfileManager instance.")
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
function PlayerProfileManager.PromiseProfile(self: PPM_Internal, playerOrUserId: Player | number): Promise
	assert(self.ClassName == "PlayerProfileManager", "Must be called on a PlayerProfileManager instance.")
	return self:OnLoaded(playerOrUserId):andThen(function()
		local profile = self:GetProfile(playerOrUserId)
		if not profile then
			return Promise.reject("Profile was unloaded before it could be returned")
		end
		return profile
	end)
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
function PlayerProfileManager.WipeProfile(self: PPM_Internal, userId: number): Promise
	-- Validate userId
	if not IsValidUserId(userId) then
		return Promise.reject(`[👤] Invalid userId: {userId}`)
	end

	self:_DebugPrint(`WipeProfile initiated for userId {userId}`)

	-- Reject if profile is currently loading (would race with StartSessionAsync)
	if self._LoadingPlayers[userId] then
		return Promise.reject(`[👤] Cannot wipe profile for userId {userId}: profile is currently loading`)
	end

	-- Attempt to acquire the delete-in-progress lock
	if not self:_acquireWipeLockAsync(userId) then
		return Promise.reject(`[👤] Cannot wipe profile for userId {userId}: delete already in progress`)
	end

	-- Send cross-server wipe reset notification
	self:_sendWipeResetMessageAsync(userId)

	-- End local active session if present
	local profile = self._PlayerProfileStorage[userId]
	if profile then
		self:_DebugPrint(`Ending active profile session for userId {userId} prior to wipe`)
		self:_endProfileSession(userId, profile, "profile_wipe")
	end

	-- Generate the player key for removal
	local playerKey = self:_generatePlayerKey(userId)

	-- RemoveAsync with bounded retries; lock is always released via :finally
	return Promise.retryWithDelay(function()
		return Promise.new(function(removeResolve, removeReject)
			local ok, result = pcall(function()
				return self._profileStore:RemoveAsync(playerKey)
			end)

			if not ok then
				removeReject(`[👤] RemoveAsync error for userId {userId}: {result}`)
				return
			end

			if result == true then
				self:_DebugPrint(`RemoveAsync succeeded for userId {userId}`)
				removeResolve()
			else
				removeReject(`[👤] RemoveAsync returned false for userId {userId}`)
			end
		end)
	end, WIPE_RETRY_ATTEMPTS, WIPE_RETRY_DELAY)
		:tap(function()
			self:_DebugPrint(`Successfully wiped profile for userId {userId}`)
		end)
		:finally(function()
			self:_releaseWipeLockAsync(userId)
		end)
end

return PlayerProfileManager
