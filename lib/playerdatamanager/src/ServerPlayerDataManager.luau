-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class ServerPlayerDataManager

    The Server side class for the PlayerDataManager package.

    This class now uses constructed instances so each namespace can have an
    independent manager registry, lifecycle, and replication scope.
]=]

const Players = game:GetService("Players")

--// Imports //--
const Packages = script.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)
const Promise = require(Packages.Promise)
const RailUtil = require(Packages.RailUtil)
const TableManager = require(Packages.TableManager)
const TableReplicator = require(Packages.TableReplicator)

--// Types //--
type table = { [any]: any }
type PromiseObject = typeof(Promise.new(function() end))
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
	Client: table?,
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
	ManagerReady: any,
	ManagerRegistered: any,
	PlayerDataReady: any,
	_name: string,
	_dataProvider: DataProvider,
	_playerData: { [Player]: PlayerDataEntry },
	_managerTemplates: { [string]: ManagerTemplate },
	_replicatorTokens: { [string]: any },
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
	DisableDefaultManager: (self: SPDM_Internal) -> (),
	SetDefaultManagerName: (self: SPDM_Internal, managerName: string) -> (),
	[any]: any,
}

--// Constants //--
const DEFAULT_TIMEOUT = 60

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local ServerPlayerDataManager = {}
ServerPlayerDataManager.ClassName = "ServerPlayerDataManager"
ServerPlayerDataManager.__index = ServerPlayerDataManager
ServerPlayerDataManager.DEFAULT_MANAGER_NAME = "DefaultManager"

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

local function debugPrint(self: SPDM_Internal, ...)
	if self._DEBUG then
		print("[📤 SPDM]", ...)
	end
end

--------------------------------------------------------------------------------
--// Constructors //--
--------------------------------------------------------------------------------

function ServerPlayerDataManager.new(name: string, dataProvider: DataProvider): SPDM_Internal
	assert(typeof(name) == "string" and #name > 0, "[📤] Expected a non-empty string for name.")
	assert(typeof(dataProvider) == "function", "[📤] Expected dataProvider to be a function.")

	local self = setmetatable({}, ServerPlayerDataManager) :: any
	self._name = name
	self._dataProvider = dataProvider
	self._playerData = {}
	self._managerTemplates = {}
	self._replicatorTokens = {}
	self._started = false

	self._DEBUG = false
	self.DEFAULT_MANAGER_NAME = ServerPlayerDataManager.DEFAULT_MANAGER_NAME

	self.ManagerReady = Signal.new()
	self.ManagerRegistered = Signal.new()
	self.PlayerDataReady = Signal.new()

	return self
end

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

function ServerPlayerDataManager._getToken(self: SPDM_Internal, managerName: string)
	local tokenName = `{self._name}/{managerName}`
	if not self._replicatorTokens[tokenName] then
		self._replicatorTokens[tokenName] = TableReplicator.Token(tokenName)
	end
	return self._replicatorTokens[tokenName]
end

function ServerPlayerDataManager._setupPlayerDataManagers(
	self: SPDM_Internal,
	player: Player,
	data: table
): ({ PromiseObject }, Janitor)
	debugPrint(self, "Setting up player data managers for", player)

	local jani = Janitor.new()
	local replicators = {}
	self._playerData[player] = {
		Replicators = replicators,
		AllManagersReady = false,
		ForEachJanitors = {},
	}

	local managerReadyPromises = {}
	for name, template in self._managerTemplates do
		local generateConfig = template.ConfigGenerator
		table.insert(
			managerReadyPromises,
			jani:AddPromise(Promise.new(function(resolve)
				local config = generateConfig(player, data)
				assert(typeof(config.Data) == "table", "The Data function must return a table. Failed for: " .. name)

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

				local tm = TableManager.new(config.Data)
				local tr = TableReplicator.new {
					ClassToken = self:_getToken(name),
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

				replicators[name] = tr
				self.ManagerReady:Fire(player, name, tm)
				resolve(tm)
			end))
		)
	end

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

function ServerPlayerDataManager._refreshRegisteredManagersFolder(self: SPDM_Internal)
	local rootFolder = script.Parent:FindFirstChild("RegisteredServerManagers")
	if not rootFolder then
		rootFolder = Instance.new("Folder")
		rootFolder.Name = "RegisteredServerManagers"
		rootFolder.Parent = script.Parent
	end

	local namespaceFolder = rootFolder:FindFirstChild(self._name)
	if not namespaceFolder then
		namespaceFolder = Instance.new("Folder")
		namespaceFolder.Name = self._name
		namespaceFolder.Parent = rootFolder
	end

	for _, child in ipairs(namespaceFolder:GetChildren()) do
		child:Destroy()
	end

	for name in self._managerTemplates do
		local manager = Instance.new("BoolValue")
		manager.Name = name
		manager.Parent = namespaceFolder
	end
end

--------------------------------------------------------------------------------
--// Start Method //--
--------------------------------------------------------------------------------

function ServerPlayerDataManager.Start(self: SPDM_Internal)
	if self._started then
		warn("[📤] ServerPlayerDataManager has already started. Do not call Start multiple times.")
		return
	end

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

	RailUtil.Player.forEachPlayer(function(plr: Player, jani: Janitor)
		jani:AddPromise(self._dataProvider(plr):andThen(function(resolvedData: table)
			assert(typeof(resolvedData) == "table", "[📤] dataProvider must resolve a table.")

			local readyPromises, cleanup = self:_setupPlayerDataManagers(plr, resolvedData)
			jani:Add(cleanup)

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

	self:_refreshRegisteredManagersFolder()
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

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

function ServerPlayerDataManager.PromiseManager(self: SPDM_Internal, player: Player, managerName: string?): PromiseObject
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

	return Promise.fromEvent(self.ManagerReady, function(readiedPlayer: Player, readiedManager: string)
		return readiedPlayer == player and readiedManager == managerName
	end):andThen(function()
		return self:GetManager(player, managerName)
	end)
end

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

function ServerPlayerDataManager.IsManagerRegistered(self: SPDM_Internal, managerName: string?): boolean
	managerName = managerName or self.DEFAULT_MANAGER_NAME
	if not managerName then
		return false
	end
	assertValidManagerName(managerName)
	return self._managerTemplates[managerName] ~= nil
end

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

function ServerPlayerDataManager.IsPlayerReady(self: SPDM_Internal, player: Player): boolean
	assertPlayer(player)
	local entry = self._playerData[player]
	return entry ~= nil and entry.AllManagersReady
end

function ServerPlayerDataManager.OnPlayerReady(self: SPDM_Internal, player: Player): PromiseObject
	assertPlayer(player)
	if self:IsPlayerReady(player) then
		return Promise.resolve()
	end
	return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
		return readiedPlayer == player
	end):timeout(DEFAULT_TIMEOUT, `[📤] PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end

function ServerPlayerDataManager.ForEachPlayer(
	self: SPDM_Internal,
	func: (player: Player, janitor: Janitor) -> ()
): Connection
	assert(typeof(func) == "function", "[📤] Expected a function for the first argument. Got Type: " .. typeof(func))
	return RailUtil.Player.forEachPlayer(function(player: Player, jani: Janitor)
		if not self:IsPlayerReady(player) then
			jani:AddPromise(self:OnPlayerReady(player)):await()
		end

		if self:IsPlayerReady(player) then
			local callbackJani = Janitor.new()
			jani:Add(function()
				callbackJani:Destroy()
			end)

			local entry = self._playerData[player]
			if entry then
				table.insert(entry.ForEachJanitors, callbackJani)
			end

			task.spawn(func, player, callbackJani)
		end
	end)
end

function ServerPlayerDataManager.IsStarted(self: SPDM_Internal): boolean
	return self._started
end

function ServerPlayerDataManager.DisableDefaultManager(self: SPDM_Internal)
	assert(not self._started, "[📤] Cannot disable default manager after the service has started.")
	self.DEFAULT_MANAGER_NAME = nil
	debugPrint(self, "Default Manager disabled.")
end

function ServerPlayerDataManager.SetDefaultManagerName(self: SPDM_Internal, managerName: string)
	assert(not self._started, "[📤] Cannot change default manager name after the service has started.")
	assertValidManagerName(managerName)
	self.DEFAULT_MANAGER_NAME = managerName
	debugPrint(self, "Default Manager name set to:", managerName)
end

export type ServerPlayerDataManager = typeof(ServerPlayerDataManager)

return ServerPlayerDataManager