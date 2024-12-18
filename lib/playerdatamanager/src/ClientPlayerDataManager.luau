-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ClientPlayerDataManager

    This class is used to provide a simple unified interface for accessing PlayerData. It requires
    registering what data it should expect and then you can access the data's managers once they have replicated.

    ```lua
    local PlayerDataManager = require(Packages.PlayerDataManager).Client

    PlayerDataManager:Start():await() -- wait for all managers to be ready

    local currencyManager = PlayerDataManager:GetManager("Currency")

    currencyManager:Observe("Robux", function(money)
        print("My premium currency is:", money)
    end)
    ```

    :::tip Usage with ROAM
    If you are using ROAM then you can set it up easily with the following format:
    ```lua
    local PlayerDataController = require(Packages.PlayerDataManager).Client

    
    function PlayerDataController:RoamInit()
        task.wait() -- optional frame delay to allow for other services to register if they need to
        local startProm = self:Start()
        startProm:await() -- yield roam to prevent Start until all managers are ready. This is optional, but makes it safer to access managers.
    end
    
    ---------------------------------------------------------------------
    
    local Roam = require(Packages.Roam)
    Roam.registerService(PlayerDataController, "PlayerDataController")

    return PlayerDataController
    ```
    :::
]=]

--// Services //--
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Janitor = require(Packages.Janitor)
local Promise = require(Packages.Promise)
local TableManager = require(Packages.TableManager)
local TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = {[any]: any}
type Promise = typeof(Promise.new(function() end))
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ClientTableReplicator
type TableReplicatorSingleton = TableReplicator.TableReplicatorSingleton

--// Constants //--
local LocalPlayer = Players.LocalPlayer

--// Volatiles //--
local Singletons = {}
local Replicators = {}

-- FLAGS
local DEBUG = true
local READY = false

--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local function debugPrint(...)
    if DEBUG then
        print("[DEBUG]", ...)
    end
end

local DEFAULT_CONDITION_FN = function(replicator: TableReplicator): boolean
    return tostring(replicator:GetTag("UserId")) == tostring(LocalPlayer.UserId)
end

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ClientPlayerDataManager = {}
ClientPlayerDataManager.ClassName = "ClientPlayerDataManager"
ClientPlayerDataManager.__index = ClientPlayerDataManager

--[=[
    @within ClientPlayerDataManager
    @prop DEFAULT_MANAGER_NAME string
    The default internal manager name.
]=]

--[=[
    @within ClientPlayerDataManager
    @prop PlayerDataReady Signal<Player>
    A signal that fires when a Player's data is ready to be used.
]=]
ClientPlayerDataManager.PlayerDataReady = Signal.new()

--[=[
    @within ClientPlayerDataManager
    @prop ManagerReady Signal<string, TableManager>
    A signal that fires when a manager is ready to be used.
]=]
ClientPlayerDataManager.ManagerReady = Signal.new()

--[=[
    Starts the auto-listening process for server registered managers. If you need custom behavior for fetching managers
    then you should use `RegisterManager` prior to calling this. Registering new managers after calling this method will
    result in unexpected behavior.
]=]
function ClientPlayerDataManager:Start()
    self._ServerManagersRegistered = Promise.new(function(resolve)
        local managersListFolder = script.Parent:WaitForChild("RegisteredServerManagers")

        local managerProms = {}

        for _, managerObj in managersListFolder:GetChildren() do
            local managerName = managerObj.Name
            
            local preregistered = Singletons[managerName]
            if preregistered then
                table.insert(managerProms, preregistered:PromiseTableManager():andThen(function(manager)
                    self.ManagerReady:Fire(managerName, manager)
                end))
                continue
            end

            local prom = TableReplicator.promiseFirstReplicator(function(replicator)
                return replicator:GetClassToken() == managerName and DEFAULT_CONDITION_FN(replicator)
            end):andThen(function(replicator)
                Replicators[managerName] = replicator
                self.ManagerReady:Fire(managerName, replicator:GetTableManager())
            end)

            table.insert(managerProms, prom)
        end

        Promise.all(managerProms):andThen(resolve)
    end)
    :andThen(function()
        READY = true
        self.PlayerDataReady:Fire()
    end)

    self.Start = function()
        warn("ClientPlayerDataManager has already been started.")
        return self._ServerManagersRegistered
    end

    return self._ServerManagersRegistered
end


--------------------------------------------------------------------------------
--// Fetcher Methods //--
--------------------------------------------------------------------------------

--[=[
    Gets the TableManager associated with the given name.
    ```lua
    cpdm:Start():await() -- wait for all managers to be ready
    
    local currencyManager = cpdm:GetManager("Currency")

    currencyManager:Observe("Robux", function(money)
        print("My premium currency is:", money)
    end)
    ```
    :::error Calling prior to data being ready
    This method will error if you attempt to call it before the ClientPlayerDataManager is ready.
    If you need to fetch a manager in a non-blocking way then you should use `PromiseManager`.
    :::
]=]
function ClientPlayerDataManager:GetManager(managerName: string?): TableManager
    assert(self:IsReady(), "Don't use GetManager before the data has replicated")
    local singleton = Singletons[managerName]
    if singleton then
        return singleton:GetTableManager()
    end
    local replicator = Replicators[managerName]
    return replicator:GetTableManager()
end

--[=[
    Promises the TableManager associated with the given name. If it doesnt exist when called then
    it will wait for it to be replicated and then will resolve.
    @return Promise<TableManager>
    ```lua
    ClientPlayerDataManager:PromiseManager("Currency")
    :andThen(function(manager: TableManager)
        manager:Observe("Robux", function(money)
            print("My premium currency is:", money)
        end)
    end)
    ```
]=]
function ClientPlayerDataManager:PromiseManager(managerName: string?): Promise
    local singleton = Singletons[managerName]
    if singleton then
        return singleton:PromiseTableManager()
    end
    local replicator = Replicators[managerName]
    if replicator then
        return replicator:GetTableManager()
    end
    return Promise.fromEvent(self.ManagerReady, function(name)
        return name == managerName
    end):andThen(function(name, manager)
        return manager
    end)
end

--[=[
    Checks if all the managers have replicated and are ready to be used.
]=]
function ClientPlayerDataManager:IsReady(): boolean
    return READY
end

--[=[
    Returns a promise that resolves when all player managers have been replicated.
]=]
function ClientPlayerDataManager:OnReady(): Promise
    if self:IsReady() then
        return Promise.resolve()
    end
    return Promise.fromEvent(self.PlayerDataReady)
end

--[=[
    `GetImmediate` returns a special manager, in the form of a `TableReplicatorSingleton`, that can be accessed
    prior to the data being replicated. In order to use this you must pre-registered it with `:RegisterManager()`.
    ```lua
    cpdm:RegisterManager("Currency", {
        Tickets = 100,
        Robux = 25
    })
    
    local immediateCurrencyManager = cpdm:GetImmediate("Currency")

    immediateCurrencyManager:Observe("Robux", function(money)
        print("My premium currency is:", money)
    end)
    ```
]=]
function ClientPlayerDataManager:GetImmediate(managerName: string?): TableReplicatorSingleton
    local s = Singletons[managerName]
    assert(s, `{managerName} is not a registered singleton.`)
    return s
end



export type ClientPlayerDataManager = typeof(ClientPlayerDataManager)

return ClientPlayerDataManager