-- Authors: Logan Hunt (Raildex)
-- May 01, 2024
--[=[
	@class CmdrClient
	@client

	This is a wrapper client for Evaera's Cmdr module (https://eryn.io/Cmdr/).
	It provides an easier way to interact with Cmdr and autoboots with Roam's
	systems.
]=]

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent

local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local NetWire = require(Packages.NetWire)

local CmdrTypes = require(script.Parent.Shared.CmdrTypes)

--// Types //--
type Cmdr = any
type Promise = typeof(Promise.new())
type CommandDefinition = CmdrTypes.CommandDefinition
type CommandContext = CmdrTypes.CommandContext
type TypeDefinition = CmdrTypes.TypeDefinition

--// Constants //--
local LocalPlayer = Players.LocalPlayer

--// Volatiles //--
local cmdrReadied = Signal.new()
local cmdrProm = Promise.fromEvent(cmdrReadied)
local cmdrInstance: Cmdr? = nil

local PermissionsHandler = require(script.Parent.Shared.PermissionsHandler)
local bindingsJanitor = Janitor.new()

--------------------------------------------------------------------------------
--// Client //--
--------------------------------------------------------------------------------

local CmdrClient = {}
CmdrClient.ClassName = "CmdrClient"

--[=[
	@within CmdrClient
	@prop PermissionsHandler PermissionsHandler
]=]
CmdrClient.PermissionsHandler = PermissionsHandler

--[=[
	Returns a promise that resolves with the Cmdr instance.
	https://eryn.io/Cmdr/api/CmdrClient.html
	return Promise<Cmdr>
]=]
function CmdrClient:PromiseCmdr(): Promise
	return cmdrProm
end

--[=[
	Checks if a player has permission to run a command
	@param commandName -- The name of the command to check
]=]
function CmdrClient:HasPermission(commandName: string): boolean
	return CmdrClient.PermissionsHandler:PlayerHasPermissionForCommand(LocalPlayer, commandName)
end

--[=[
	Executes a command
	@return Promise<string>
	```lua
	CmdrClient:ExecuteCommand("blink")
	```
]=]
function CmdrClient:ExecuteCommand(...: string): Promise
	local args = { ... }
	return CmdrClient:PromiseCmdr():andThen(function(cmdr)
		return cmdr.Dispatcher:Run(table.unpack(args))
	end)
end

--[=[
	Checks if a command exists in the registry
	@param commandName -- The name of the command to check
	@return boolean -- Whether the command exists
]=]
function CmdrClient:CommandExists(commandName: string): boolean
	if not cmdrInstance then
		return false
	end

	local command = cmdrInstance.Registry:GetCommand(commandName)
	return command ~= nil
end

--[=[
	Gets information about a specific command
	@param commandName -- The name of the command to get info for
	@return CommandDefinition? -- The command data, or nil if not found
]=]
function CmdrClient:GetCommandInfo(commandName: string): CommandDefinition?
	if not cmdrInstance then
		return nil
	end

	return cmdrInstance.Registry:GetCommand(commandName)
end

--[=[
	Gets all commands available to the local player
	@return {string} -- Array of command names the player can use
]=]
function CmdrClient:GetAvailableCommands(): { string }
	if not cmdrInstance then
		return {}
	end

	local availableCommands = {}
	local permissions = CmdrClient.PermissionsHandler:GetPlayerPermissionGroups(LocalPlayer)

	for _, command in cmdrInstance.Registry:GetCommands() do
		if table.find(permissions, command.Group) or table.find(permissions, "Creator") then
			table.insert(availableCommands, command.Name)
		end
	end

	return availableCommands
end

--[=[
	Gets all registered commands
	@return {CommandDefinition} -- Array of all registered commands
]=]
function CmdrClient:GetAllCommands(): { CommandDefinition }
	if not cmdrInstance then
		return {}
	end

	return cmdrInstance.Registry:GetCommands()
end

--------------------------------------------------------------------------------
--// Client Core //--
--------------------------------------------------------------------------------

--[=[
	@private
	Sets up the default bindings for Cmdr
]=]
function CmdrClient:_setBindings(cmdr: Cmdr)
	cmdr:SetActivationUnlocksMouse(true)
	cmdr:SetActivationKeys { Enum.KeyCode.F2 }

	-- enable activation on mobile
	bindingsJanitor:Add(
		Players.LocalPlayer.Chatted:Connect(function(chat)
			-- check if the chat string starts with "/cmdr"
			local keyword = "/cmdr"
			if chat:sub(1, #keyword):lower() == keyword then
				cmdr:Show()
			end
		end),
		nil,
		"ChatBind"
	)

	-- Race condition
	-- task.defer(function()
	-- 	-- Default blink for debugging purposes
	-- 	cmdr.Dispatcher:Run("bind", Enum.KeyCode.G.Name, "blink")
	--	end)
end

--[=[
	Initializes the Cmdr Client
]=]
function CmdrClient:Init()
	local Server = NetWire.Client("CmdrServer")

	-- Set up PermissionsHandler data syncing from server
	Server.PermissionInheritance:Observe(function(newValue)
		CmdrClient.PermissionsHandler:_setPermissionInheritanceData(newValue)
	end)

	Server.GroupRankPermissionGroups:Observe(function(newValue)
		CmdrClient.PermissionsHandler:_setGroupRankPermissionGroupsData(newValue)
	end)

	Server.GroupRolePermissionGroups:Observe(function(newValue)
		CmdrClient.PermissionsHandler:_setGroupRolePermissionGroupsData(newValue)
	end)

	Server.Permissions:Observe(function(newValue)
		local playerData = {}
		if newValue then
			playerData[LocalPlayer] = newValue
		end
		CmdrClient.PermissionsHandler:_setPlayerPermissionGroupsData(playerData)
	end)

	task.spawn(function()
		cmdrInstance = require(ReplicatedStorage:WaitForChild("CmdrClient") :: any)
		CmdrClient._Cmdr = cmdrInstance

		-- Set up PermissionsHandler with Cmdr registry
		CmdrClient.PermissionsHandler:SetCmdrRegistry(cmdrInstance.Registry)
		CmdrClient:_setBindings(cmdrInstance)

		cmdrReadied:Fire(cmdrInstance)
	end)

	CmdrClient:PromiseCmdr():andThen(function(cmdr)
		cmdr.Registry:RegisterHook("BeforeRun", function(context: CommandContext)
			-- allow!
			if context.Executor == nil then
				return nil
			end

			local HasPermission = CmdrClient:HasPermission(context.Name)
			if not HasPermission then
				return "[Client] You do not have permission to run this command."
			end

			return nil
		end)
	end)
end

--------------------------------------------------------------------------------
--// Registration and Return //--
--------------------------------------------------------------------------------

return CmdrClient
