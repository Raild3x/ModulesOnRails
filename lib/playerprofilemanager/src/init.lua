-- Authors: Logan Hunt (Raildex)
-- January 22, 2024
--[=[
    @class PlayerProfileManager
    @server

    This class is responsible for managing player profiles. It is a singleton class, so calling
    `PlayerProfileManager.new` multiple times will return the same instance. It is recommended to
    create a `PlayerDataService` to manage this class.
    
]=]

--// Services //--
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent
local ProfileTypeDef = require(script.ProfileTypeDef)
local T = require(Packages.T)
local ProfileService = require(Packages.ProfileService)
local RailUtil = require(Packages.RailUtil)
local Promise = require(Packages.Promise)
local BaseObject = require(Packages.BaseObject)
local SuperClass = BaseObject

type table = {[any]: any}
type Promise = typeof(Promise.new())
export type Profile = ProfileTypeDef.Profile

--[=[
    @interface DataMigrator
    @within PlayerProfileManager
    .FromVersion string
    .ToVersion string
    .Migrate (profileData: table, profileOwner: Player) -> (table)
]=]
type DataVersion = string | number
export type DataMigrator = {
    FromVersion: DataVersion,
    ToVersion: DataVersion,
    Migrate: (profileData: table, profileOwner: Player) -> (table)
}


local ConfigType = {
    DataStoreKey = T.string :: string,
    DefaultDataSchema = T.table :: {[string]: any},
    UseMock = T.optional(T.boolean) :: boolean?,
    Migrator = T.optional(T.array(T.table)) :: {DataMigrator}?,
    GetPlayerKeyCallback = T.optional(T.callback) :: ((userId: number) -> string)?,
    ReconcileCallback = T.optional(T.callback) :: ((Player, Profile) -> ())?,
    OnProfileLoadFailure = T.optional(T.callback) :: ((Player, string) -> ())?,

    Debug = T.optional(T.boolean) :: boolean?
}
local ConfigInterface = T.interface(ConfigType)

--[=[
    @within PlayerProfileManager
    @interface PPM_Config
    .DataStoreKey string
    .DefaultDataSchema table
    .UseMock boolean?
    .Migrator {DataMigrator}
    .GetPlayerKeyCallback ((player: Player) -> (string))?
    .ReconcileCallback ((player: Player, profile: Profile) -> ())?
    .OnProfileLoadFailure ((player: Player, err: string) -> ())?

    - **OnProfileLoadFailure** will default to kicking the player if not provided.
    - **ReconcileCallback** will default to calling Profile:Reconcile if not provided.
]=]
export type PPM_Config = typeof(ConfigType)

local RETRY_PROFILE_LOAD_DELAY = 3
local RETRY_PROFILE_LOAD_ATTEMPTS = 5

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local SINGLETON

local PlayerProfileManager = setmetatable({}, SuperClass)
PlayerProfileManager.ClassName = "PlayerProfileManager"
PlayerProfileManager.__index = PlayerProfileManager

--[=[
    Creates a new PlayerProfileManager. This is a singleton class, so calling this function multiple
    times will return the same instance. Takes a config table with the following fields.

    ```lua
    PlayerProfileManager.new({
        DataStoreKey = "PlayerData";
        DefaultDataSchema = {
            __VERSION = "0.0.0";
            Currency = 0;
        };
    })
    ```
]=]
function PlayerProfileManager.new(config: PPM_Config): PlayerProfileManager
    if SINGLETON then return SINGLETON end
    assert(ConfigInterface(config))
    local self = setmetatable(SuperClass.new(), PlayerProfileManager)
    SINGLETON = self


    self:RegisterSignal("PlayerProfileLoadFailure")
    self:RegisterSignal("PlayerProfileLoadSuccess")
    self:RegisterSignal("PlayerProfileReleasing")

    self._PlayerProfileStorage = {} :: {[Player]: Profile}

    self._config = config
    self._isMock = config.UseMock or false

    self._reconcileCallback = config.ReconcileCallback or function(_: Player, profile)
        profile:Reconcile()
    end
    self._loadFailureCallback = config.OnProfileLoadFailure or function(player: Player, err: string)
        player:Kick("Something went wrong and we failed to load your player data. Please rejoin the game. If this issue persists, please contact the developer.\n"..tostring(err))
    end

    -- create player profile provider
    self._profileStore = ProfileService.GetProfileStore(
        config.DataStoreKey,
        config.DefaultDataSchema
    )

    if self._isMock then
        self._profileStore = self._profileStore.Mock
    end

    ---------------------------------------------------------------------------

    self:AddTask(RailUtil.Player.forEachPlayer(function(player, janitor)
        janitor:AddPromise(self:_createPlayerData(player))
    end))

    return self
end

--[=[
    @private
]=]
function PlayerProfileManager:_reconcileProfile(player: Player, profile: Profile)
    if self._config.Debug then
        print(`[👤] Reconciling {player.Name}'s profile.`)
    end
    self._reconcileCallback(player, profile)
end

--[=[
	@private

	Looks up a migrator function for a specific version
]=]
function PlayerProfileManager:_lookupMigrator(fromVersion: number): DataMigrator?
    local migrator
	for _, migration in ipairs(self._config.Migrator) do
		if migration.FromVersion == fromVersion then
            if migrator then
                error("[👤] Multiple migrators found for version " .. fromVersion)
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

    local VERSION_KEY = "__VERSION"
    -- handle migrations
    while profile.Data[VERSION_KEY] and profile.Data[VERSION_KEY] ~= self._config.DefaultDataSchema[VERSION_KEY] do
        local currentVersion = profile.Data[VERSION_KEY]

        local migrator = self:_lookupMigrator(currentVersion)

        if migrator then
            local nextVersion = migrator.ToVersion

            if self._config.Debug then
                print(`[👤] Migrating {player.Name}'s data from {currentVersion} to {nextVersion}`)
            end

            local newData
            local ok, err = pcall(function()
                newData = migrator.Migrate(profile.Data, player)

                local MigratorName = currentVersion .. " -> " .. nextVersion
                if not newData then
                    warn(`[👤] Migrator[{MigratorName}] did not return new data, assuming same table. Have your migrator return a table to silence this warning.`)
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
    Generates a key for the player based on the GetPlayerKeyCallback if it exists.
]=]
function PlayerProfileManager:_generatePlayerKey(playerOrUserId: Player | number | string): string
    if type(playerOrUserId) ~= "number" or type(playerOrUserId) ~= "string" then
        assert(typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player"), "Invalid argument #1 to _generatePlayerKey")
        playerOrUserId = playerOrUserId.UserId
    end
    return if self._config.GetPlayerKeyCallback then self._config.GetPlayerKeyCallback(playerOrUserId) else `Player_{playerOrUserId}`
end

--[=[
    @private
    Attempts to load the profile for the given player asyncronously.
]=]
function PlayerProfileManager:_attemptLoadProfile(player: Player): Promise
    return Promise.new(function(resolve, reject)
        local playerKey = self:_generatePlayerKey(player)
        
        -- load profile
        local profile = self._profileStore:LoadProfileAsync(playerKey)
        if profile ~= nil then
            profile:AddUserId(player.UserId) -- GDPR compliance

            -- The profile could've been loaded on another Roblox server:
            profile:ListenToRelease(function()
                player:Kick("Your player data profile was released while you were playing. Please rejoin the game.")
                return reject("Player joined another Roblox server while profile was loading!")
            end)

            -- if player left while profile was loading
            if not player:IsDescendantOf(Players) then
                profile:Release()
                return reject("Player left while profile was loading!")
            end

            self:_migrateProfileData(player, profile)
            self:_reconcileProfile(player, profile)

            -- successfully loaded
            return resolve(profile)
        else
            return reject("Profile failed to load for " .. player.Name)
        end
    end)
end

--[=[
    @private
]=]
function PlayerProfileManager:_createPlayerData(player: Player): Promise
    if self._config.Debug then
        print(`[👤] Loading Profile for {player.Name}.`)
    end

    return Promise.retryWithDelay(function()
        local prom = self:_attemptLoadProfile(player)
        prom:catch(function(err)
            warn("[👤] Failed to load profile for " .. player.Name,"|", err)
            warn(`[👤] Retrying in {RETRY_PROFILE_LOAD_DELAY} seconds...`)
        end)
        return prom
    end, RETRY_PROFILE_LOAD_ATTEMPTS, RETRY_PROFILE_LOAD_DELAY)
    :andThen(function(profile)
        self._PlayerProfileStorage[player] = profile

        profile:ListenToRelease(function()
            if self._config.Debug then
                print(`[👤] {player.Name}'s profile was released.`)
            end
            self._PlayerProfileStorage[player] = nil
        end)

        Promise.fromEvent(Players.PlayerRemoving, function(removingPlayer)
            return removingPlayer == player
        end):andThen(function()
            self:FireSignal("PlayerProfileReleasing", player, profile)
            profile:Release()
            if self._isMock then
                self._profileStore:WipeProfileAsync(self:_generatePlayerKey(player))
            end
        end)
    end)
    :andThen(function()
        if self._config.Debug then
			print(`[👤] Loaded profile for`, player)
		end

        self:FireSignal("PlayerProfileLoadSuccess", player)
    end)
    :catch(function(err)
        self:FireSignal("PlayerProfileLoadFailure", player, err)

        -- Currently the default behavior is to kick the player if their profile fails to load. In the future, we may want to
        -- give the player default data, alert them of that default data and that something went wrong, mark the data as "temporary"
        -- and ensure that it doesn't get saved when the player leaves.
        self._loadFailureCallback(player, err)
    end)
end

--[=[
    @private
    Generates a promise that will reject when the player leaves or the profile fails to load.
]=]
function PlayerProfileManager:_PromisePlayerLoadEventFailure(player: Player): Promise
    return Promise.fromEvent(self:GetSignal("PlayerProfileLoadFailure"), function(loadedPlayer: Player)
        return loadedPlayer == player
    end):andThen(function()
        return Promise.reject("Failed to load profile for " .. player.Name)
    end);
end

--[=[
    @private
    Generates a promise that will resolve when the player's profile is loaded.
]=]
function PlayerProfileManager:_PromisePlayerLoadEventSuccess(player: Player): Promise
    if self:IsLoaded(player) then return Promise.resolve() end
    return Promise.fromEvent(self:GetSignal("PlayerProfileLoadSuccess"), function(loadedPlayer: Player)
        return loadedPlayer == player
    end)
end


--[=[
    Returns whether or not the player's profile is currently loaded.

    ```lua
    local isLoaded = PlayerProfileManager:IsLoaded(player)
    ```

    @param player Player
    @return boolean
]=]
function PlayerProfileManager:IsLoaded(player: Player): boolean
    return self._PlayerProfileStorage[player] ~= nil
end

--[=[
    Returns a promise that will resolve when the player's profile is loaded.
    Rejects if the player leaves or the profile fails to load.

    ```lua
    PlayerProfileManager:OnLoaded(player):andThen(function()
        print("Profile loaded for " .. player.Name)
    end)
    ```

    @param player Player
    @return Promise<()>
]=]
function PlayerProfileManager:OnLoaded(player: Player): Promise
    return Promise.race({
        self:_PromisePlayerLoadEventFailure(player);
        self:_PromisePlayerLoadEventSuccess(player);
    })
end

--------------------------------------------------------------------------------
    --// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    @private
    @unreleased
    THIS METHOD IS UNFINISHED AND CURRENTLY CAUSES ERRORS.
    Wipes the player's profile from the data store.
    Use this in cases where you need to reset a player's data or
    comply with a right to erasure request.
]=]
function PlayerProfileManager:WipeProfile(userId: number): Promise
    warn("Attempting profile wipe for Player_" .. userId)
    return Promise.new(function(resolve, reject)
        local player = Players:GetPlayerByUserId(userId)
        if player then
            local success = self:PromiseProfile(player):andThen(function(profile)
                self:FireSignal("PlayerProfileReleasing", player, profile)
                profile:Release()
            end):await()

            if not success then
                return reject("Failed to wipe profile for Player_" .. userId)
            end
        end
        
        local success = self._profileStore:WipeProfileAsync(self:_generatePlayerKey(player))
        if success then
            warn("Profile successfully wiped for Player_" .. userId)
            return resolve()
        else
            return reject("Failed to wipe profile for Player_" .. userId)
        end
    end)
end


--[=[
    Returns the player's profile, if it exists. May return nil if this players profile is not loaded.

    ```lua
    local profile: Profile? = PlayerProfileManager:GetProfile(player)
    ```

    @param player Player
    @return Profile?
]=]
function PlayerProfileManager:GetProfile(player: Player): Profile?
    assert(getmetatable(self) == PlayerProfileManager, "Must call using the Singleton instance.")
    return self._PlayerProfileStorage[player]
end

--[=[
    Returns a promise that resolves with the player's profile when it is ready.
    Rejects if the player leaves or the profile fails to load.

    ```lua
    PlayerProfileManager:PromiseProfile(player):andThen(function(profile: Profile)
        print("Profile loaded for " .. player.Name)
    end)
    ```

    @param player Player
    @return Promise<Profile>
]=]
function PlayerProfileManager:PromiseProfile(player: Player): Promise
    assert(getmetatable(self) == PlayerProfileManager, "Must call using the Singleton instance.")
    return self:OnLoaded(player):andThen(function()
        return self:GetProfile(player)
    end)
end


export type PlayerProfileManager = typeof(PlayerProfileManager)

return PlayerProfileManager