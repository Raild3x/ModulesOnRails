-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ServerPlayerDataManager

    The Server side class for the PlayerDataManager package.

    ## Overview
    This class manages server-side player data replication and lifecycle. It provides a namespace-aware, 
    constructed instance pattern so each namespace can have an independent manager registry, lifecycle, 
    and replication scope.

    ## Core Responsibilities
    - Register data managers for different player data concerns (e.g., Currency, Inventory)
    - Handle player join/leave lifecycle automatically
    - Replicate data to clients via TableReplicator
    - Provide synchronous and Promise-based access to managers
    - Ensure data is ready before access via signals

    ## Basic Usage
    ```lua
    local SPDM = require(packages.ServerPlayerDataManager)
    
    local function getPlayerData(player: Player)
        return Promise.resolve({
            DefaultManager = { level = 1, exp = 0 },
            Currency = { gold = 100, gems = 10 }
        })
    end
    
    local pdm = SPDM.new("PlayerData", getPlayerData)
    
    pdm:RegisterManager("Currency", function(player, data)
        return {
            Data = data.Currency,
            ReplicationTargets = player
        }
    end)
    
    pdm:Start()
    ```
]=]

const Players = game:GetService("Players")

--// Imports //--
const Packages = script.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)
const Promise = require(Packages.Promise)
const RailUtil = require(Packages.RailUtil)
const SharedUtil = require(script.Parent.SharedUtil)
const TableManager = require(Packages.TableManager)
const TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = { [any]: any }
type PromiseObject = Promise.Promise
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ServerTableReplicator
type PlayerProfileManager = table -- PlayerProfileManager.PlayerProfileManager
type Connection = {
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

type DataProvider = (player: Player) -> PromiseObject

type ManagerConfig = {
	Data: table,
	ReplicationTargets: "All" | "None" | "Self" | "self" | Player | { Player }?,
	Tags: table?,
	Parent: Instance?,
	Client: table?, -- POWER USER FEATURE
}

type ManagerTemplate = {
	ConfigGenerator: (player: Player, data: table) -> ManagerConfig,
}

type PlayerDataEntry = {
	Replicators: { [string]: TableReplicator },
	AllManagersReady: boolean,
	ForEachJanitors: { Janitor },
}

type SPDM_Internal = {
	ClassName: string,
	_DEBUG: boolean,
	DEFAULT_MANAGER_NAME: string?,
	ManagerReady: Signal.Signal<
		(player: Player, managerName: string, manager: TableManager) -> (),
		Player,
		string,
		TableManager
	>,
	ManagerRegistered: Signal.Signal<(managerName: string) -> (), string>,
	PlayerDataReady: Signal.Signal<(player: Player) -> (), Player>,
	_name: string,
	_dataProvider: DataProvider,
	_playerData: { [Player]: PlayerDataEntry },
	_managerTemplates: { [string]: ManagerTemplate },
	_replicatorTokens: { [string]: any },
	_janitor: Janitor,
	_started: boolean,
	new: (name: string, dataProvider: DataProvider) -> SPDM_Internal,
	fromPPM: (name: string, ppm: PlayerProfileManager) -> SPDM_Internal,
	_getToken: (self: SPDM_Internal, managerName: string) -> any,
	_setupPlayerDataManagers: (self: SPDM_Internal, player: Player, data: table) -> ({ PromiseObject }, Janitor),
	_refreshRegisteredManagersFolder: (self: SPDM_Internal) -> (),
	Start: (self: SPDM_Internal) -> (),
	RegisterManager: (
		self: SPDM_Internal,
		managerName: string,
		configGenerator: (player: Player, data: table) -> ManagerConfig
	) -> (),
	GetManager: (self: SPDM_Internal, player: Player, managerName: string?) -> TableManager?,
	PromiseManager: (self: SPDM_Internal, player: Player, managerName: string?) -> PromiseObject,
	GetReplicator: (self: SPDM_Internal, player: Player, managerName: string?) -> TableReplicator?,
	IsManagerRegistered: (self: SPDM_Internal, managerName: string?) -> boolean,
	IsManagerReady: (self: SPDM_Internal, player: Player, managerName: string?) -> boolean,
	IsPlayerReady: (self: SPDM_Internal, player: Player) -> boolean,
	OnPlayerReady: (self: SPDM_Internal, player: Player) -> PromiseObject,
	ForEachPlayer: (self: SPDM_Internal, func: (player: Player, janitor: Janitor) -> ()) -> Connection,
	IsStarted: (self: SPDM_Internal) -> boolean,
	Destroy: (self: SPDM_Internal) -> (),
	DisableDefaultManager: (self: SPDM_Internal) -> (),
	SetDefaultManagerName: (self: SPDM_Internal, managerName: string) -> (),
	[any]: any,
}

--// Constants //--
const DEFAULT_TIMEOUT = 60
const REGISTERED_MANAGERS_FOLDER_NAME = SharedUtil.REGISTERED_MANAGERS_FOLDER_NAME

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ServerPlayerDataManager = {}
ServerPlayerDataManager.ClassName = "ServerPlayerDataManager"
ServerPlayerDataManager.__index = ServerPlayerDataManager

--------------------------------------------------------------------------------

-- Validates that the provided value is a Player instance currently in the game.
-- Throws an error if the type is wrong, warns if the player is not a descendant of Players service.
local function assertPlayer(player: any)
	if not (player and typeof(player) == "Instance" and player:IsA("Player")) then
		error("[📤] Expected a Player instance. Got Type: " .. typeof(player) .. " | Value: " .. tostring(player))
	end
	if player.Parent ~= Players then
		warn("[📤] Player is not a descendant of the game. Value: " .. tostring(player))
	end
end

-- Validates that the provided manager name is a non-empty string.
-- Throws an error if the type is incorrect.
local function assertValidManagerName(managerName: any)
	if typeof(managerName) ~= "string" then
		error(
			"[📤] Expected a string for managerName. Got Type: "
				.. typeof(managerName)
				.. " | Value: "
				.. tostring(managerName)
		)
	end
end

-- Prints debug information if DEBUG mode is enabled on this instance.
local function debugPrint(self: SPDM_Internal, ...)
	if self._DEBUG then
		print("[📤 SPDM]", ...)
	end
end

--------------------------------------------------------------------------------
--// Constructors //--
--------------------------------------------------------------------------------

--[=[
    Creates a new ServerPlayerDataManager instance for a given namespace.
    
    The namespace string allows multiple independent instances to coexist, each with their own
    manager registry, lifecycle, and replication scope.
    
    @param nameSpace -- A unique identifier for this manager instance (e.g., "PlayerData", "Economy")
    @param dataProvider -- A function that receives a Player and returns a Promise resolving to a data table
    @return -- A new ServerPlayerDataManager instance
    
    Example:
    ```lua
    local function getPlayerData(player: Player)
        return Promise.resolve({
            DefaultManager = { level = 1, exp = 0 }
        })
    end
    
    local pdm = ServerPlayerDataManager.new("PlayerData", getPlayerData)
    ```
]=]
function ServerPlayerDataManager.new(nameSpace: string, dataProvider: DataProvider): SPDM_Internal
	assert(typeof(nameSpace) == "string" and #nameSpace > 0, "[📤] Expected a non-empty string for nameSpace.")
	assert(typeof(dataProvider) == "function", "[📤] Expected dataProvider to be a function.")
	local namespaceReservation = SharedUtil.reserveFolderNamespace(REGISTERED_MANAGERS_FOLDER_NAME, nameSpace)

	local self = setmetatable({}, ServerPlayerDataManager) :: any
	self._name = nameSpace
	self._dataProvider = dataProvider
	self._playerData = {}
	self._managerTemplates = {}
	self._replicatorTokens = {}
	self._janitor = Janitor.new()
	self._started = false

	self._DEBUG = false
	self.DEFAULT_MANAGER_NAME = SharedUtil.DEFAULT_MANAGER_NAME

	self.ManagerReady = self._janitor:Add(Signal.new())
	self.ManagerRegistered = self._janitor:Add(Signal.new())
	self.PlayerDataReady = self._janitor:Add(Signal.new())
	self._janitor:Add(namespaceReservation)
	self._janitor:Add(function()
		for player, entry in self._playerData do
			for _, forEachJani in ipairs(entry.ForEachJanitors) do
				forEachJani:Destroy()
			end

			for _, replicator in entry.Replicators do
				local manager = replicator:GetTableManager()
				replicator:Destroy()
				manager:Destroy()
			end

			self._playerData[player] = nil
		end

		self._managerTemplates = {}
		self._replicatorTokens = {}
		self._started = false
	end)

	return self
end

--[=[
    Creates a ServerPlayerDataManager instance that sources data from a PlayerProfileManager.
    
    This is a convenience constructor that automatically integrates with PlayerProfileManager,
    eliminating the need to manually define a data provider function.
    
    @param name -- The namespace identifier for this manager
    @param ppm -- A valid PlayerProfileManager instance to source data from
    @return -- A new ServerPlayerDataManager instance configured with PPM data
    
    Example:
    ```lua
    local ppm = require(packages.PlayerProfileManager).new("PlayerProfiles")
    local pdm = ServerPlayerDataManager.fromPPM("PlayerData", ppm)
    ```
]=]
function ServerPlayerDataManager.fromPPM(name: string, ppm: PlayerProfileManager): SPDM_Internal
	assert(ppm, "[📤] PlayerProfileManager is required for fromPPM.")
	assert(ppm.ClassName == "PlayerProfileManager", "[📤] fromPPM expected a valid PlayerProfileManager instance.")

	return ServerPlayerDataManager.new(name, function(player: Player)
		return ppm:PromiseProfile(player):andThen(function(profile)
			assert(typeof(profile.Data) == "table", "[📤] fromPPM expected profile.Data to be a table.")
			return profile.Data
		end)
	end)
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

--[[ Generate or retrieve a cached replication token for the given manager name.
     Tokens are namespace-scoped to prevent conflicts between different PDM instances. ]]
function ServerPlayerDataManager._getToken(self: SPDM_Internal, managerName: string)
	local tokenName = SharedUtil.getTokenName(self._name, managerName)
	if not self._replicatorTokens[tokenName] then
		self._replicatorTokens[tokenName] = TableReplicator.Token(tokenName)
	end
	return self._replicatorTokens[tokenName]
end

--[[ Initialize all registered managers for a newly joined player.
     Returns an array of promises (one per manager) and a cleanup Janitor.
     This is called automatically when a player's data has been resolved. ]]
function ServerPlayerDataManager._setupPlayerDataManagers(
	self: SPDM_Internal,
	player: Player,
	data: table
): ({ PromiseObject }, Janitor)
	debugPrint(self, "Setting up player data managers for", player)

	-- Create cleanup Janitor and initialize player data entry
	local jani = Janitor.new()
	local replicators = {}
	self._playerData[player] = {
		Replicators = replicators,
		AllManagersReady = false,
		ForEachJanitors = {},
	}

	-- Create a promise for each registered manager
	local managerReadyPromises = {}
	for name, template in self._managerTemplates do
		local generateConfig = template.ConfigGenerator
		table.insert(
			managerReadyPromises,
			jani:AddPromise(Promise.new(function(resolve)
				-- Get the config for this manager from the template
				local config = generateConfig(player, data)
				assert(typeof(config.Data) == "table", "The Data function must return a table. Failed for: " .. name)

				-- Normalize replication targets (handle string shortcuts)
				local rTargets = config.ReplicationTargets
				if typeof(rTargets) == "string" and string.lower(rTargets) == "self" then
					rTargets = player
				elseif not config.Parent and not rTargets then
					warn(
						`[📤] ReplicationTargets is not set for {name} manager. Defaulting to '{player.Name}'. To ensure nil replication targets, set ReplicationTargets to 'None'.`
					)
					rTargets = player
				elseif typeof(rTargets) == "string" and string.lower(rTargets) == "none" then
					rTargets = nil
				end

				-- Create the TableManager and Replicator for this manager
				local tm = TableManager.new(config.Data)
				local tr = TableReplicator.new {
					ClassToken = self:_getToken(name),
					TableManager = tm,
					ReplicationTargets = rTargets,
					Parent = config.Parent,
					Client = config.Client,
					Tags = RailUtil.Table.Reconcile(config.Tags or {}, { UserId = player.UserId }),
				}

				-- Cleanup replicator and table manager when player leaves
				jani:Add(function()
					task.wait() -- wait a frame to allow other disconnects to process first
					tr:Destroy()
					tm:Destroy()
				end)

				replicators[name] = tr
				self.ManagerReady:Fire(player, name, tm)
				resolve(tm)
			end))
		)
	end

	-- Cleanup all ForEach janitors when player leaves
	jani:Add(function()
		local entry = self._playerData[player]
		if entry then
			for _, forEachJani in ipairs(entry.ForEachJanitors) do
				forEachJani:Destroy()
			end
		end
		self._playerData[player] = nil
	end)

	return managerReadyPromises, jani
end

--[[ Refreshes the RegisteredServerManagers folder structure in the script parent.
     This folder is used by clients to discover which managers are available and wait for them.
     Creates the structure: RegisteredServerManagers/{nameSpace}/{managerNames} ]]
function ServerPlayerDataManager._refreshRegisteredManagersFolder(self: SPDM_Internal)
	-- Create or retrieve the root RegisteredServerManagers folder
	local rootFolder = SharedUtil.getOrCreateFolder(script.Parent, REGISTERED_MANAGERS_FOLDER_NAME)

	-- Create or retrieve the namespace-scoped folder
	local namespaceFolder = rootFolder:FindFirstChild(self._name)
	if not namespaceFolder then
		namespaceFolder = Instance.new("Folder")
		namespaceFolder.Name = self._name
		namespaceFolder.Parent = rootFolder
	end

	-- Clear old manager entries
	for _, child in ipairs(namespaceFolder:GetChildren()) do
		child:Destroy()
	end

	-- Create new manager entries for clients to discover
	for name in self._managerTemplates do
		local manager = Instance.new("BoolValue")
		manager.Name = name
		manager.Parent = namespaceFolder
	end
end

--------------------------------------------------------------------------------
--// Start Method //--
--------------------------------------------------------------------------------

--[=[
    Starts the ServerPlayerDataManager, initializing all managers for all current and future players.
    
    This method:
    - Begins listening for player join events
    - Calls the dataProvider for each player to get their data
    - Sets up all registered managers for each player
    - Automatically registers a "DefaultManager" if not already registered (unless disabled)
    - Fires PlayerDataReady signal when each player's data is fully initialized
    
    Must be called after all managers are registered and cannot be called more than once.
    
    Example:
    ```lua
    local pdm = ServerPlayerDataManager.new("PlayerData", getPlayerData)
    pdm:RegisterManager("Currency", currencyConfig)
    pdm:Start() -- Begin listening for players
    ```
]=]
function ServerPlayerDataManager.Start(self: SPDM_Internal)
	if self._started then
		warn("[📤] ServerPlayerDataManager has already started. Do not call Start multiple times.")
		return
	end

	-- Automatically register default manager if enabled and not already registered
	if self.DEFAULT_MANAGER_NAME then
		if not self._managerTemplates[self.DEFAULT_MANAGER_NAME] then
			debugPrint(self, "Default Manager not registered. Registering Default Manager.")
			self:RegisterManager(self.DEFAULT_MANAGER_NAME, function(player: Player, resolvedData: table): ManagerConfig
				return {
					Data = resolvedData[self.DEFAULT_MANAGER_NAME],
					ReplicationTargets = player,
				}
			end)
		else
			debugPrint(self, "Default Manager already registered.")
		end
	else
		debugPrint(self, "Default Manager disabled (DEFAULT_MANAGER_NAME is nil).")
	end

	self._started = true
	debugPrint(self, "ServerPlayerDataManager has started!")

	-- Listen for all players and initialize their data
	local lifecycleConnection = RailUtil.Player.forEachPlayer(function(plr: Player, jani: Janitor)
		jani:AddPromise(self._dataProvider(plr):andThen(function(resolvedData: table)
			-- Validate dataProvider returned a table
			assert(typeof(resolvedData) == "table", "[📤] dataProvider must resolve a table.")

			-- Set up all managers for this player
			local readyPromises, cleanup = self:_setupPlayerDataManagers(plr, resolvedData)
			jani:Add(cleanup)

			-- Wait for all managers to be ready, then signal player is ready
			Promise.all(readyPromises):andThen(function()
				local entry = self._playerData[plr]
				if not entry then
					return
				end
				entry.AllManagersReady = true
				self.PlayerDataReady:Fire(plr)
				debugPrint(self, `{plr.Name}'s PlayerData is now ready.`)
			end)
		end))
	end)
	self._janitor:Add(lifecycleConnection, "Disconnect", "LifecycleConnection")

	-- Create the RegisteredServerManagers folder structure for clients to discover
	self:_refreshRegisteredManagersFolder()
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
    Registers a new data manager before the service is started.
    
    The configGenerator function is called for each player to define how their manager should be set up.
    Must be called before :Start() is invoked.
    
    @param managerName -- The unique name for this manager (e.g., "Currency", "Inventory")
    @param configGenerator -- A function(player, data) that returns a ManagerConfig table
    
    ManagerConfig structure:
    ```lua
    {
        Data = { ... },  -- The table to manage
        ReplicationTargets = player,  -- Who receives updates ("Self", "None", "All", Player, or {Players})
        Tags = { ... },  -- Optional custom tags (UserId added automatically)
        Parent = instance,  -- Optional parent for replicator instance
        Client = { ... }  -- Power user feature for custom client behavior
    }
    ```
    
    Example:
    ```lua
    pdm:RegisterManager("Currency", function(player, data)
        return {
            Data = data.Currency or { gold = 0, gems = 0 },
            ReplicationTargets = player
        }
    end)
    ```
]=]
function ServerPlayerDataManager.RegisterManager(
	self: SPDM_Internal,
	managerName: string,
	configGenerator: (player: Player, data: table) -> ManagerConfig
)
	assert(not self._started, "[📤] Cannot register data containers after the service has started.")
	assertValidManagerName(managerName)
	assert(typeof(configGenerator) == "function", "[📤] Expected configGenerator to be a function.")
	assert(not self._managerTemplates[managerName], "[📤] Manager already exists with name: " .. managerName)
	self._managerTemplates[managerName] = {
		ConfigGenerator = configGenerator,
	}
	debugPrint(self, "Registered Manager:", managerName)
	self.ManagerRegistered:Fire(managerName)
end

--[=[
    Synchronously gets the TableManager for a player's specific manager.
    
    Returns nil if the data is not ready yet or the manager doesn't exist.
    For safer access, consider using :PromiseManager() instead to wait for readiness.
    
    @param player -- The player whose manager to retrieve
    @param managerName -- The name of the manager (defaults to DEFAULT_MANAGER_NAME)
    @return -- The TableManager, or nil if not ready
    
    Example:
    ```lua
    pdm:Start():await()
    local currencyManager = pdm:GetManager(player, "Currency")
    if currencyManager then
        currencyManager:Set("gold", 100)
    end
    ```
    
    :::warn
    Only use this after the player data is confirmed ready. Use :OnPlayerReady() first if unsure.
    :::
]=]
function ServerPlayerDataManager.GetManager(self: SPDM_Internal, player: Player, managerName: string?): TableManager?
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	if not managerName then
		warn("[📤] No manager name provided and DEFAULT_MANAGER_NAME is disabled (nil).")
		return nil
	end

	assertValidManagerName(managerName)
	local entry = self._playerData[player]
	if not entry then
		assertPlayer(player)
		warn(
			`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. Their player data has not yet begun initializing!`
		)
		return nil
	end

	local replicator = entry.Replicators[managerName]
	if not replicator then
		if not self:IsPlayerReady(player) then
			warn(
				`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. Their player data is in the process of readying. \n`,
				debug.traceback()
			)
		else
			warn(
				`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. The manager does not exist. Check to ensure it was registered properly. Current Managers: `,
				RailUtil.Table.Keys(self._managerTemplates),
				"\n",
				debug.traceback()
			)
		end
		return nil
	end

	return replicator:GetTableManager()
end

--[=[
    Promises the TableManager for a player's specific manager.
    
    If the manager is already ready, resolves immediately. Otherwise, waits for the ManagerReady signal.
    This is the safe way to access managers asynchronously.
    
    @param player -- The player whose manager to promise
    @param managerName -- The name of the manager (defaults to DEFAULT_MANAGER_NAME)
    @return -- A Promise that resolves to the TableManager
    
    Example:
    ```lua
    pdm:PromiseManager(player, "Currency"):andThen(function(currencyManager)
        currencyManager:Observe("gold", function(newGold)
            print("Gold changed:", newGold)
        end)
    end)
    ```
]=]
function ServerPlayerDataManager.PromiseManager(
	self: SPDM_Internal,
	player: Player,
	managerName: string?
): PromiseObject
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	if not managerName then
		return Promise.reject("[📤] No manager name provided and DEFAULT_MANAGER_NAME is disabled (nil).")
	end

	assertPlayer(player)
	assertValidManagerName(managerName)
	local entry = self._playerData[player]
	if entry and entry.Replicators[managerName] then
		return Promise.resolve(entry.Replicators[managerName]:GetTableManager())
	end

	-- Wait for the manager to become ready
	return Promise.fromEvent(self.ManagerReady, function(readiedPlayer: Player, readiedManager: string)
		return readiedPlayer == player and readiedManager == managerName
	end):andThen(function()
		return self:GetManager(player, managerName)
	end)
end

--[=[
    Gets the TableReplicator for a player's specific manager.
    
    The replicator handles data synchronization to clients. Returns nil if the manager
    is not ready or doesn't exist.
    
    @param player -- The player whose replicator to retrieve
    @param managerName -- The name of the manager (defaults to DEFAULT_MANAGER_NAME)
    @return -- The TableReplicator, or nil if not ready
    
    Example:
    ```lua
    local replicator = pdm:GetReplicator(player, "Currency")
    if replicator then
        print("Replication token:", replicator:GetTokenName())
    end
    ```
]=]
function ServerPlayerDataManager.GetReplicator(
	self: SPDM_Internal,
	player: Player,
	managerName: string?
): TableReplicator?
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	if not managerName then
		warn("[📤] No manager name provided and DEFAULT_MANAGER_NAME is disabled (nil).")
		return nil
	end

	assertPlayer(player)
	assertValidManagerName(managerName)
	if not self:IsPlayerReady(player) then
		warn(`[📤] Failed to get {player.Name}'s TableReplicator. Their player data is not ready.`)
		return nil
	end
	local entry = self._playerData[player]
	return if entry then entry.Replicators[managerName] else nil
end

--- Checks if a manager is registered in this instance.
function ServerPlayerDataManager.IsManagerRegistered(self: SPDM_Internal, managerName: string?): boolean
	managerName = managerName or self.DEFAULT_MANAGER_NAME
	if not managerName then
		return false
	end
	assertValidManagerName(managerName)
	return self._managerTemplates[managerName] ~= nil
end

--- Checks if a specific manager is ready for a player.
function ServerPlayerDataManager.IsManagerReady(self: SPDM_Internal, player: Player, managerName: string?): boolean
	managerName = managerName or self.DEFAULT_MANAGER_NAME
	if not managerName then
		return false
	end
	assertPlayer(player)
	assertValidManagerName(managerName)
	local entry = self._playerData[player]
	return entry ~= nil and entry.Replicators[managerName] ~= nil
end

--- Checks if all of a player's managers are ready and fully initialized.
function ServerPlayerDataManager.IsPlayerReady(self: SPDM_Internal, player: Player): boolean
	assertPlayer(player)
	local entry = self._playerData[player]
	return entry ~= nil and entry.AllManagersReady
end

--[=[
    Returns a Promise that resolves when all of a player's data is ready.
    
    If the player is already ready, resolves immediately. Otherwise, waits for the
    PlayerDataReady signal (with a timeout to prevent hanging promises).
    
    @param player -- The player to wait for
    @return -- A Promise that resolves when all managers are ready
    
    Example:
    ```lua
    pdm:OnPlayerReady(player):andThen(function()
        local mgr = pdm:GetManager(player)
        -- All managers are ready here
    end)
    ```
]=]
function ServerPlayerDataManager.OnPlayerReady(self: SPDM_Internal, player: Player): PromiseObject
	assertPlayer(player)
	if self:IsPlayerReady(player) then
		return Promise.resolve()
	end
	-- Wait for PlayerDataReady signal with timeout
	return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
		return readiedPlayer == player
	end):timeout(DEFAULT_TIMEOUT, `[📤] PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end

--[=[
    Calls a function for each player in the game, and continues calling it for new players who join.
    
    The function yields until each player's data is ready, ensuring you always have access to their managers.
    Returns a connection that can be disconnected to stop listening for new players.
    
    @param func -- A function(player, janitor) to call for each player
    @return -- A Connection with Disconnect() method
    
    Example:
    ```lua
    local connection = pdm:ForEachPlayer(function(player, janitor)
        local currencyMgr = pdm:GetManager(player, "Currency")
        
        -- This connection is tied to this player's lifecycle
        janitor:Add(currencyMgr:Observe("gold", function(gold)
            print(player.Name .. " has " .. gold .. " gold")
        end))
    end)
    
    -- Later, stop listening for new players
    connection:Disconnect()
    ```
]=]
function ServerPlayerDataManager.ForEachPlayer(
	self: SPDM_Internal,
	func: (player: Player, janitor: Janitor) -> ()
): Connection
	assert(typeof(func) == "function", "[📤] Expected a function for the first argument. Got Type: " .. typeof(func))
	return RailUtil.Player.forEachPlayer(function(player: Player, jani: Janitor)
		-- Wait for this player's data to be ready before calling the func
		if not self:IsPlayerReady(player) then
			jani:AddPromise(self:OnPlayerReady(player)):await()
		end

		if self:IsPlayerReady(player) then
			-- Create a janitor scoped to the callback function's lifetime
			local callbackJani = Janitor.new()
			jani:Add(function()
				callbackJani:Destroy()
			end)

			-- Track the janitor so it gets cleaned up when player leaves
			local entry = self._playerData[player]
			if entry then
				table.insert(entry.ForEachJanitors, callbackJani)
			end

			-- Spawn the user's function with the player and janitor
			task.spawn(func, player, callbackJani)
		end
	end)
end

--- Returns whether the service has been started.
function ServerPlayerDataManager.IsStarted(self: SPDM_Internal): boolean
	return self._started
end

--- Destroys this instance and releases the namespace so it can be reused.
function ServerPlayerDataManager.Destroy(self: SPDM_Internal)
	self._janitor:Destroy()
end

--[=[
    Disables automatic registration of the default manager.
    
    Must be called before :Start(). Use this if you want explicit control over all managers
    and don't want an implicit default manager created.
    
    Example:
    ```lua
    local pdm = ServerPlayerDataManager.new("PlayerData", getPlayerData)
    pdm:DisableDefaultManager()
    pdm:RegisterManager("Currency", currencyConfig)
    pdm:Start()
    ```
]=]
function ServerPlayerDataManager.DisableDefaultManager(self: SPDM_Internal)
	assert(not self._started, "[📤] Cannot disable default manager after the service has started.")
	self.DEFAULT_MANAGER_NAME = nil
	debugPrint(self, "Default Manager disabled.")
end

--[=[
    Sets the name used for the automatically-registered default manager.
    
    Must be called before :Start(). By default, this is "DefaultManager", but it can be
    customized to any manager name you prefer.
    
    @param managerName -- The new default manager name
    
    Example:
    ```lua
    local pdm = ServerPlayerDataManager.new("PlayerData", getPlayerData)
    pdm:SetDefaultManagerName("PlayerStats")
    pdm:Start()
    ```
]=]
function ServerPlayerDataManager.SetDefaultManagerName(self: SPDM_Internal, managerName: string)
	assert(not self._started, "[📤] Cannot change default manager name after the service has started.")
	assertValidManagerName(managerName)
	self.DEFAULT_MANAGER_NAME = managerName
	debugPrint(self, "Default Manager name set to:", managerName)
end

export type ServerPlayerDataManager = typeof(ServerPlayerDataManager)

return ServerPlayerDataManager
