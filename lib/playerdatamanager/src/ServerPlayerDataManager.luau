-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ServerPlayerDataManager

    The Server side class for the PlayerDataManager package
]=]


--// Imports //--
local Packages = script.Parent.Parent
local T = require(Packages.T)
local BaseObject = require(Packages.BaseObject)
local RailUtil = require(Packages.RailUtil)
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local Signal = require(Packages.Signal)
local TableManager = require(Packages.TableManager)
local TableReplicator = require(Packages.TableReplicator)
-- local PlayerProfileManager = require(Packages.PlayerProfileManager)

--// Types //--
type table = {[any]: any}
type Promise = typeof(Promise.new())
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ServerTableReplicator
type Profile = table --PlayerProfileManager.Profile
type PlayerProfileManager = table --PlayerProfileManager.PlayerProfileManager
type Connection = Signal.ScriptConnection

--// Constants //--
local DEFAULT_TIMEOUT = 60

local validateManagerConfig = T.interface({
    Name = T.string,
    Data = T.optional(T.callback),

    -- Custom Handling for the TableReplicator
    ReplicationTargets = T.optional(
        T.union(
            T.literal("All"),
            --T.literal("Others"), -- not yet supported
            T.literal("Self"),
            T.instanceIsA("Player"),
            T.array(T.instanceIsA("Player"))
        )
    ),
    Parent = T.optional(T.table),
    Tags = T.optional(T.table),
    Client = T.optional(T.table),
})

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ServerPlayerDataManager = setmetatable({}, BaseObject)
ServerPlayerDataManager.ClassName = "ServerPlayerDataManager"
ServerPlayerDataManager.__index = ServerPlayerDataManager
ServerPlayerDataManager.__call = function(t, ...) return t.new(...) end

--[=[
    @within ServerPlayerDataManager
    @prop DEFAULT_MANAGER_NAME string
    The default internal manager name.
]=]
ServerPlayerDataManager.DEFAULT_MANAGER_NAME = "Default"

--[=[
    @within ServerPlayerDataManager
    @prop PlayerDataReady Signal<Player>
    A signal that fires when a Player's data is ready to be used.
]=]

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Promise that resolves when the player's data is ready to be used.
]=]
function ServerPlayerDataManager:OnReady(player: Player): Promise
    if self:IsReady(player) then return Promise.resolve(self._PlayerData[player]) end
    return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
        return readiedPlayer == player
    end)
    :andThen(function()
        return self._PlayerData[player]
    end)
    :timeout(DEFAULT_TIMEOUT, `PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end

--[=[
    Checks whether or not a given player's data is ready
]=]
function ServerPlayerDataManager:IsReady(player: Player): boolean
    return self._PlayerData and self._PlayerData[player] ~= nil
end

--[[
    Fetches one of the given Player's DataManagers. If one is not specified then it will assume the default one. 
]]
function ServerPlayerDataManager:GetManager(player: Player, managerName: string?): TableManager?
    if not self:IsReady(player) then
        warn("Player data is not ready")
        return nil
    end
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    return self._PlayerData[player][managerName]:GetTableManager()
end
ServerPlayerDataManager.Get = ServerPlayerDataManager.GetManager
ServerPlayerDataManager.GetTableManager = ServerPlayerDataManager.GetManager

--[=[
    Promises a TableManager for a given player. If a managerName is not specified then it will assume the default one.
    ```lua
    ServerPlayerDataManager:PromiseManager(Players.Raildex, "Settings"):andThen(function(manager)
        manager:Set("Volume", 0.5)
    end)
    ```
]=]
function ServerPlayerDataManager:PromiseManager(player: Player, managerName: string?): Promise
    return self:OnReady(player):andThen(function()
        return self:GetManager(player, managerName)
    end)
end

--[[
    Runs a function for all existing loaded player data and all future player data.
    ```lua
    ServerPlayerDataManager:ForEach(function(player)
        local defaultManager = ServerPlayerDataManager:GetManager(player)
        defaultManager:Set("Volume", 0.5)
    end)
    ```
]]
function ServerPlayerDataManager:ForEach(fn: (player: Player, data: any) -> ()): Connection
    for player, data in pairs(self._PlayerData) do
        task.spawn(fn, player, data)
    end
    return self.PlayerDataReady:Connect(function(player: Player)
        fn(player, self._PlayerData[player])
    end)
end

--[=[
    Returns the TableReplicator for a given player. If a replicatorName is not specified then it will assume the default one.
    ```lua
    local replicator = ServerPlayerDataManager:GetReplicator(Players.Raildex, "Settings")
    ```
]=]
function ServerPlayerDataManager:GetReplicator(player: Player, replicatorName: string?): TableReplicator?
    if not self:IsReady(player) then
        warn("Failed to get {player.Name}'s TableReplicator. Their player data is not read.y")
        return nil
    end
    replicatorName = replicatorName or self.DEFAULT_MANAGER_NAME
    return self._PlayerData[player][replicatorName]
    
end

--[=[
    Registers a config table for new managers to use for construction.

    :::caution Modifying the given table
    DO NOT MODIFY THE TABLE AFTER PASSING IT. Treat it as frozen. Doing so can cause potential
    desyncs between players.
    :::
]=]
function ServerPlayerDataManager:RegisterManager(config: {
    Name: string,
    GetData: (player: Player, profile: Profile) -> table,
} | string)
    if type(config) == "string" then
        config = {Name = config} :: any
    end

    assert(validateManagerConfig(config))
    assert(typeof(config) == "table", "Expected a table for the config argument.")

    local name = config.Name
    assert(not self._STARTED, "Cannot register data containers after the service has started.")
    assert(not self._ManagerTemplates[name], "Manager already exists with name: " .. config.Name)
    self._ManagerTemplates[name] = config
    self:FireSignal("ManagerRegistered", name, config)
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

-- Cache and fetch the class token for a given name
local ReplicatorClassTokens = {}
function ServerPlayerDataManager:_UpsertToken(name: string)
    if not ReplicatorClassTokens[name] then
        ReplicatorClassTokens[name] = TableReplicator.newClassToken(name)
    end
    return ReplicatorClassTokens[name]
end

-- Simple utility function for debugging
function ServerPlayerDataManager:_debugPrint(...)
    if self._DEBUG then
        print("[DEBUG]", ...)
    end
end


function ServerPlayerDataManager:_SetupPlayerDataManagers(player: Player, profile: Profile)
    self:_debugPrint("Setting up player data managers for", player)

    local jani = Janitor.new()
    local DataContainer = {}

    for name, config in pairs(self._ManagerTemplates) do
        assert(validateManagerConfig(config))

        local getData = config.GetData or function(player, profile)
            local d = profile.Data[name]
            if not d then
                warn(`[Default Data Getter] Could not find index '{name}' in {player.Name}'s profile data. Returning an empty table.`)
                d = {}
            end-- default GetData fn
            return d
        end
        local data = getData(player, profile)
        assert(typeof(data) == "table", "The Data function must return a table.")

        -- reconcile the replication targets
        local rTargets = config.ReplicationTargets
        if rTargets and string.lower(rTargets) == "self" then
            rTargets = player
        elseif not config.Parent and not rTargets then
            rTargets = player
        end
        
        local tm = TableManager.new(data)
        local tr = TableReplicator.new({
            ClassToken = self:_UpsertToken(name);
            TableManager = tm;
            ReplicationTargets = rTargets;
            Parent = config.Parent;
            Client = config.Client;
            Tags = RailUtil.Table.Reconcile(config.Tags or {}, {UserId = player.UserId});
        });

        jani:Add(tm)
        jani:Add(tr)

        DataContainer[name] = tr
    end

    return DataContainer, jani
end

--[=[
    Starts the service and sets up all the Player's data managers.
    ```lua
    local PlayerDataManager = PlayerDataManager.Server.new()
    
    local PPM = PlayerProfileManager.new()
    PlayerDataManager:Start(PPM)
    ```
]=]
function ServerPlayerDataManager:Start(ppm: PlayerProfileManager?)
    -- Final chance to set the PlayerProfileManager
    self.PlayerProfileManager = ppm or self.PlayerProfileManager
    assert(self.PlayerProfileManager, "PlayerProfileManager is not set. Please set it before calling Start.")
    assert(self.PlayerProfileManager.ClassName == "PlayerProfileManager", "PlayerProfileManager is not a valid PlayerProfileManager instance.")

    -- Initialize the default manager if it doesn't exist
    if not self._ManagerTemplates[self.DEFAULT_MANAGER_NAME] then
        self:_debugPrint("Default Manager not registered. Registering Default Manager.")

        self:RegisterManager({
            Name = self.DEFAULT_MANAGER_NAME,
            Data = function(player: Player, profile: Profile)
                return profile.Data[self.DEFAULT_MANAGER_NAME]
            end
        })
    else
        self:_debugPrint("Default Manager already registered.")
    end

    -- Mark the service as started so no more managers can be registered
    self._STARTED = true

    --------------------------------------------------------------------------------
    -- Grab the profile for each Player and setup their managers
    local function Setup(plr: Player, profile: Profile, jani: Janitor)
        local dataContainer, cleanup = self:_SetupPlayerDataManagers(plr, profile)
        self._PlayerData[plr] = dataContainer

        jani:Add(cleanup)
        jani:Add(function()
            self._PlayerData[plr] = nil
        end)

        self.PlayerDataReady:Fire(plr)

        self:_debugPrint(`{plr.Name}'s PlayerData is now ready.`)
    end

    self:AddTask(RailUtil.Player.forEachPlayer(function(plr: Player, jani: Janitor)
        jani:AddPromise(self.PlayerProfileManager:PromiseProfile(plr):andThen(function(profile: Profile)
            Setup(plr, profile, jani)
        end))
    end))
   
    --------------------------------------------------------------------------------
    -- Override the Start method so that it can only be called once
    self.Start = function()
        warn("ServerPlayerDataManager has already started. Do not call Start multiple times.")
    end
    -- Lock the service from further manipulation
    table.freeze(self)
end

--[=[
    @tag Constructor
    @tag Singleton
    @tag Static
    @return ServerPlayerDataManager
    Constructs a new ServerPlayerDataManager instance.
    ```lua
    local PPM = PlayerProfileManager.new()
    local PlayerDataManager = PlayerDataManager.Server.new(PPM)
    ```
    :::warning PlayerProfileManager
    The ServerPlayerDataManager requires a PlayerProfileManager instance in order to properly function.
    You must provide a PlayerProfileManager instance before you call the `:Start` method. Optimally you
    should provide it during the constructor phase.
    :::
]=]
function ServerPlayerDataManager.new(ppm: PlayerProfileManager?): ServerPlayerDataManager
    local self = setmetatable(BaseObject.new(), ServerPlayerDataManager)
    
    -- Internal Data
    self._PlayerData = {}
    self._ManagerTemplates = {}
    self.PlayerProfileManager = ppm

    -- FLAGS
    self._DEBUG = true
    self._STARTED = false

    -- Server Signals
    self:RegisterSignal("ManagerRegistered")
    self:RegisterSignal("PlayerDataReady")
    self.PlayerDataReady = self:GetSignal("PlayerDataReady")

    -- Overwrite this method so that it can only be called once
    self.new = function()
        warn("ServerPlayerDataManager is a singleton and should not be instantiated multiple times.")
        return self
    end

    return self
end

export type ServerPlayerDataManager = typeof(ServerPlayerDataManager.new())

return ServerPlayerDataManager