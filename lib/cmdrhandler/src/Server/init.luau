-- Authors: Logan Hunt (Raildex)
-- May 01, 2024
--[=[
	@class CmdrServer
	@server

	This is a wrapper service for Evaera's Cmdr module (https://eryn.io/Cmdr/).
	It provides an easier way to interact with Cmdr and autoboots with Roam's
	systems.
]=]

--// Services //--
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

--// Imports //--
local Packages = script.Parent.Parent

local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)
local NetWire = require(Packages.NetWire)

local Cmdr = require(script["Cmdr-1.12.0"])
local CmdrTypes = require(script.Parent.Shared.CmdrTypes)

local Templates = script.Templates

--// Types //--
type table = { [any]: any }
type Promise = typeof(Promise.new())
type CommandDefinition = CmdrTypes.CommandDefinition
type CommandContext = CmdrTypes.CommandContext
type TypeDefinition = CmdrTypes.TypeDefinition

local cmdrReadied = Signal.new()
local cmdrProm = Promise.fromEvent(cmdrReadied)

local DefaultAdmins = { 5519161 } -- used for testing

local definitionData: { [string]: CommandDefinition } = {}
local executeData: { [string]: (context: table, ...any) -> any } = {}

local PermissionsHandler = require(script.Parent.Shared.PermissionsHandler)

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local CmdrServer = {}
CmdrServer.ClassName = "CmdrServer"

--[=[
	@within CmdrServer
	@prop PermissionsHandler PermissionsHandler
]=]
CmdrServer.PermissionsHandler = PermissionsHandler

--[=[
	Promise that resolves to the Cmdr module data
	@return Promise<Cmdr>
]=]
function CmdrServer:PromiseCmdr(): Promise
	return cmdrProm
end

--[=[
	Registers a command from a module with Cmdr. Command modules must return a table of type `CommandModuleData`.
	@param module -- The module to register the command from
	@return Promise<nil>
	```lua
	-- Commands/Kill.lua
	return {
		Name = "kill";
		Aliases = {"slay"};
		Description = "Kills a player or set of players.";
		Group = "Admin"; -- The permission group required to run this command
		Args = {
			{
				Type = "players";
				Name = "victims";
				Description = "The players to kill.";
			},
		};

		-- Executors
		ClientRun = nil, -- No client side needed
		ServerRun = function (context: CommandContext, players: {Player})
			for _, player in pairs(players) do
				if player.Character then
					player.Character:BreakJoints()
				end
			end
			return ("Killed %d players."):format(#players)
		end
	}
	```
	```lua
	CmdrServer:RegisterCommandFromModule(script.Parent.Commands.Kill)
	```
]=]
function CmdrServer:RegisterCommandFromModule(module: ModuleScript)
	return CmdrServer:PromiseCmdr():andThen(function(cmdr)
		local commandData = require(module)
		local commandId = ("%s___[%s]"):format(commandData.Name, HttpService:GenerateGUID(false))

		definitionData[commandId] = commandData
		executeData[commandId] = commandData.ServerRun or function() end
		commandData.ServerRun = nil

		local commandServerScript = Templates.CmdrExecutionTemplate:Clone()
		commandServerScript.Name = ("%sServer"):format(commandId)

		local cmdrServiceTarget = Instance.new("ObjectValue")
		cmdrServiceTarget.Name = "CmdrServerTarget"
		cmdrServiceTarget.Value = script
		cmdrServiceTarget.Parent = commandServerScript

		local cmdrCommandId = Instance.new("StringValue")
		cmdrCommandId.Name = "CmdrCommandId"
		cmdrCommandId.Value = commandId
		cmdrCommandId.Parent = commandServerScript

		cmdr.Registry:RegisterCommand(module, commandServerScript)
	end)
end

--[=[
	Executes a command with Cmdr from the server. Requires a player to be given as a source of the command.
	If `Data` is given, it will be available on the server with `CommandContext.GetData`

	```lua
	local result = CmdrServer:ExecuteCommand("kill Mophyr", Players.Raildex)
	```
]=]
function CmdrServer:ExecuteCommand(commandText: string, executor: Player, options: { Data: any?, IsHuman: boolean }?)
	assert(typeof(executor) == "Instance", "Bad executor")
	assert(executor:IsA("Player"), "Bad executor")
	assert(type(commandText) == "string", "Bad commandText")
	return Cmdr.Dispatcher:EvaluateAndRun(commandText, executor, options)
end

--[=[
	Registers a type with Cmdr
	@param name -- The name of the type
	@param typeData -- The type data to register
]=]
function CmdrServer:RegisterType(name: string, typeData: TypeDefinition)
	return Cmdr.Registry:RegisterType(name, typeData)
end

--[=[
	@private
	@unreleased
	This method is deprecated
	Registers a command with Cmdr. This method does not support client-side execution.
	Originally ported from Quenty's wrapper for Cmdr.
	@param commandData -- The command data to register
	@param commandServerExecutor -- The server function to execute when the command is run
]=]
function CmdrServer:RegisterCommand(
	commandData: CommandDefinition,
	commandServerExecutor: ((context: table, ...any) -> ())?
)
	assert(commandData, "No commandData")
	assert(commandData.Name, "No commandData.Name")

	commandServerExecutor = commandServerExecutor or function() end
	assert(commandServerExecutor, "No server executor")

	local commandId = ("%s_%s"):format(commandData.Name, HttpService:GenerateGUID(false))

	definitionData[commandId] = commandData
	executeData[commandId] = commandServerExecutor

	local commandServerScript = Templates.CmdrExecutionTemplate:Clone()
	commandServerScript.Name = ("%sServer"):format(commandId)

	local cmdrServiceTarget = Instance.new("ObjectValue")
	cmdrServiceTarget.Name = "CmdrServerTarget"
	cmdrServiceTarget.Value = script
	cmdrServiceTarget.Parent = commandServerScript

	local cmdrCommandId = Instance.new("StringValue")
	cmdrCommandId.Name = "CmdrCommandId"
	cmdrCommandId.Value = commandId
	cmdrCommandId.Parent = commandServerScript

	local commandScript = Templates.CmdrCommandDefinitionTemplate:Clone()
	commandScript.Name = commandId

	local cmdrJsonCommandData = Instance.new("StringValue")
	cmdrJsonCommandData.Value = HttpService:JSONEncode(commandData)
	cmdrJsonCommandData.Name = "CmdrJsonCommandData"
	cmdrJsonCommandData.Parent = commandScript

	Cmdr.Registry:RegisterCommand(commandScript, commandServerScript)
end

--[=[
	Gets all commands available to a specific player
	@param player -- The player to get commands for
	@return {string} -- Array of command names the player can use
]=]
function CmdrServer:GetAvailableCommandsForPlayer(player: Player): { string }
	local availableCommands = {}
	local permissions = CmdrServer.PermissionsHandler:GetPlayerPermissionGroups(player)

	for _, command in Cmdr.Registry:GetCommands() do
		if table.find(permissions, command.Group) or table.find(permissions, "Creator") then
			table.insert(availableCommands, command.Name)
		end
	end

	return availableCommands
end

--[=[
	Gets information about a specific command
	@param commandName -- The name of the command to get info for
	@return CommandDefinition? -- The command data, or nil if not found
]=]
function CmdrServer:GetCommandInfo(commandName: string): CommandDefinition?
	return Cmdr.Registry:GetCommand(commandName)
end

--[=[
	Gets all registered commands
	@return {CommandDefinition} -- Array of all registered commands
]=]
function CmdrServer:GetAllCommands(): { CommandDefinition }
	return Cmdr.Registry:GetCommands()
end

--[=[
	Checks if a command exists in the registry
	@param commandName -- The name of the command to check
	@return boolean -- Whether the command exists
]=]
function CmdrServer:CommandExists(commandName: string): boolean
	local command = Cmdr.Registry:GetCommand(commandName)
	return command ~= nil
end

--------------------------------------------------------------------------------
--// Internal Methods //--
--------------------------------------------------------------------------------

--[=[
	Private function used by the execution template to retrieve the execution function.
	@param cmdrCommandId string
	@param ... any
	@private
]=]
function CmdrServer:__executeCommand(cmdrCommandId, ...)
	assert(type(cmdrCommandId) == "string", "Bad cmdrCommandId")
	assert(self._Cmdr, "CmdrServer is not initialized yet")

	local execute = executeData[cmdrCommandId]
	if not execute then
		error(("[CmdrServer] - No command definition for cmdrCommandId %q"):format(tostring(cmdrCommandId)))
	end

	return execute(...)
end

--[=[
	@private
]=]
function CmdrServer:_getRawGroupPerms(groupId: number): { string }
	local groupSets = CmdrServer.PermissionsHandler:_getGroupRankPermissionGroupsData()
	return groupSets[groupId] or groupSets[tostring(groupId)] or {}
end

--------------------------------------------------------------------------------
--// Service Core //--
--------------------------------------------------------------------------------

--[=[
	Starts Cmdr on the Server
]=]
function CmdrServer:Init()
	-- Set up PermissionsHandler with Cmdr registry
	CmdrServer.PermissionsHandler:SetCmdrRegistry(Cmdr.Registry)

	local Client = NetWire.Server("CmdrServer")
	Client.Permissions = NetWire.createProperty(nil) -- per-player permissions
	Client.PermissionInheritance = NetWire.createProperty {} -- shared permission inheritance
	Client.GroupRankPermissionGroups = NetWire.createProperty {} -- shared group rank permissions
	Client.GroupRolePermissionGroups = NetWire.createProperty {} -- shared group role permissions

	Players.PlayerAdded:Connect(function(player)
		if table.find(DefaultAdmins, player.UserId) then
			CmdrServer.PermissionsHandler:GivePlayerPermissionGroups(player, "Creator")
		end

		-- Sync initial player permissions to client
		local playerPerms = CmdrServer.PermissionsHandler:_getPlayerPermissionGroupsData()[player]
		Client.Permissions:SetFor(player, playerPerms)
	end)

	-- Listen to PermissionsHandler changes and sync to clients
	CmdrServer.PermissionsHandler.PermissionInheritanceChanged:Connect(function(newValue)
		Client.PermissionInheritance:Set(newValue)
	end)

	CmdrServer.PermissionsHandler.GroupRankPermissionGroupsChanged:Connect(function(newValue)
		Client.GroupRankPermissionGroups:Set(newValue)
	end)

	CmdrServer.PermissionsHandler.GroupRolePermissionGroupsChanged:Connect(function(newValue)
		Client.GroupRolePermissionGroups:Set(newValue)
	end)

	CmdrServer.PermissionsHandler.PlayerPermissionGroupsChanged:Connect(function(player, newValue)
		Client.Permissions:SetFor(player, newValue)
	end)

	-- Initialize shared data on clients
	Client.PermissionInheritance:Set(CmdrServer.PermissionsHandler:_getPermissionInheritanceData())
	Client.GroupRankPermissionGroups:Set(CmdrServer.PermissionsHandler:_getGroupRankPermissionGroupsData())
	Client.GroupRolePermissionGroups:Set(CmdrServer.PermissionsHandler:_getGroupRolePermissionGroupsData())

	task.spawn(function()
		Cmdr.Registry:RegisterDefaultCommands()

		for _, commandModule in script:FindFirstChild("BuiltInCommands"):GetDescendants() do
			if commandModule:IsA("ModuleScript") then
				CmdrServer:RegisterCommandFromModule(commandModule)
			end
		end
	end)

	Cmdr.Registry:RegisterHook("BeforeRun", function(context: CommandContext)
		-- allow!
		if context.Executor == nil then
			return nil
		end

		local HasPermission =
			CmdrServer.PermissionsHandler:PlayerHasPermissionForCommand(context.Executor, context.Name)
		if not HasPermission then
			return "[Server] You do not have permission to run this command."
		end

		return nil
	end)

	self._Cmdr = Cmdr
	cmdrReadied:Fire(Cmdr)
end

--------------------------------------------------------------------------------
--// Registration and Return //--
--------------------------------------------------------------------------------

return CmdrServer
