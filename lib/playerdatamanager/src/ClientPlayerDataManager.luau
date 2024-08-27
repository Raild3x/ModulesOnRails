-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ClientPlayerDataManager

    This class is used to provide a simple unified interface for accessing PlayerData. It requires
    registering what data it should expect and then you can access the data's managers once they have replicated.

    ```lua
    -- this should usually be gotten from a shared module between the server and client
    local ProfileTemplate = {
        Currency = {
            Money = 0,
            Gems = 100,
        }
    }
    
    local cpdm = ClientPlayerDataManager.new({
        ProfileSchema = ProfileTemplate
    })

    cpdm:RegisterManager("Currency")

    cpdm:PromiseManager("Currency"):andThen(function(tm: TableManager)

        tm:Observe("Money", function(money)
            print("My money is:", money)
        end)

    end)
    ```
]=]

--// Services //--
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent
local BaseObject = require(Packages.BaseObject)
local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)
local RailUtil = require(Packages.RailUtil)
local Janitor = require(Packages.Janitor)
local TableManager = require(Packages.TableManager)
local TableReplicator = require(Packages.TableReplicator)
local T = require(Packages.T)

--// Types //--
type table = {[any]: any}
type Promise = typeof(Promise.new())
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ClientTableReplicator
type TableReplicatorSingleton = TableReplicator.TableReplicatorSingleton

--// Constants //--
local LocalPlayer = Players.LocalPlayer

local DEFAULT_CONDITION_FN = function(replicator: TableReplicator): boolean
    return replicator:GetTag("UserId") == LocalPlayer.UserId
end

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ClientPlayerDataManager = setmetatable({}, BaseObject)
ClientPlayerDataManager.ClassName = "ClientPlayerDataManager"
ClientPlayerDataManager.__index = ClientPlayerDataManager
ClientPlayerDataManager.__call = function(t, ...) return t.new(...) end

--[=[
    @within ClientPlayerDataManager
    @prop DEFAULT_MANAGER_NAME string
    The default internal manager name.
]=]
ClientPlayerDataManager.DEFAULT_MANAGER_NAME = "Default"

--[=[
    @within ClientPlayerDataManager
    @prop PlayerDataReady Signal<Player>
    A signal that fires when a Player's data is ready to be used.
]=]

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Gets the TableReplicatorSingleton for this manager so you can get immediate info from
    it if needed.
]=]
function ClientPlayerDataManager:GetImmediate(managerName: string?): TableReplicatorSingleton
    local s = self._Singletons[managerName]
    assert(s, `{managerName} is not a registered singleton.`)
    return s
end

--[=[
    Gets the TableManager associated with the given name. This method may return `nil` if the
    data has not replicated yet.
]=]
function ClientPlayerDataManager:GetManager(managerName: string?): TableManager?
    local singleton = self._Singletons[managerName]
    assert(singleton, `{managerName} has not been registered`)
    return singleton:GetTableManager()
end

--[=[
    Promises the TableManager associated with the given name. If it doesnt exist when called then
    it will wait for it to be replicated and then will resolve.
]=]
function ClientPlayerDataManager:PromiseManager(managerName: string?): Promise
    local singleton = self._Singletons[managerName]
    assert(singleton, `{managerName} has not been registered`)
    return singleton:PromiseTableManager()
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

--[=[
    Registers a tableManager/TableReplicatorSingleton to be watched for on the client.
    
    Informal registration. Assumes data key in the profile template is the same as the given name.
    ```lua
    ClientPlayerDataManager:RegisterManager("Currency")
    ```

    Formal registration. Used for more complex/custom registering of managers
    ```lua
    ClientPlayerDataManager:RegisterManager({
        Name = "Currency",
        DefaultDataSchema = profileTemplate["Currency"],
        ConditionFn = function(replicator)
            return replicator:GetTag("UserId") == LocalPlayer.UserId
        end,
    })
]=]
function ClientPlayerDataManager:RegisterManager(config: string | {
    Name: string;
    DefaultDataSchema: table;
    ConditionFn: ((replicator: TableReplicator) -> boolean)?
}): TableReplicatorSingleton
    if typeof(config) == "string" then
        config = {
            Name = config,
            DefaultDataSchema = self._ProfileSchema[config]
        }
    end
    
    if self._STARTED then
        warn("It is not reccomended to register managers after Start has been called")    
    end

    assert(type(config) == "table", "Config must be a table")
    assert(T.interface({
        Name = T.string,
        DefaultDataSchema = T.table,
        ConditionFn = T.optional(T.callback),
    }))

    local managerName = config.Name

    if self._Singletons[managerName] then
        warn("Already Registered Object with name", managerName)
        return self._Singletons[managerName]
    end

    -- TODO: Validate managerName?
    self._Singletons[managerName] = TableReplicator.fromTemplate({
        ClassTokenName = managerName;
        DefaultDataSchema = config.DefaultDataSchema;
        ConditionFn = config.ConditionFn or DEFAULT_CONDITION_FN;
    })

    return self._Singletons[managerName]
end


--[=[
    @unreleased
    Marks the CPDM as started. This is not currently neccessary
]=]
function ClientPlayerDataManager:Start()
    self._STARTED = true
    self.Start = function()
        warn("ClientPlayerDataManager has already started.")
    end
end

--[=[
    @tag Constructor
    @tag Static
    @return ClientPlayerDataManager
]=]
function ClientPlayerDataManager.new(config: {
    ProfileSchema: table,
})
    assert(T.interface({
        ProfileSchema = T.table,
    }))
    local self = setmetatable(BaseObject.new(), ClientPlayerDataManager)

    self._Singletons = {}
    self._ProfileSchema = config.ProfileSchema

    -- FLAGS
    self._DEBUG = true
    self._STARTED = false

    self.new = function()
        warn("ClientPlayerDataManager is a singleton and should not be instantiated multiple times.")
        return self
    end

    return self
end

export type ClientPlayerDataManager = typeof(ClientPlayerDataManager.new())

return ClientPlayerDataManager