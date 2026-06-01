--!strict
-- Authors: Logan Hunt (Raildex)
-- August 20, 2024
--[=[
    @class ClientPlayerDataManager

    This class provides a constructed, namespace-aware interface for accessing player data replicated from the server.
    Each ClientPlayerDataManager instance is paired with a ServerPlayerDataManager via a shared namespace string.

    Key Features:
    - Constructed instances with namespace isolation (multiple instances can coexist)
    - Automatic discovery of server-registered managers via namespace folder structure
    - Promise-based API for safe asynchronous access
    - Direct signal fields for lifecycle events

    Basic Usage:
    ```lua
    local PlayerDataManager = require(Packages.PlayerDataManager)
    local cpdm = PlayerDataManager.Client.new("PlayerData")

    cpdm:Start():await() -- wait for all managers to be ready

    local currencyManager = cpdm:GetManager("Currency")
    currencyManager:Observe("Robux", function(money)
        print("My premium currency is:", money)
    end)
    ```

    :::tip Usage with ROAM
    If you are using ROAM then you can set it up easily with the following format:
    ```lua
    local PlayerDataManager = require(Packages.PlayerDataManager)
    local cpdm = PlayerDataManager.Client.new("PlayerData")

    function cpdm:RoamInit()
        task.wait() -- optional frame delay to allow for other services to register if they need to
        local startProm = self:Start()
        startProm:await() -- yield roam to prevent Start until all managers are ready. This is optional, but makes it safer to access managers.
    end

    local Roam = require(Packages.Roam)
    Roam.registerService(cpdm, "PlayerDataController")

    return cpdm
    ```
    :::
]=]

--// Services //--
const Players = game:GetService("Players")

--// Imports //--
const Packages = script.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)
const Promise = require(Packages.Promise)
const SharedUtil = require(script.Parent.SharedUtil)
const TableManager = require(Packages.TableManager)
const TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = { [any]: any }
type PromiseObject = Promise.Promise
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ClientTableReplicator
type Connection = {
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}
type ManagerReadySignal = Signal.Signal<(name: string, manager: TableManager) -> (), string, TableManager>
type PlayerDataReadySignal = Signal.VoidSignal
type NamespaceLostSignal = Signal.VoidSignal
type LifecycleState = "idle" | "starting" | "ready" | "unavailable" | "destroyed"

--[=[
    @type ClientPlayerDataManager
    @within ClientPlayerDataManager
    Public interface for `ClientPlayerDataManager` instances.
]=]
export type ClientPlayerDataManager = {
	ClassName: string,
	new: (name: string) -> ClientPlayerDataManager,
	-- lifecycle signals (connect directly on the instance)
	PlayerDataReady: PlayerDataReadySignal,
	ManagerReady: ManagerReadySignal,
	NamespaceLost: NamespaceLostSignal,
	-- status
	IsReady: (self: ClientPlayerDataManager) -> boolean,
	OnReady: (self: ClientPlayerDataManager) -> PromiseObject,
	OnUnavailable: (self: ClientPlayerDataManager) -> PromiseObject,
	-- manager access
	GetManager: (self: ClientPlayerDataManager, managerName: string?) -> TableManager?,
	GetReplicator: (self: ClientPlayerDataManager, managerName: string?) -> TableReplicator?,
	PromiseManager: (self: ClientPlayerDataManager, managerName: string?) -> PromiseObject,
	-- lifecycle
	Start: (self: ClientPlayerDataManager) -> PromiseObject,
	Destroy: (self: ClientPlayerDataManager) -> (),
}

type CPDM_Internal = ClientPlayerDataManager & {
	-- fields
	_name: string,
	_replicators: { [string]: TableReplicator },
	_ready: boolean,
	_lifecycleState: LifecycleState,
	_serverManagersRegistered: PromiseObject?,
	_janitor: Janitor,
	_DEBUG: boolean?,
	DEFAULT_MANAGER_NAME: string,
	-- private methods
	_handleNamespaceLost: (self: CPDM_Internal) -> (),
	_getToken: (self: CPDM_Internal, managerName: string) -> string,
}

-- Constants
const REGISTERED_MANAGERS_FOLDER_NAME = SharedUtil.REGISTERED_MANAGERS_FOLDER_NAME
const ACTIVE_NAMESPACE_REGISTRY_FOLDER_NAME = SharedUtil.ACTIVE_NAMESPACE_REGISTRY_FOLDER_NAME
const LocalPlayer = Players.LocalPlayer

--[=[
    Creates a new ClientPlayerDataManager instance scoped to a namespace.
    All managers discovered by this instance will be namespaced under the provided `name`.
    
    ```lua
    local cpdm = ClientPlayerDataManager.new("PlayerData")
    cpdm:Start():await()
    ```
]=]
local ClientPlayerDataManager = {}
ClientPlayerDataManager.ClassName = "ClientPlayerDataManager"
ClientPlayerDataManager.__index = ClientPlayerDataManager

function ClientPlayerDataManager.new(namespace: string): ClientPlayerDataManager
	assert(
		type(namespace) == "string" and #namespace > 0,
		"[📥] ClientPlayerDataManager.new() requires a non-empty namespace string"
	)

	local reservation = SharedUtil.reserveFolderNamespace(ACTIVE_NAMESPACE_REGISTRY_FOLDER_NAME, namespace)

	local self = (setmetatable({}, ClientPlayerDataManager) :: any) :: CPDM_Internal

	self._name = namespace
	self._replicators = {}
	self._ready = false
	self._lifecycleState = "idle"
	self._janitor = Janitor.new()
	self.DEFAULT_MANAGER_NAME = SharedUtil.DEFAULT_MANAGER_NAME

	-- Instance-level lifecycle signals
	self.PlayerDataReady = self._janitor:Add(Signal.new() :: any) :: PlayerDataReadySignal
	self.ManagerReady = self._janitor:Add(Signal.new() :: any) :: ManagerReadySignal
	self.NamespaceLost = self._janitor:Add(Signal.new() :: any) :: NamespaceLostSignal
	self._janitor:Add(reservation)

	return (self :: any) :: ClientPlayerDataManager
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

-- Generates a namespace-scoped token for the given manager name.
function ClientPlayerDataManager._getToken(self: CPDM_Internal, managerName: string): string
	return SharedUtil.getTokenName(self._name, managerName)
end

-- Transitions this instance into an unavailable state when the server namespace is removed.
function ClientPlayerDataManager._handleNamespaceLost(self: CPDM_Internal)
	if self._lifecycleState == "destroyed" or self._lifecycleState == "unavailable" then
		return
	end

	self._replicators = {}
	self._ready = false
	self._lifecycleState = "unavailable"
	self._serverManagersRegistered = nil
	self.NamespaceLost:Fire()
end

--------------------------------------------------------------------------------
--// Lifecycle Management //--
--------------------------------------------------------------------------------

--[=[
    @tag yields
    Starts the auto-listening process for server-registered managers.
    Discovers managers in the namespace-scoped folder: `RegisteredServerManagers/{name}/`
    
    Must be called before accessing managers.
    
    Returns a promise that resolves when all managers are ready.
]=]
function ClientPlayerDataManager:Start(): PromiseObject
	assert(
		not self._serverManagersRegistered,
		`[📥] ClientPlayerDataManager('{self._name}') has already been started`
	)
	assert(self._lifecycleState ~= "destroyed", `[📥] ClientPlayerDataManager('{self._name}') is destroyed.`)

	self._lifecycleState = "starting"

	self._serverManagersRegistered = Promise.new(function(resolve)
		-- Navigate to namespace-scoped folder
		local registeredRoot = script.Parent:WaitForChild(REGISTERED_MANAGERS_FOLDER_NAME)
		local managersListFolder = registeredRoot:WaitForChild(self._name)
		self._janitor:Add(
			managersListFolder.AncestryChanged:Connect(function(_, parent)
				if not parent then
					self:_handleNamespaceLost()
				end
			end),
			"Disconnect"
		)

		local managerProms: { PromiseObject } = {}

		for _, managerObj in managersListFolder:GetChildren() do
			local managerName = managerObj.Name
			local expectedToken = self:_getToken(managerName)

			-- Wait for replicator with namespace-scoped token
			local prom = TableReplicator.promiseFirstReplicator(function(replicator)
				local tokenMatches = replicator:GetTokenName() == expectedToken
				local userIdMatches = tostring(replicator:GetTag("UserId")) == tostring(LocalPlayer.UserId)
				return tokenMatches and userIdMatches
			end):andThen(function(replicator)
				self._replicators[managerName] = replicator
				self.ManagerReady:Fire(managerName, replicator:GetTableManager())
			end)

			table.insert(managerProms, prom)
		end

		-- Wait for all managers to be ready
		Promise.all(managerProms):andThen(resolve)
	end):andThen(function()
		if self._lifecycleState == "unavailable" then
			return
		end
		self._ready = true
		self._lifecycleState = "ready"
		self.PlayerDataReady:Fire()
	end)

	return self._serverManagersRegistered
end

--------------------------------------------------------------------------------
--// Fetcher Methods //--
--------------------------------------------------------------------------------

--[=[
    Gets the TableManager associated with the given manager name.
    Returns nil if the manager is not ready or has been destroyed.
    
    ```lua
    cpdm:Start():await()
    local currencyManager = cpdm:GetManager("Currency")
    currencyManager:Observe("Robux", function(money)
        print("My premium currency is:", money)
    end)
    ```
    
    :::warn
    This method will return nil if the data has not been replicated yet or the
    client is in the process of shutting down.
    :::
]=]
function ClientPlayerDataManager:GetManager(managerName: string?): TableManager?
	assert(self:IsReady(), "[📥] Don't use :GetManager() before the data has replicated")
	managerName = managerName or self.DEFAULT_MANAGER_NAME
	assert(typeof(managerName) == "string", `[📥] Expected 'managerName' to be a string, got {typeof(managerName)}`)

	local replicator = self._replicators[managerName]
	if not replicator then
		warn(`[📥] '{managerName}' is not a registered manager`)
		return nil
	end

	if replicator.IsDestroyed then
		warn(`[📥] '{managerName}' replicator is destroyed. Returning nil.`)
		return nil
	end

	return replicator:GetTableManager()
end

--[=[
    Gets the TableReplicator associated with the given manager name.
    Returns nil if the replicator is not ready or has been destroyed.
]=]
function ClientPlayerDataManager:GetReplicator(managerName: string?): TableReplicator?
	assert(self:IsReady(), "[📥] Don't use :GetReplicator() before the data has replicated")
	managerName = managerName or self.DEFAULT_MANAGER_NAME
	assert(typeof(managerName) == "string", `[📥] Expected 'managerName' to be a string, got {typeof(managerName)}`)

	local replicator = self._replicators[managerName]
	if not replicator then
		warn(`[📥] '{managerName}' is not a registered replicator`)
		return nil
	end

	if replicator.IsDestroyed then
		warn(`[📥] '{managerName}' replicator is destroyed. Returning nil.`)
		return nil
	end

	return replicator
end

--[=[
    Promises the TableManager associated with the given manager name.
    If it doesn't exist when called, waits for it to be discovered and replicated.
    
    ```lua
    cpdm:PromiseManager("Currency"):andThen(function(manager: TableManager)
        manager:Observe("Robux", function(money)
            print("My premium currency is:", money)
        end)
    end)
    ```

    @return PromiseObject
]=]
function ClientPlayerDataManager:PromiseManager(managerName: string?): PromiseObject
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	if self._lifecycleState == "destroyed" then
		return Promise.reject(`[📥] ClientPlayerDataManager('{self._name}') is destroyed.`)
	end

	if self._lifecycleState == "unavailable" then
		return Promise.reject(
			`[📥] Namespace '{self._name}' became unavailable because its ServerPlayerDataManager was destroyed.`
		)
	end

	local replicator = self._replicators[managerName]
	if replicator and not replicator.IsDestroyed then
		return Promise.resolve(replicator:GetTableManager())
	end

	return Promise.fromEvent(self.ManagerReady, function(name)
		return name == managerName
	end):andThen(function(_, manager)
		return manager
	end)
end

--------------------------------------------------------------------------------
--// Status Methods //--
--------------------------------------------------------------------------------

--[=[
    Checks if all the managers have been discovered and are ready to be used.
]=]
function ClientPlayerDataManager:IsReady(): boolean
	return self._ready
end

--[=[
    Returns a promise that resolves when all player managers have been discovered and replicated.
]=]
function ClientPlayerDataManager:OnReady(): PromiseObject
	if self:IsReady() then
		return Promise.resolve()
	end
	return Promise.fromEvent(self.PlayerDataReady)
end

--[=[
	Returns a promise that resolves when the associated server namespace becomes unavailable.
]=]
function ClientPlayerDataManager:OnUnavailable(): PromiseObject
	if self._lifecycleState == "unavailable" or self._lifecycleState == "destroyed" then
		return Promise.resolve()
	end
	return Promise.fromEvent(self.NamespaceLost)
end

--------------------------------------------------------------------------------
--// Cleanup //--
--------------------------------------------------------------------------------

--[=[
    Destroys the ClientPlayerDataManager instance and all associated signals and connections.
]=]
function ClientPlayerDataManager:Destroy()
	self._lifecycleState = "destroyed"
	self._ready = false
	self._replicators = {}
	self._serverManagersRegistered = nil
	self._janitor:Destroy()
end

return ClientPlayerDataManager
