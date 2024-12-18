-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ServerPlayerDataManager

    The Server side class for the PlayerDataManager package

    :::tip Usage with ROAM
    If you are using ROAM then you can set it up easily with the following format:
    ```lua
    local PlayerDataService = require(Packages.PlayerDataManager).Server
    local PlayerProfileManager = require(ServerPackages.PlayerProfileManager)

    local PlayerDataTemplate = { -- Some example data schema
        [PlayerDataService.DEFAULT_MANAGER_NAME] = {};

        Settings = {
            Volume = 0.5;
        };

        Currency = {
            Tickets = 100;
            Robux = 25;
        };
    };

    ---------------------------------------------------------------------

    function PlayerDataService:RegisterGenericManager(managerName: string)
        self:RegisterManager(managerName, function(player, profile)
            return {
                Data = profile.Data[managerName];
                ReplicationTargets = player;
            }
        end)
    end

    -- Private method to organize where we register all the managers
    function PlayerDataService:_RegisterManagers()
        self:RegisterGenericManager("Settings")
        self:RegisterGenericManager("Currency")
    end

    ---------------------------------------------------------------------
    
    function PlayerDataService:RoamInit()
        self.PlayerProfileManager = PlayerProfileManager.new({
            DataStoreKey = "PlayerProfileData";
            DefaultDataSchema = PlayerDataTemplate;
        })
    end

    function PlayerDataService:RoamStart()
        self:_RegisterManagers()
        self:Start(self.PlayerProfileManager)
    end
    
    ---------------------------------------------------------------------
    
    local Roam = require(Packages.Roam)
    Roam.registerService(PlayerDataService, "PlayerDataService")

    return PlayerDataService
    ```
    :::
]=]


--// Imports //--
local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Janitor = require(Packages.Janitor)
local Promise = require(Packages.Promise)
local RailUtil = require(Packages.RailUtil)
local TableManager = require(Packages.TableManager)
local TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = {[any]: any}
type Promise = typeof(Promise.new(function() end))
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ServerTableReplicator
type Profile = table --PlayerProfileManager.Profile
type PlayerProfileManager = table --PlayerProfileManager.PlayerProfileManager

--// Constants //--
local DEFAULT_TIMEOUT = 60

--// Volatiles //--
local STARTED = false
local PlayerData = {}
local ManagerTemplates = {}

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ServerPlayerDataManager = {}
ServerPlayerDataManager.ClassName = "ServerPlayerDataManager"
ServerPlayerDataManager.__index = ServerPlayerDataManager

--[=[
    @private
    @within ServerPlayerDataManager
    @prop _DEBUG boolean
    Whether or not to print debug messages.
]=]
ServerPlayerDataManager._DEBUG = false

--[=[
    @within ServerPlayerDataManager
    @prop DEFAULT_MANAGER_NAME string
    The default internal manager name.
]=]

--[=[
    @within ServerPlayerDataManager
    @prop ManagerReady Signal<Player, string, TableManager>
    A signal that fires when a manager is ready for a Player.
]=]
ServerPlayerDataManager.ManagerReady = Signal.new()

--[=[
    @within ServerPlayerDataManager
    @prop ManagerRegistered Signal<string>
    A signal that fires when a new manager is registered.
]=]
ServerPlayerDataManager.ManagerRegistered = Signal.new()

--[=[
    @within ServerPlayerDataManager
    @prop PlayerDataReady Signal<Player>
    A signal that fires when a Player's data is ready to be used.
]=]
ServerPlayerDataManager.PlayerDataReady = Signal.new()

--------------------------------------------------------------------------------

local function debugPrint(...)
    if ServerPlayerDataManager._DEBUG then
        print("[DEBUG]", ...)
    end
end

-- Cache and fetch the class token for a given name
local ReplicatorClassTokens = {}
local function upsertToken(name: string)
    if not ReplicatorClassTokens[name] then
        ReplicatorClassTokens[name] = TableReplicator.newClassToken(name)
    end
    return ReplicatorClassTokens[name]
end


local function setupPlayerDataManagers(player: Player, profile: Profile)
    debugPrint("Setting up player data managers for", player)

    local jani = Janitor.new()
    local Replicators = {}
    PlayerData[player] = {
        Replicators = Replicators,
        AllManagersReady = false,
    }

    local managerReadyPromises = {}

    for name, data in ManagerTemplates do
        local generateConfig = data.ConfigGenerator
        table.insert(managerReadyPromises, jani:AddPromise(Promise.new(function(resolve)
            local config = generateConfig(player, profile)
            assert(typeof(config.Data) == "table", "The Data function must return a table.")
    
            -- reconcile the replication targets
            local rTargets = config.ReplicationTargets
            if typeof(rTargets) == "string" and string.lower(rTargets) == "self" then
                rTargets = player
            elseif not config.Parent and not rTargets then
                warn(`ReplicationTargets is not set for {name} manager. Defaulting to '{player.Name}'. To ensure 'nil' replication targets, set ReplicationTargets to 'None'.`)
                rTargets = player
            elseif typeof(rTargets) == "string" and string.lower(rTargets) == "None" then
                rTargets = nil
            end
            
            local tm = TableManager.new(config.Data)
            local tr = TableReplicator.new({
                ClassToken = upsertToken(name);
                TableManager = tm;
                ReplicationTargets = rTargets;
                Parent = config.Parent;
                Client = config.Client;
                Tags = RailUtil.Table.Reconcile(config.Tags or {}, {UserId = player.UserId});
            });
    
            jani:Add(tm)
            jani:Add(tr)
    
            Replicators[name] = tr
            ServerPlayerDataManager.ManagerReady:Fire(player, name, tm)
            resolve(tm)
        end)))
    end

    return managerReadyPromises, jani
end

--------------------------------------------------------------------------------
--// Start Method //--
--------------------------------------------------------------------------------

--[=[
    Starts the service and sets up all the Player's data managers.
    ```lua
    local PlayerDataManager = require(Packages.PlayerDataManager).Server
    
    local PPM = PlayerProfileManager.new(yourProfileConfig)
    PlayerDataManager:Start(PPM)
    ```
]=]
function ServerPlayerDataManager:Start(ppm: PlayerProfileManager)
    assert(ppm, "PlayerProfileManager is not set. Please set it before calling Start.")
    assert(ppm.ClassName == "PlayerProfileManager", "PlayerProfileManager is not a valid PlayerProfileManager instance.")

    -- Initialize the default manager if it doesn't exist
    if not ManagerTemplates[self.DEFAULT_MANAGER_NAME] then
        if not ppm._config.DefaultDataSchema[self.DEFAULT_MANAGER_NAME] then
            error(`No table at index '{self.DEFAULT_MANAGER_NAME}' found in the DefaultDataSchema.`)
        end
        debugPrint("Default Manager not registered. Registering Default Manager.")

        self:RegisterManager(self.DEFAULT_MANAGER_NAME, function(player: Player, profile: Profile)
            return {
                Data = profile.Data[self.DEFAULT_MANAGER_NAME],
                ReplicationTargets = player,
            }
        end)
    else
        debugPrint("Default Manager already registered.")
    end
    
    -- Mark the service as started so no more managers can be registered
    STARTED = true

    -- Override the Start method so that it can only be called once
    self.Start = function()
        warn("ServerPlayerDataManager has already started. Do not call Start multiple times.")
    end

    --------------------------------------------------------------------------------
    -- Grab the profile for each Player and setup their managers
    local function Setup(plr: Player, profile: Profile, jani: Janitor)
        local readyPromises, cleanup = setupPlayerDataManagers(plr, profile)
        
        jani:Add(cleanup)
        jani:Add(function()
            PlayerData[plr] = nil
        end)
        
        Promise.all(readyPromises):andThen(function()
            PlayerData[plr].AllManagersReady = true
            self.PlayerDataReady:Fire(plr)
            debugPrint(`{plr.Name}'s PlayerData is now ready.`)
        end)
    end

    RailUtil.Player.forEachPlayer(function(plr: Player, jani: Janitor)
        jani:AddPromise(ppm:PromiseProfile(plr):andThen(function(profile: Profile)
            Setup(plr, profile, jani)
        end))
    end)
   
    --------------------------------------------------------------------------------

    -- Setup a list
    local ManagersListFolder = Instance.new("Folder")
    ManagersListFolder.Name = "RegisteredServerManagers"
    for name in ManagerTemplates do
        local manager = Instance.new("BoolValue")
        manager.Name = name
        manager.Parent = ManagersListFolder
    end
    ManagersListFolder.Parent = script.Parent
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Registers a manager config generator for new managers to use during construction.

    ```lua
    SPDM:RegisterManager("Settings", function(player, profile)
        return {
            Data = profile.Data.Settings;
            ReplicationTargets = player;
            Tags = {UserId = player.UserId};
        }
    end)
    ```

    :::note UserId tag
    All managers are automatically reconciled with the UserId tag being set to the Player's UserId. `{UserId = player.UserId}`.
    Don't modify this tag unless you know what you're doing as it can break autosetup features.
    :::

    :::warning Modifying the given table
    Do not modify a table after passing it. Treat it as frozen. Doing so can cause potential
    desyncs between players.
    :::

    :::warning Registering after Start
    You are not allowed to register managers after the service has started. Doing so will result in an error.
    :::
]=]
function ServerPlayerDataManager:RegisterManager(managerName: string, configGenerator: (player: Player, profile: Profile) -> {
    Data: table,
    ReplicationTargets: ("All" | "None" | Player | {Player}),
    Tags: table?,
    Parent: table?,
    Client: table?,
})
    assert(not STARTED, "Cannot register data containers after the service has started.")
    assert(not ManagerTemplates[managerName], "Manager already exists with name: " .. managerName)
    ManagerTemplates[managerName] = {
        ConfigGenerator = configGenerator,
    }
    self.ManagerRegistered:Fire(managerName)
end

--[=[
    Fetches one of the given Player's DataManagers. If one is not specified then it will assume the default one.
    Will return nil if the player's data is not ready or the manager does not exist.
    ```lua
    local defaultManager = SPDM:GetManager(Players.Raildex)
    assert(defaultManager, "Player data is not ready yet.")
    defaultManager:Set("Volume", 0.5)
    ```
]=]
function ServerPlayerDataManager:GetManager(player: Player, managerName: string?): TableManager?
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    if not PlayerData[player] then
        warn(`Failed to get {player.Name}'s TableManager '{managerName}'. Their player data has not yet begun initializing!`)
        return nil
    end

    local Replicator = PlayerData[player].Replicators[managerName]
    if not Replicator then
        if not self:IsReady(player) then
            warn(`Failed to get {player.Name}'s TableManager '{managerName}'. Their player data is in the process of readying.`)
        else
            warn(`Failed to get {player.Name}'s TableManager '{managerName}'. The manager does not exist. Check to ensure it was registered properly. Current Managers: `, RailUtil.Table.Keys(self._ManagerTemplates))
        end
        return nil
    end

    return Replicator:GetTableManager()
end
ServerPlayerDataManager.Get = ServerPlayerDataManager.GetManager
ServerPlayerDataManager.GetTableManager = ServerPlayerDataManager.GetManager

--[=[
    Promises a TableManager for a given player. If a managerName is not specified then it will assume the default one.
    ```lua
    SPDM:PromiseManager(Players.Raildex, "Settings"):andThen(function(manager)
        manager:Set("Volume", 0.5)
    end)
    ```
]=]
function ServerPlayerDataManager:PromiseManager(player: Player, managerName: string?): Promise
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    if PlayerData[player] and PlayerData[player].Replicators[managerName] then
        return Promise.resolve(PlayerData[player].Replicators[managerName]:GetTableManager())
    end

    return Promise.fromEvent(self.ManagerReady, function(readiedPlayer: Player, readiedManager: string)
        return readiedPlayer == player and readiedManager == managerName
    end)
    :andThen(function()
        return self:GetManager(player, managerName)
    end)
end


--[=[
    Returns the TableReplicator associated with a Player's Manager. If a manager name is not specified then it will assume the default one.
    ```lua
    local replicator = SPDM:GetReplicator(Players.Raildex, "Settings")
    ```
]=]
function ServerPlayerDataManager:GetReplicator(player: Player, managerName: string?): TableReplicator?
    if not self:IsReady(player) then
        warn("Failed to get {player.Name}'s TableReplicator. Their player data is not ready.")
        return nil
    end
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    return PlayerData[player][managerName]
end

--[=[
    Checks whether or not a given manager is registered. If one is not specified then it will assume the default one.
]=]
function ServerPlayerDataManager:IsManagerRegistered(managerName: string?): boolean
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    return ManagerTemplates[managerName] ~= nil
end

--[=[
    Checks whether or not a given player's manager is ready. If one is not specified then it will assume the default one.
    ```lua
    if SPDM:IsManagerReady(Players.Raildex, "Settings") then
        local settings = SPDM:GetManager(Players.Raildex, "Settings")
    end
    ```
]=]
function ServerPlayerDataManager:IsManagerReady(player: Player, managerName: string?): boolean
    managerName = managerName or self.DEFAULT_MANAGER_NAME
    return PlayerData[player] and PlayerData[player].Replicators[managerName] ~= nil
end

--[=[
    Checks whether or not a given player's data is ready
]=]
function ServerPlayerDataManager:IsReady(player: Player): boolean
    return PlayerData[player] ~= nil and PlayerData[player].AllManagersReady
end

--[=[
    Promise that resolves when the player's data is ready to be used.
]=]
function ServerPlayerDataManager:OnReady(player: Player): Promise
    if self:IsReady(player) then return Promise.resolve() end
    return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
        return readiedPlayer == player
    end)
    :timeout(DEFAULT_TIMEOUT, `PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end


--[=[
    Runs a function for all existing loaded player data and all future player data.
    @return () -> () -- A function that when called will disconnect the listener and cancel any running threads.
    ```lua
    SPDM:ForEachPlayer(function(player)
        local defaultManager = SPDM:GetManager(player)
        defaultManager:Set("Volume", 0.5)
    end)
    ```
]=]
function ServerPlayerDataManager:ForEachPlayer(fn: (player: Player, data: any) -> ()): () -> ()
    local janitor = Janitor.new()

    for player, data in PlayerData do
        janitor:Add(task.spawn(fn, player, data))
    end

    janitor:Add(self.PlayerDataReady:Connect(function(player: Player)
        janitor:Add(task.spawn(fn, player, PlayerData[player]))
    end))

    return function()
        janitor:Destroy()
    end
end
ServerPlayerDataManager.ForEach = ServerPlayerDataManager.ForEachPlayer


export type ServerPlayerDataManager = typeof(ServerPlayerDataManager)

return ServerPlayerDataManager