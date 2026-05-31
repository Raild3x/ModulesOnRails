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
    - Data migration system with version tracking
    - Robust error handling and edge case management
    - Singleton pattern for easy access across your game
    - Mock support for testing
    - Comprehensive event system for profile lifecycle
    
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
    
    -- Or wait for it to load
    manager:PromiseProfile(player):andThen(function(profile)
        profile.Data.Level += 1
    end)
    ```
]=]

--// Services //--
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent
local ProfileTypeDef = require(script.ProfileTypeDef)
local ProfileStore = require(Packages.ProfileStore)
local RailUtil = require(Packages.RailUtil)
local Promise = require(Packages.Promise)
local BaseObject = require(Packages.BaseObject)
local T = require(Packages.T)

local SuperClass = BaseObject

--// Types //--
type table = { [any]: any }
type Promise = Promise.Promise
export type Profile = ProfileTypeDef.Profile

--[=[
    @interface DataMigrator
    @within PlayerProfileManager
    .FromVersion string
    .ToVersion string
    .Migrate (profileData: table, profileOwner: Player) -> (table)

    Used to Transform data from one version to another
    ```lua
    -- Turn all the deprecated currency 'Candy' into the new currency 'Gems' at a  1:10 rate
    local migrator = {
        FromVersion = "0.0.1",
        ToVersion = "0.0.2"
        Migrate = function(data: table, plr: Player)
            if not data.Gems then
                data.Gems = 0
            end

            local candy = data.Candy or 0
            data.Gems += candy * 10
            data.Candy = nil

            return data
        end
    }
    ```
]=]
type DataVersion = string | number
export type DataMigrator<F = table, T = table> = {
	FromVersion: DataVersion,
	ToVersion: DataVersion,
	Migrate: (profileData: F, profileOwner: Player) -> T,
}

local ConfigType = {
	DataStoreKey = T.optional(T.string) :: string?,
	DefaultDataSchema = T.table :: { [string]: any },
	UseMock = T.optional(T.boolean) :: boolean?,
	Migrator = T.optional(T.array(T.table)) :: { DataMigrator }?,
	GetPlayerKeyCallback = T.optional(T.callback) :: ((userId: number) -> string)?,
	ReconcileCallback = T.optional(T.callback) :: ((Player, Profile) -> ())?,
	OnProfileLoadFailureCallback = T.optional(T.callback) :: ((Player, string) -> ())?,

	Debug = T.optional(T.boolean) :: boolean?,
}
local ConfigInterface = T.interface(ConfigType)

--[=[
    @within PlayerProfileManager
    @interface PPM_Config
    .DefaultDataSchema table
    .UseMock boolean?
    .Migrator {DataMigrator}
    .DataStoreKey string?
    .GetPlayerKeyCallback ((player: Player) -> (string))?
    .ReconcileCallback ((player: Player, profile: Profile) -> ())?
    .OnProfileLoadFailureCallback ((player: Player, err: string) -> ())?

    - **DataStoreKey** is the internal Key used for the PlayerData's DataStore.
    - **DefaultDataSchema** is a template table that is used for reconciling the player's profile with. It is what new players are given if they dont have existing data.
    - **UseMock** determines whether or not a Mock ProfileStore will be used.
    - **Migrator** is a table of DataMigrators that are used to transform data from one version to another.

    - **GetPlayerKeyCallback** is a callback that is used to fetch the Key that each player's data is mapped to.
    - **ReconcileCallback** is a callback that is called when the system attempts to reconcile the players profile. It will default to calling Profile:Reconcile if not provided.
    - **OnProfileLoadFailureCallback** is a callback that is called if the player's data fails to load. It will default to kicking the player if not provided.
]=]
export type PPM_Config = typeof(ConfigType)

-- Constants
local RETRY_PROFILE_LOAD_DELAY = 3
local RETRY_PROFILE_LOAD_ATTEMPTS = 5
local VERSION_KEY = "__VERSION"
local DEFAULT_DATA_STORE_KEY = "PPM_PlayerData"

-- Debug profile constants
local DEBUG_USER_ID = 12345
local DEBUG_PROFILE_ACTIVE = false -- Will be set by external systems

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local PlayerProfileManager = setmetatable({}, SuperClass)
PlayerProfileManager.ClassName = "PlayerProfileManager"
PlayerProfileManager.__index = PlayerProfileManager

PlayerProfileManager.DEBUG_USER_ID = DEBUG_USER_ID
PlayerProfileManager.DEBUG_PROFILE_ACTIVE = DEBUG_PROFILE_ACTIVE

--[=[
    Creates a new PlayerProfileManager. Takes a config table, see PPM_Config for more info on the individual
    fields it supports.

    ```lua
    PlayerProfileManager.start({
        DefaultDataSchema = {
            __VERSION = "0.0.0";
            Currency = 0;
        };
    })
    ```
]=]
function PlayerProfileManager.new(config: PPM_Config): PlayerProfileManager
	-- Validate configuration
	assert(ConfigInterface(config))

	local self = setmetatable(SuperClass.new(), PlayerProfileManager)

	-- Initialize signals
	self:RegisterSignal("PlayerProfileLoadFailure")
	self:RegisterSignal("PlayerProfileLoadSuccess")
	self:RegisterSignal("PlayerProfileReleasing")

	-- Initialize storage
	self._PlayerProfileStorage = {} :: { [number]: Profile }

	-- Initialize loading state tracking
	self._LoadingPlayers = {} :: { [number]: boolean }

	-- Store configuration
	self._config = config
	self._isMock = config.UseMock or false

	-- Set up callback functions with defaults
	self:_setupCallbacks()

	-- Initialize ProfileStore
	self:_initializeProfileStore()

	-- Start managing existing and joining players
	self:_startPlayerManagement()

	return self
end

--[=[
    @private
    Sets up callback functions with sensible defaults
]=]
function PlayerProfileManager:_setupCallbacks()
	self._reconcileCallback = self._config.ReconcileCallback or function(_: Player, profile)
		profile:Reconcile()
	end

	self._loadFailureCallback = self._config.OnProfileLoadFailureCallback
		or function(player: Player, err: string)
			player:Kick(
				"Something went wrong and we failed to load your player data. Please rejoin the game. "
					.. "If this issue persists, please contact the developer.\n"
					.. tostring(err)
			)
		end
end

--[=[
    @private
    Initializes the ProfileStore with appropriate settings
]=]
function PlayerProfileManager:_initializeProfileStore()
	local DatastoreKey = self._config.DataStoreKey or DEFAULT_DATA_STORE_KEY
	self._profileStore = ProfileStore.New(DatastoreKey, self._config.DefaultDataSchema)

	if self._isMock then
		self._profileStore = self._profileStore.Mock
		self:_DebugPrint("Using Mock ProfileStore for testing")
	end
end

--[=[
    @private
    Starts managing player lifecycle events
]=]
function PlayerProfileManager:_startPlayerManagement()
	self:AddTask(RailUtil.Player.forEachPlayer(function(player, janitor)
		janitor:AddPromise(self:_createPlayerData(player))
	end))
end

--[=[
    @private
]=]
function PlayerProfileManager:_reconcileProfile(player: Player, profile: Profile)
	self:_DebugPrint(`Reconciling {player.Name}'s profile.`)
	self._reconcileCallback(player, profile)
end

--[=[
    @private
    Looks up a migrator function for a specific version with validation
]=]
function PlayerProfileManager:_lookupMigrator(fromVersion: DataVersion): DataMigrator?
	if not self._config.Migrator or #self._config.Migrator == 0 then
		return nil
	end

	local migrator = nil
	for _, migration in ipairs(self._config.Migrator) do
		if migration.FromVersion == fromVersion then
			if migrator then
				error(
					`[👤] Multiple migrators found for version {fromVersion}. Each version should have exactly one migrator.`
				)
			end
			migrator = migration
		end
	end

	return migrator
end

--[=[
    @private
    Attempts to migrate the player's profile data to the latest version.
]=]
function PlayerProfileManager:_migrateProfileData(player: Player, profile: Profile)
	if not self._config.Migrator then
		return
	end

	-- Handle migrations
	while profile.Data[VERSION_KEY] and profile.Data[VERSION_KEY] ~= self._config.DefaultDataSchema[VERSION_KEY] do
		local currentVersion = profile.Data[VERSION_KEY]

		local migrator = self:_lookupMigrator(currentVersion)

		if migrator then
			local nextVersion = migrator.ToVersion

			self:_DebugPrint(`Migrating {player.Name}'s data from {currentVersion} to {nextVersion}`)

			local newData
			local ok, err = pcall(function()
				newData = migrator.Migrate(profile.Data, player)

				local MigratorName = currentVersion .. " -> " .. nextVersion
				if not newData then
					warn(
						`[👤] Migrator[{MigratorName}] did not return new data, assuming same table. Have your migrator return a table to silence this warning.`
					)
				else
					assert(type(newData) == "table", `[👤] Migrator[{MigratorName}] must return a table`)
				end
			end)

			if not ok then
				error(`[👤] Error migrating {player.Name}'s data: {err}`)
			else
				newData[VERSION_KEY] = nextVersion
				profile.Data = newData
			end
		else
			error(`[👤] No migrator found to migrate {player.Name}'s data from version '{currentVersion}'.`)
		end
	end
end

--[=[
    @private
    Generates a unique key for the player's profile data
]=]
function PlayerProfileManager:_generatePlayerKey(playerOrUserId: Player | number | string): string
	local userId: number

	if type(playerOrUserId) == "number" then
		userId = playerOrUserId
	elseif type(playerOrUserId) == "string" then
		local convertedUserId = tonumber(playerOrUserId)
		assert(convertedUserId, "Invalid string userId provided to _generatePlayerKey")
		userId = convertedUserId
	else
		assert(
			typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player"),
			"Invalid argument provided to _generatePlayerKey - expected Player, number, or string"
		)
		userId = playerOrUserId.UserId
	end

	if userId <= 0 then
		warn(`[👤] Invalid userId provided to _generatePlayerKey: {userId}.`)
	end

	return if self._config.GetPlayerKeyCallback then self._config.GetPlayerKeyCallback(userId) else `Player_{userId}`
end

--[=[
    @private
    Attempts to load and initialize a single profile for the given player
]=]
function PlayerProfileManager:_attemptLoadProfile(player: Player): Promise
	return Promise.new(function(resolve, reject)
		local userId = self:_getUserId(player)
		-- Early exit check - player left before we started
		if not player:IsDescendantOf(Players) then
			reject("Player left before profile loading started")
			return
		end

		local playerKey = self:_generatePlayerKey(userId)
		self:_DebugPrint(`Attempting to load profile with key: {playerKey}`)

		-- Start the ProfileStore session
		local profile = self._profileStore:StartSessionAsync(playerKey, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})

		if not profile then
			reject(`Profile failed to load for {player.Name}`)
			return
		end

		-- GDPR compliance
		profile:AddUserId(userId)

		-- Check if player left during loading
		if not player:IsDescendantOf(Players) then
			profile:EndSession()
			reject("Player left while profile was loading")
			return
		end

		-- Apply data migrations and reconciliation
		local success, err = pcall(function()
			self:_migrateProfileData(player, profile)
			self:_reconcileProfile(player, profile)
		end)

		if not success then
			profile:EndSession()
			reject(`Failed to process profile data for {player.Name}: {err}`)
			return
		end

		-- Final check before resolving
		if player.Parent == Players then
			self:_DebugPrint(`Profile successfully loaded for {player.Name}`)
			resolve(profile)
		else
			profile:EndSession()
			reject("Player left before profile session fully started")
		end
	end)
end

--[=[
    @private
    Main entry point for loading a player's profile data with retry logic
]=]
function PlayerProfileManager:_createPlayerData(player: Player): Promise
	local userId = self:_getUserId(player)

	-- Prevent duplicate loading attempts
	if self._LoadingPlayers[userId] then
		self:_DebugPrint(`Profile already loading for {player.Name}, skipping duplicate attempt`)
		return Promise.reject("Profile already being loaded")
	end

	-- Mark as loading
	self._LoadingPlayers[userId] = true
	self:_DebugPrint(`Starting profile load for {player.Name}`)

	return Promise.retryWithDelay(function()
		local prom = self:_attemptLoadProfile(player)
		prom:catch(function(err)
			warn(`[👤] Failed to load profile for {player.Name}: {err}`)
			warn(`[👤] Retrying in {RETRY_PROFILE_LOAD_DELAY} seconds...`)
		end)
		return prom
	end, RETRY_PROFILE_LOAD_ATTEMPTS, RETRY_PROFILE_LOAD_DELAY)
		:andThen(function(profile)
			return self:_setupProfileSession(player, profile)
		end)
		:andThen(function()
			self:_DebugPrint(`Successfully loaded profile for {player.Name}`)
			self:FireSignal("PlayerProfileLoadSuccess", userId)
		end)
		:catch(function(err)
			self:FireSignal("PlayerProfileLoadFailure", userId, err)
			self._loadFailureCallback(player, err)
		end)
		:finally(function()
			-- Always clear loading state
			self._LoadingPlayers[userId] = nil
		end)
end

--[=[
    @private
    Sets up the profile session and event handlers after successful load
]=]
function PlayerProfileManager:_setupProfileSession(player: Player, profile: Profile): Promise
	return Promise.new(function(resolve)
		local userId = self:_getUserId(player)
		-- Store the profile
		self._PlayerProfileStorage[userId] = profile

		-- Handle profile session end during play
		profile.OnSessionEnd:Connect(function()
			self:_DebugPrint(`Profile session ended for {player.Name}`)
			self:FireSignal("PlayerProfileReleasing", player, profile)
			self._PlayerProfileStorage[userId] = nil

			-- Only kick if the player is still in the game
			if player.Parent == Players then
				player:Kick("Profile session ended - Please rejoin")
			end
		end)

		-- Handle player leaving
		local playerRemovingConnection
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(removingPlayer)
			if removingPlayer == player then
				playerRemovingConnection:Disconnect()
				self:_DebugPrint(`Cleaning up profile for leaving player {player.Name}`)
				self:FireSignal("PlayerProfileReleasing", userId, profile)

				profile:EndSession()

				-- Clean up mock data if needed
				if self._isMock then
					self._profileStore:RemoveAsync(self:_generatePlayerKey(userId))
					self:_DebugPrint(`Removed mock profile for {player.Name}`)
				end
			end
		end)

		resolve()
	end)
end

--[=[
    @private
    Generates a promise that will reject when the player leaves or the profile fails to load.
]=]
function PlayerProfileManager:_PromisePlayerLoadEventFailure(player: Player | number): Promise
	local userId = self:_getUserId(player)
	return Promise.fromEvent(self:GetSignal("PlayerProfileLoadFailure"), function(loadedUserId: number)
		return loadedUserId == userId
	end):andThen(function()
		return Promise.reject("Failed to load profile for " .. tostring(player))
	end)
end

--[=[
    @private
    Generates a promise that will resolve when the player's profile is loaded.
]=]
function PlayerProfileManager:_PromisePlayerLoadEventSuccess(player: Player | number): Promise
	if self:IsLoaded(player) then
		return Promise.resolve()
	end
	local userId = self:_getUserId(player)
	return Promise.fromEvent(self:GetSignal("PlayerProfileLoadSuccess"), function(loadedUserId: number)
		return loadedUserId == userId
	end)
end

function PlayerProfileManager:_DebugPrint(...)
	if self._config.Debug then
		print("[👤]", ...)
	end
end

--[=[
    @private
    Helper function to safely extract userId from Player or number
]=]
function PlayerProfileManager:_getUserId(player: Player | number): number
	if DEBUG_PROFILE_ACTIVE then
		warn("[👤] Debug profile active - returning debug userId")
		return DEBUG_USER_ID
	end
	if type(player) == "number" then
		return player
	else
		return player.UserId
	end
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Returns whether or not the player's profile is currently loaded.

    ```lua
    local isLoaded = PlayerProfileManager:IsLoaded(player)
    ```

    @param player Player
    @return boolean
]=]
function PlayerProfileManager:IsLoaded(player: Player | number): boolean
	local userId = self:_getUserId(player)
	return self._PlayerProfileStorage[userId] ~= nil
end

--[=[
    Returns a promise that will resolve when the player's profile is loaded.
    Rejects if the player leaves or the profile fails to load.

    ```lua
    PlayerProfileManager:OnLoaded(player):andThen(function()
        print("Profile loaded for " .. player.Name)
    end)
    ```

    @param player Player | number
    @return Promise<()>
]=]
function PlayerProfileManager:OnLoaded(player: Player | number): Promise
	return Promise.race {
		self:_PromisePlayerLoadEventFailure(player),
		self:_PromisePlayerLoadEventSuccess(player),
	}
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    @private
    @unreleased
    STUB: This method is not yet implemented.
    Wipes the player's profile from the data store.
    Use this in cases where you need to reset a player's data or
    comply with a right to erasure request.
]=]
function PlayerProfileManager:WipeProfile(_userId: number): Promise
	return Promise.reject("WipeProfile method is not yet implemented")
end

--[=[
    Returns the player's profile, if it exists. May return nil if this players profile is not loaded.

    ```lua
    local profile: Profile? = PlayerProfileManager:GetProfile(player)
    ```

    @param player Player | number
    @return Profile?
]=]
function PlayerProfileManager:GetProfile(player: Player | number): Profile?
	assert(getmetatable(self) == PlayerProfileManager, "Must call using the Singleton instance.")
	local userId = self:_getUserId(player)
	return self._PlayerProfileStorage[userId]
end

--[=[
    Returns a promise that resolves with the player's profile when it is ready.
    Rejects if the player leaves or the profile fails to load.

    ```lua
    PlayerProfileManager:PromiseProfile(player):andThen(function(profile: Profile)
        print("Profile loaded for " .. player.Name)
    end)
    ```

    @param player Player | number
    @return Promise<Profile>
]=]
function PlayerProfileManager:PromiseProfile(player: Player | number): Promise
	assert(getmetatable(self) == PlayerProfileManager, "Must call using the Singleton instance.")

	return self:OnLoaded(player):andThen(function()
		return self:GetProfile(player)
	end)
end

--[=[
    Returns whether the player's profile is currently being loaded.
    
    ```lua
    local isLoading = PlayerProfileManager:IsLoading(player)
    ```
    
    @param player Player | number
    @return boolean
]=]
function PlayerProfileManager:IsLoading(player: Player | number): boolean
	local userId = self:_getUserId(player)
	return self._LoadingPlayers[userId] == true
end

--[=[
    Returns detailed status information about a player's profile state.
    
    ```lua
    local status = PlayerProfileManager:GetPlayerStatus(player)
    if status.isLoaded then
        print("Profile is ready!")
    elseif status.isLoading then
        print("Profile is still loading...")
    else
        print("Profile not loaded yet")
    end
    ```
    
    @param player Player | number
    @return {isLoaded: boolean, isLoading: boolean, profile: Profile?}
]=]
function PlayerProfileManager:GetPlayerStatus(
	player: Player | number
): { isLoaded: boolean, isLoading: boolean, profile: Profile? }
	return {
		isLoaded = self:IsLoaded(player),
		isLoading = self:IsLoading(player),
		profile = self:GetProfile(player),
	}
end

--[=[
    Enables debug profile mode where a specific userId's profile data will be used
    for testing purposes.
    
    @param userId number -- The userId whose profile data to use for testing
]=]
function PlayerProfileManager:EnableDebugProfile(userId: number)
	DEBUG_USER_ID = userId
	DEBUG_PROFILE_ACTIVE = true
	self:_DebugPrint(`Debug profile enabled. Using UserId: {userId}`)
end

--[=[
    Disables debug profile mode, returning to normal profile loading behavior.
]=]
function PlayerProfileManager:DisableDebugProfile()
	DEBUG_PROFILE_ACTIVE = false
	self:_DebugPrint("Debug profile disabled.")
end

--[=[
    Returns whether debug profile mode is currently active.
]=]
function PlayerProfileManager:IsDebugProfileActive(): boolean
	return DEBUG_PROFILE_ACTIVE
end

--[=[
    Returns the userId being used for debug profile mode.
]=]
function PlayerProfileManager:GetDebugUserId(): number
	return DEBUG_USER_ID
end

export type PlayerProfileManager = typeof(PlayerProfileManager)

return PlayerProfileManager
