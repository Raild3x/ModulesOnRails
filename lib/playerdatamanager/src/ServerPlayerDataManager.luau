-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ServerPlayerDataManager

    The Server side class for the PlayerDataManager package

    ## Default Manager System
    
    By default, the ServerPlayerDataManager automatically creates a "DEFAULT_MANAGER" that maps to 
    the DEFAULT_MANAGER field in your data schema. This allows methods like GetManager() to work 
    without specifying a manager name.

    ## Save Callback System
    
    The ServerPlayerDataManager now supports priority-based save callbacks through `OnSave` and `OnLastSave` methods.
    Callbacks are executed in priority order (highest numbers first), allowing you to control the sequence of save operations.
    
    ### Priority Constants
    ```lua
    SPDM.SAVE_PRIORITY.HIGHEST  -- 1000
    SPDM.SAVE_PRIORITY.HIGH     -- 500  
    SPDM.SAVE_PRIORITY.NORMAL   -- 0 (default)
    SPDM.SAVE_PRIORITY.LOW      -- -500
    SPDM.SAVE_PRIORITY.LOWEST   -- -1000
    ```
    
    ### Usage Examples
    ```lua
    -- High priority callback (runs first)
    SPDM:OnLastSave(player, function(profile)
        profile.Data.LastSeen = DateTime.now().UnixTimestamp
    end, SPDM.SAVE_PRIORITY.HIGH)
    
    -- Normal priority callback (runs after high priority)
    SPDM:OnLastSave(player, function(profile)
        profile.Data.SessionCount += 1
    end) -- Default priority
    
    -- Low priority callback (runs last)
    SPDM:OnLastSave(player, function(profile)
        profile.Data.DataVersion = "1.0.0"
    end, SPDM.SAVE_PRIORITY.LOW)
    ```
]=]

const Players = game:GetService("Players")

--// Imports //--
const Packages = script.Parent.Parent
const Symbol = require(Packages.Symbol)
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)
const Promise = require(Packages.Promise)
const RailUtil = require(Packages.RailUtil)
const TableManager = require(Packages.TableManager)
const TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = { [any]: any }
type Promise = Promise.Promise
type Janitor = Janitor.Janitor
type TableManager = TableManager.TableManager
type TableReplicator = TableReplicator.ServerTableReplicator
type Profile = table --PlayerProfileManager.Profile
type PlayerProfileManager = table --PlayerProfileManager.PlayerProfileManager
type Connection = any

type SaveCallback = {
	callback: (profile: Profile) -> (),
	priority: number,
	connection: any,
}

type SPDM_Internal = {
	DEFAULT_MANAGER_NAME: string?,
	PlayerDataReady: any,
	ManagerRegistered: any,
	-- Methods used via self within the class body:
	Start: (self: SPDM_Internal, ppm: PlayerProfileManager) -> (),
	RegisterManager: (self: SPDM_Internal, managerName: string, configGenerator: any) -> (),
	IsPlayerReady: (self: SPDM_Internal, player: Player) -> boolean,
	GetProfile: (self: SPDM_Internal, player: Player) -> Profile?,
	GetPlayerProfileManager: (self: SPDM_Internal) -> PlayerProfileManager,
	OnPlayerReady: (self: SPDM_Internal, player: Player) -> Promise,
	[any]: any,
}

--// Constants //--
const DEFAULT_TIMEOUT = 60
const KEY_PPM = Symbol("PlayerProfileManager")

-- Priority constants for save callbacks
const SAVE_PRIORITY = {
	HIGHEST = 1000,
	HIGH = 500,
	NORMAL = 0,
	LOW = -500,
	LOWEST = -1000,
}

--// Volatiles //--
local STARTED = false -- DO NOT TOUCH
const PlayerData = {}
const ManagerTemplates = {}
const PlayerSaveCallbacks = {} -- Store save callbacks per player

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ServerPlayerDataManager = {}
ServerPlayerDataManager.ClassName = "ServerPlayerDataManager"
ServerPlayerDataManager.__index = ServerPlayerDataManager

--[=[
    @within ServerPlayerDataManager
    @prop SAVE_PRIORITY table
    Priority constants for save callbacks. Higher numbers execute first.
    
    ```lua
    SPDM.SAVE_PRIORITY.HIGHEST  -- 1000
    SPDM.SAVE_PRIORITY.HIGH     -- 500
    SPDM.SAVE_PRIORITY.NORMAL   -- 0 (default)
    SPDM.SAVE_PRIORITY.LOW      -- -500
    SPDM.SAVE_PRIORITY.LOWEST   -- -1000
    ```
]=]
ServerPlayerDataManager.SAVE_PRIORITY = SAVE_PRIORITY

--[=[
    @private
    @within ServerPlayerDataManager
    @prop _DEBUG boolean
    Whether or not to print debug messages.
]=]
ServerPlayerDataManager._DEBUG = false

--[=[
    @within ServerPlayerDataManager
    @prop DEFAULT_MANAGER_NAME string?
    The default internal manager name. Set to nil to disable default manager functionality.
]=]
-- ServerPlayerDataManager.DEFAULT_MANAGER_NAME = "DEFAULT_MANAGER"

--[=[
    @within ServerPlayerDataManager
    @prop ManagerReady Signal<player: Player, managerName: string, manager: TableManager>
    A signal that fires when a manager is ready for a Player.
]=]
ServerPlayerDataManager.ManagerReady = Signal.new()

--[=[
    @within ServerPlayerDataManager
    @prop ManagerRegistered Signal<managerName: string>
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

local function assertPlayer(player: any)
	if not (player and typeof(player) == "Instance" and player:IsA("Player")) then
		error("[📤] Expected a Player instance. Got Type: " .. typeof(player) .. " | Value: " .. tostring(player))
	end
	if player.Parent ~= Players then
		warn("[📤] Player is not a descendant of the game. Value: " .. tostring(player))
	end
end

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

local function debugPrint(...)
	if ServerPlayerDataManager._DEBUG then
		print("[📤 SPDM]", ...)
	end
end

-- Cache and fetch the class token for a given name
const ReplicatorClassTokens = {}
local function upsertToken(name: string)
	if not ReplicatorClassTokens[name] then
		ReplicatorClassTokens[name] = TableReplicator.Token(name)
	end
	return ReplicatorClassTokens[name]
end

-- Helper function to execute callbacks in priority order
local function executeSaveCallbacks(player: Player, profile: Profile, callbackType: string)
	local callbacks = PlayerSaveCallbacks[player] and PlayerSaveCallbacks[player][callbackType]
	if not callbacks or #callbacks == 0 then
		return
	end

	-- Sort callbacks by priority (highest first)
	table.sort(callbacks, function(a, b)
		return a.priority > b.priority
	end)

	-- Execute callbacks in priority order
	for _, callbackData in ipairs(callbacks) do
		local success, err = pcall(callbackData.callback, profile)
		if not success then
			warn(`[📤] Save callback failed for {player.Name}: {err}`)
		end
	end
end

-- Helper function to add a save callback with priority
local function addSaveCallback(
	player: Player,
	callbackType: string,
	callback: (profile: Profile) -> (),
	priority: number
): any
	if not PlayerSaveCallbacks[player] then
		PlayerSaveCallbacks[player] = {
			OnSave = {},
			OnLastSave = {},
		}
	end

	local callbackData = {
		callback = callback,
		priority = priority,
		connection = nil, -- Will be set later if needed
	}

	table.insert(PlayerSaveCallbacks[player][callbackType], callbackData)

	-- Return a connection-like object for cleanup
	local connection = {
		Disconnect = function()
			local callbacks = PlayerSaveCallbacks[player] and PlayerSaveCallbacks[player][callbackType]
			if callbacks then
				local idx = table.find(callbacks, callbackData)
				if idx then
					table.remove(callbacks, idx)
				end
			end
		end,
	}
	connection.Destroy = connection.Disconnect

	callbackData.connection = connection
	return connection
end

local function setupPlayerDataManagers(player: Player, profile: Profile)
	debugPrint("Setting up player data managers for", player)

	local jani = Janitor.new()
	local Replicators = {}
	PlayerData[player] = {
		Replicators = Replicators,
		AllManagersReady = false,
	}

	-- Initialize save callbacks for this player
	PlayerSaveCallbacks[player] = {
		OnSave = {},
		OnLastSave = {},
	}

	-- Setup save callback execution
	local saveConnection = profile.OnSave:Connect(function()
		executeSaveCallbacks(player, profile, "OnSave")
	end)

	local lastSaveConnection = profile.OnLastSave:Connect(function()
		executeSaveCallbacks(player, profile, "OnLastSave")
	end)

	jani:Add(function()
		saveConnection:Disconnect()
		lastSaveConnection:Disconnect()
		PlayerSaveCallbacks[player] = nil
	end)

	local managerReadyPromises = {}

	-- ...existing code...
	for name, data in ManagerTemplates do
		local generateConfig = data.ConfigGenerator
		table.insert(
			managerReadyPromises,
			jani:AddPromise(Promise.new(function(resolve)
				local config = generateConfig(player, profile)
				assert(typeof(config.Data) == "table", "The Data function must return a table. Failed for: " .. name)

				-- reconcile the replication targets
				local rTargets = config.ReplicationTargets
				if typeof(rTargets) == "string" and string.lower(rTargets) == "self" then
					rTargets = player
				elseif not config.Parent and not rTargets then
					warn(
						`[📤] ReplicationTargets is not set for {name} manager. Defaulting to '{player.Name}'. To ensure 'nil' replication targets, set ReplicationTargets to 'None'.`
					)
					rTargets = player
				elseif typeof(rTargets) == "string" and string.lower(rTargets) == "None" then
					rTargets = nil
				end

				local tm = TableManager.new(config.Data)
				local tr = TableReplicator.new {
					ClassToken = upsertToken(name),
					TableManager = tm,
					ReplicationTargets = rTargets,
					Parent = config.Parent,
					Client = config.Client,
					Tags = RailUtil.Table.Reconcile(config.Tags or {}, { UserId = player.UserId }),
				}

				jani:Add(function()
					task.wait() -- wait a frame to allow other disconnects to process first
					tr:Destroy()
					tm:Destroy()
				end)

				Replicators[name] = tr
				ServerPlayerDataManager.ManagerReady:Fire(player, name, tm)
				resolve(tm)
			end))
		)
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
function ServerPlayerDataManager.Start(self: SPDM_Internal, ppm: PlayerProfileManager)
	assert(ppm, "PlayerProfileManager is not set. Please set it before calling Start.")
	assert(
		ppm.ClassName == "PlayerProfileManager",
		"PlayerProfileManager is not a valid PlayerProfileManager instance."
	)
	ServerPlayerDataManager[KEY_PPM] = ppm

	-- Initialize the default manager if it's enabled and doesn't exist
	if self.DEFAULT_MANAGER_NAME then
		if not ManagerTemplates[self.DEFAULT_MANAGER_NAME] then
			if not ppm._config.DefaultDataSchema[self.DEFAULT_MANAGER_NAME] then
				error(`[📤] No table at index '{self.DEFAULT_MANAGER_NAME}' found in the DefaultDataSchema.`)
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
	else
		debugPrint("Default Manager disabled (DEFAULT_MANAGER_NAME is nil).")
	end

	-- Mark the service as started so no more managers can be registered
	STARTED = true

	-- Override the Start method so that it can only be called once
	self.Start = function()
		warn("[📤] ServerPlayerDataManager has already started. Do not call Start multiple times.")
	end

	debugPrint("ServerPlayerDataManager has started!")

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
function ServerPlayerDataManager.RegisterManager(
	self: SPDM_Internal,
	managerName: string,
	configGenerator: (
		player: Player,
		profile: Profile
	) -> {
		Data: table,
		ReplicationTargets: "All" | "None" | Player | { Player },
		Tags: table?,
		Parent: table?,
		Client: table?,
	}
)
	assert(not STARTED, "[📤] Cannot register data containers after the service has started.")
	assert(not ManagerTemplates[managerName], "[📤] Manager already exists with name: " .. managerName)
	ManagerTemplates[managerName] = {
		ConfigGenerator = configGenerator,
	}
	debugPrint("Registered Manager:", managerName)
	self.ManagerRegistered:Fire(managerName)
end

--[=[
    Fetches one of the given Player's TableManagers. If one is not specified then it will assume the default one.
    Will return nil if the player's data is not ready, the manager does not exist, or no default manager is configured.
    ```lua
    local defaultManager = SPDM:GetManager(Players.Raildex)
    assert(defaultManager, "Player data is not ready yet or no default manager configured.")
    defaultManager:Set("Volume", 0.5)
    ```
]=]
function ServerPlayerDataManager.GetManager(self: SPDM_Internal, player: Player, managerName: string?): TableManager?
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	-- Check if trying to access default manager when it's disabled
	if not managerName then
		warn("[📤] No manager name provided and DEFAULT_MANAGER_NAME is disabled (nil).")
		return nil
	end

	assertValidManagerName(managerName)
	if not PlayerData[player] then
		assertPlayer(player)
		warn(
			`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. Their player data has not yet begun initializing!`
		)
		return nil
	end

	local Replicator = PlayerData[player].Replicators[managerName]
	if not Replicator then
		if not self:IsPlayerReady(player) then
			warn(
				`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. Their player data is in the process of readying. \n`,
				debug.traceback()
			)
		else
			warn(
				`[📤] Failed to get {player.Name}'s TableManager '{managerName}'. The manager does not exist. Check to ensure it was registered properly. Current Managers: `,
				RailUtil.Table.Keys(ManagerTemplates),
				"\n",
				debug.traceback()
			)
		end
		return nil
	end

	return Replicator:GetTableManager()
end

--[=[
    Promises a TableManager for a given player. If a managerName is not specified then it will assume the default one.
    Will reject if no default manager is configured.
    ```lua
    SPDM:PromiseManager(Players.Raildex, "Settings"):andThen(function(manager)
        manager:Set("Volume", 0.5)
    end)
    ```
]=]
function ServerPlayerDataManager.PromiseManager(self: SPDM_Internal, player: Player, managerName: string?): Promise
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	-- Check if trying to access default manager when it's disabled
	if not managerName then
		return Promise.reject("[📤] No manager name provided and DEFAULT_MANAGER_NAME is disabled (nil).")
	end

	assertPlayer(player)
	assertValidManagerName(managerName)
	if PlayerData[player] and PlayerData[player].Replicators[managerName] then
		return Promise.resolve(PlayerData[player].Replicators[managerName]:GetTableManager())
	end

	return Promise.fromEvent(self.ManagerReady, function(readiedPlayer: Player, readiedManager: string)
		return readiedPlayer == player and readiedManager == managerName
	end):andThen(function()
		return self:GetManager(player, managerName)
	end)
end

--[=[
    Returns the TableReplicator associated with a Player's Manager. If a manager name is not specified then it will assume the default one.
    Will return nil if no default manager is configured.
    ```lua
    local replicator = SPDM:GetReplicator(Players.Raildex, "Settings")
    ```
]=]
function ServerPlayerDataManager.GetReplicator(
	self: SPDM_Internal,
	player: Player,
	managerName: string?
): TableReplicator?
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	-- Check if trying to access default manager when it's disabled
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
	return PlayerData[player].Replicators[managerName]
end

--[=[
    Checks whether or not a given manager is registered. If one is not specified then it will assume the default one.
    Returns false if no default manager is configured.
]=]
function ServerPlayerDataManager.IsManagerRegistered(self: SPDM_Internal, managerName: string?): boolean
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	-- Check if trying to access default manager when it's disabled
	if not managerName then
		return false
	end

	assertValidManagerName(managerName)
	return ManagerTemplates[managerName] ~= nil
end

--[=[
    Checks whether or not a given player's manager is ready. If one is not specified then it will assume the default one.
    Returns false if no default manager is configured.
    ```lua
    if SPDM:IsManagerReady(Players.Raildex, "Settings") then
        local settings = SPDM:GetManager(Players.Raildex, "Settings")
    end
    ```
]=]
function ServerPlayerDataManager.IsManagerReady(self: SPDM_Internal, player: Player, managerName: string?): boolean
	managerName = managerName or self.DEFAULT_MANAGER_NAME

	-- Check if trying to access default manager when it's disabled
	if not managerName then
		return false
	end

	assertPlayer(player)
	assertValidManagerName(managerName)
	return PlayerData[player] and PlayerData[player].Replicators[managerName] ~= nil
end

--[=[
    Checks whether or not a given player's data is ready
]=]
function ServerPlayerDataManager.IsPlayerReady(self: SPDM_Internal, player: Player): boolean
	assertPlayer(player)
	return PlayerData[player] ~= nil and PlayerData[player].AllManagersReady
end
-- ServerPlayerDataManager.IsReady = ServerPlayerDataManager.IsPlayerReady

--[=[
    Promise that resolves when the player's data is ready to be used.
]=]
function ServerPlayerDataManager.OnPlayerReady(self: SPDM_Internal, player: Player): Promise
	assertPlayer(player)
	if self:IsPlayerReady(player) then
		return Promise.resolve()
	end
	-- TODO: Check if the player has left the game
	return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
		return readiedPlayer == player
	end):timeout(DEFAULT_TIMEOUT, `[📤] PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end
-- ServerPlayerDataManager.OnReady = ServerPlayerDataManager.OnPlayerReady

--[=[
    @unreleased This method is not complete and is subject to change.

    Runs a function for all existing loaded player data and all future player data. Passes a janitor that
    runs its cleanup immediately prior to the final save of the player data.

    :::note Implicit Yield
    The callback is invoked inside `RailUtil.Player.forEachPlayer`. If the player's data is not yet
    ready, this internally yields (via `:await()`) until it becomes ready before running `func`.
    :::

    ```lua
    SPDM:ForEachPlayer(function(player, janitor)
        local defaultManager = SPDM:GetManager(player)
        defaultManager:Set("Volume", 0.5)
    end)
    ```
]=]
function ServerPlayerDataManager.ForEachPlayer(
	self: SPDM_Internal,
	func: (player: Player, janitor: Janitor) -> ()
): Connection
	local traceback = debug.traceback("", 2)
	assert(typeof(func) == "function", "[📤] Expected a function for the first argument. Got Type: " .. typeof(func))
	return RailUtil.Player.forEachPlayer(function(player: Player, jani: Janitor)
		if not self:IsPlayerReady(player) then
			jani:AddPromise(self:OnPlayerReady(player)):await()
		end

		if self:IsPlayerReady(player) then
			local saveJani = Janitor.new()
			local profile = self:GetProfile(player) :: Profile
			assert(profile:IsActive(), player.Name .. "'s profile is not active.")

			local thread = nil
			local conn = profile.OnLastSave:Connect(function(reason: string)
				debugPrint("Final save executing for:", player, "| Reason:", reason, traceback)
				saveJani:Destroy()
				task.cancel(thread)
			end)
			saveJani:Add(function()
				conn:Disconnect() -- Janitor wont let me give disconnect as a method to a non rbxscriptsignal
			end)
			thread = task.spawn(func, player, saveJani)
		end
	end)
end

--[=[
    Returns whether or not the ServerPlayerDataManager has been started.
    ```lua
    if SPDM:IsStarted() then
        print("SPDM has been started!")
    end
    ```
]=]
function ServerPlayerDataManager.IsStarted(self: SPDM_Internal): boolean
	return STARTED
end

--[=[
    Returns the PlayerProfileManager instance that is being used by the ServerPlayerDataManager.
    Will error if called prior to Starting the service.
]=]
function ServerPlayerDataManager.GetPlayerProfileManager(self: SPDM_Internal): PlayerProfileManager
	assert(STARTED, "[📤] SPDM has not yet been started.")
	return ServerPlayerDataManager[KEY_PPM]
end

--[=[
    Returns the Profile for a given player.
]=]
function ServerPlayerDataManager.GetProfile(self: SPDM_Internal, player: Player): Profile?
	assertPlayer(player)
	local ppm = self:GetPlayerProfileManager()
	return ppm:GetProfile(player)
end

--[=[
	Connects a callback to the OnSave event of a given player. This will run the callback
	whenever the player's data is saved (not just on the final save).
	
	@param player Player -- The player to attach the callback to
	@param callback function -- The callback to run on save
	@param priority number? -- Execution priority (higher numbers execute first, default: 0)
	@return Connection -- Connection object that can be disconnected
]=]
function ServerPlayerDataManager.OnSave(
	self: SPDM_Internal,
	player: Player,
	callback: (profile: Profile) -> (),
	priority: number?
): Connection?
	assertPlayer(player)
	assert(
		typeof(callback) == "function",
		"[📤] Expected a function for the callback. Got Type: " .. typeof(callback)
	)

	local profile = self:GetProfile(player)
	if not profile then
		warn("[📤] Player's profile is not active.")
		return nil
	end

	return addSaveCallback(player, "OnSave", callback, priority or SAVE_PRIORITY.NORMAL)
end

--[=[
	Connects a callback to the OnLastSave event of a given player. This will run the callback immediately
	prior to the final save of the player's data. This is useful for handling data that needs to be serialized.
	
	@param player Player -- The player to attach the callback to
	@param callback function -- The callback to run on last save
	@param priority number? -- Execution priority (higher numbers execute first, default: 0)
	@return Connection -- Connection object that can be disconnected
]=]
function ServerPlayerDataManager.OnLastSave(
	self: SPDM_Internal,
	player: Player,
	callback: (profile: Profile) -> (),
	priority: number?
): Connection?
	assertPlayer(player)
	assert(
		typeof(callback) == "function",
		"[📤] Expected a function for the callback. Got Type: " .. typeof(callback)
	)

	local profile = self:GetProfile(player)
	if not profile then
		warn("[📤] Player's profile is not active.")
		return nil
	end

	return addSaveCallback(player, "OnLastSave", callback, priority or SAVE_PRIORITY.NORMAL)
end

--[=[
    Disables the default manager functionality. This prevents automatic registration
    of the default manager and requires explicit manager names for all operations.
    
    Must be called before Start() to take effect.
    
    ```lua
    SPDM:DisableDefaultManager()
    SPDM:Start(PlayerProfileManager)
    
    -- Now all operations require explicit manager names
    local settings = SPDM:GetManager(player, "Settings") -- Must specify "Settings"
    ```
]=]
function ServerPlayerDataManager.DisableDefaultManager(self: SPDM_Internal)
	assert(not STARTED, "[📤] Cannot disable default manager after the service has started.")
	self.DEFAULT_MANAGER_NAME = nil
	debugPrint("Default Manager disabled.")
end

--[=[
    Sets a custom default manager name. This allows you to change which manager
    is used as the default instead of "DEFAULT_MANAGER".
    
    Must be called before Start() to take effect.
    
    ```lua
    SPDM:SetDefaultManagerName("PlayerData")
    SPDM:Start(PlayerProfileManager)
    ```
]=]
function ServerPlayerDataManager.SetDefaultManagerName(self: SPDM_Internal, managerName: string)
	assert(not STARTED, "[📤] Cannot change default manager name after the service has started.")
	assertValidManagerName(managerName)
	self.DEFAULT_MANAGER_NAME = managerName
	debugPrint("Default Manager name set to:", managerName)
end

export type ServerPlayerDataManager = typeof(ServerPlayerDataManager)

return ServerPlayerDataManager
