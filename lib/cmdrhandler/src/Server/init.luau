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
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

--// Imports //--
local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)
local NetWire = require(Packages.NetWire)
local Cmdr = require(script["Cmdr-1.12.0"])
local Util = require(script.Parent.Shared.CmdrUtil)
local CmdrTypes = require(script.Parent.Shared.CmdrTypes)

local Templates = script.Templates

--// Types //--
type table = {[any]: any}
type Promise = typeof(Promise.new())
type CommandDefinition<T> = CmdrTypes.CommandDefinition<T>
type CommandContext<T> = CmdrTypes.CommandContext<T>
type TypeDefinition<T> = CmdrTypes.TypeDefinition<T>

local cmdrReadied = Signal.new()
local cmdrProm = Promise.fromEvent(cmdrReadied)

local DefaultAdmins = {5519161} -- used for testing

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local CmdrServer = {}
CmdrServer.Name = "CmdrServer"
CmdrServer.Client = {
    Permissions = NetWire.createProperty({}),
	PermissionInheritance = NetWire.createProperty({
		DefaultAdmin = {"DefaultDebug", "DefaultUtility", "Help"},
		Admin = {"DefaultAdmin"},
		Tester = {"DefaultDebug", "DefaultUtility", "Help"},
	}),
	GroupPerms = NetWire.createProperty({}),  -- storage for roblox group permissions

	ExecuteCommand = NetWire.createEvent(),
}

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
		Group = "DefaultAdmin"; -- The permission group required to run this command
		Args = {
			{
				Type = "players";
				Name = "victims";
				Description = "The players to kill.";
			},
		};

		-- Executors
		ClientRun = nil, -- No client side needed
		ServerRun = function (_, players)
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
	return self:PromiseCmdr():andThen(function(cmdr)
		local commandData = require(module)
		local commandId = ("%s___[%s]"):format(commandData.Name, HttpService:GenerateGUID(false))

		self._definitionData[commandId] = commandData
		self._executeData[commandId] = commandData.ServerRun or function() end
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
	Executes a command with Cmdr from the server
	@return Promise<string>
	```lua
	CmdrServer:ExecuteCommand("kill Raildex"):andThen(function(result)
		print(result)
	end)
	```
]=]
function CmdrServer:ExecuteCommand(commandText: string, executor: Player?, options: {Data: any?, IsHuman: boolean}?): Promise
    assert(type(commandText) == "string", "Bad commandId")
	return self:PromiseCmdr():andThen(function(cmdr)
		return cmdr.Dispatcher:EvaluateAndRun(commandText, executor, options)
	end)
end

--[=[
	Executes a command with Cmdr as if it were run by a client
	```lua
	CmdrServer:ExecuteCommandAsClient(Players.Raildex, "kill", "*")
	CmdrServer:ExecuteCommandAsClient(Players.Raildex, "kill *")
	```
]=]
function CmdrServer:ExecuteCommandAsClient(executor: Player, ...: string)
	self.Client.ExecuteCommand:Fire(executor, ...)
end

--[=[
	Checks if a player has permission to run a command
	@param plr -- The player to check
	@param commandName -- The name of the command to check
]=]
function CmdrServer:HasPermission(plr: Player, commandName: string): boolean
	if not self._Cmdr then
		return false
	end

	local commandData = self._Cmdr.Registry:GetCommand(commandName) :: CommandDefinition<any>
	if not commandData then
		return false
	end

	local permissions = self:GetPermissions(plr)
	if table.find(permissions, commandData.Group) or table.find(permissions, "Creator") then
		return true
	end
	
	return false
end

--[=[
	Gets the permissions for a player
]=]
function CmdrServer:GetPermissions(plr: Player): {any}
	local permissions = self.Client.Permissions:GetFor(plr) or {}
	return Util.getPlayerPermissions(self, plr, permissions)
end

--[=[
	Sets the direct permissions for a player.
	Does not override inherited permissions or group permissions.
	```lua
	CmdrServer:SetPermissions(Players.Raildex, "Admin")
	```
	:::info
	The 'Creator' permission grants all permissions regardless of group inheritance.
	:::
]=]
function CmdrServer:SetPermissions(plr: Player, permissions: string | {string})
    if typeof(permissions) == "string" then
        permissions = {permissions}
    end
    CmdrServer.Client.Permissions:SetFor(plr, permissions)
end

--[=[
	Grants a player a permission group(s). Adds the given permissions to the player's current permissions.
	@param plr -- The player to grant permissions to
	@param permissions -- The permissions to grant
	```lua
	CmdrServer:GivePermissions(Players.Raildex, "Admin")
	```
]=]
function CmdrServer:GivePermissions(plr: Player, permissions: string | {string})
	if typeof(permissions) == "string" then
		permissions = {permissions}
	end
	local currentPermissions = self.Client.Permissions:GetFor(plr) or {}
	for _, permission: string in permissions :: any do
		if not table.find(currentPermissions, permission) then
			table.insert(currentPermissions, permission)
		end
	end
	self.Client.Permissions:SetFor(plr, currentPermissions)
end


--[=[
	Gets the permissions granted to a particular rank in a group.
	@param groupId -- The Roblox group id to get permissions for
	@param rank -- The rank to get permissions for
	@return {string} -- The permissions granted to the rank
	```lua
	local permissions = CmdrServer:GetGroupRankPermissions(15905255, 230)
	```
]=]
function CmdrServer:GetGroupRankPermissions(groupId: number, rank: number): {string}
	return Util.GetGroupRankPermissions(self, groupId, rank)
end

--[=[
	Grants a Roblox group permissions to run a command. Takes the ranks to apply the permissions to, and the permissions to grant.
	@param groupId -- The Roblox group id to grant permissions to
	@param ranks -- The ranks to apply the permissions to. Can be a single rank or a range of ranks.
	@param permissions -- The permissions to grant to the group
	@return function -- A function that can be called to remove the permissions
	```lua
	local revoke = CmdrServer:GiveGroupPermissions(15905255, 230, "Admin")
	```
]=]
function CmdrServer:GiveGroupPermissions(groupId: number, ranks: number | NumberRange, permissions: string | {string})
	assert(typeof(groupId) == "number", "Bad groupId")
	assert(typeof(ranks) == "number" or typeof(ranks) == "NumberRange", "Bad ranks")
	assert(typeof(permissions) == "string" or typeof(permissions) == "table", "Bad permissions")

	local GroupPerms = self.Client.GroupPerms:Get()
	local groupPermData = GroupPerms[groupId]
	if not groupPermData then
		groupPermData = {}
		GroupPerms[groupId] = groupPermData
	end

	if typeof(ranks) == "number" then
		ranks = NumberRange.new(ranks, ranks)
	end

	if typeof(permissions) == "string" then
		permissions = {permissions}
	end

	local rankPermData = {
		Ranks = ranks,
		Permissions = permissions
	}
	table.insert(groupPermData, rankPermData)
	self.Client.GroupPerms:Set(GroupPerms)

	if RunService:IsStudio() then
		print(`[CmdrServer] - Granted group [{groupId}] permissions [{table.concat(permissions :: any, ", ")}] for ranks [{(ranks :: NumberRange).Min}, {(ranks :: NumberRange).Max}]`)
	end

	return function()
		table.remove(groupPermData, table.find(groupPermData, rankPermData))
		self.Client.GroupPerms:Set(GroupPerms)
	end
end

--[=[
	Sets the permission inheritance for a permission group.
	This will override any previous inheritance.
	@param permissionGroup -- The permission group to set the inheritance for
	@param inheritedGroups -- The groups to inherit permissions from
	@return nil
	```lua
	CmdrServer:SetPermissionInheritance("Admin", "DefaultAdmin")
	CmdrServer:SetPermissionInheritance("Admin", {"DefaultAdmin", "Moderator"})
	```
]=]
function CmdrServer:SetPermissionInheritance(permissionGroup: string, inheritedGroups: string | {string})
	assert(typeof(permissionGroup) == "string", "Bad permissionGroup")
	if typeof(inheritedGroups) == "string" then
		inheritedGroups = {inheritedGroups}
	end
	local inheritanceDict = self.Client.PermissionInheritance:Get()
	inheritanceDict[permissionGroup] = inheritedGroups
	self.Client.PermissionInheritance:Set(inheritanceDict)
end

--[=[
	Fetches the inherited permission group for a permission group
]=]
function CmdrServer:GetPermissionInheritance(permissionGroup: string): {string}
	local inheritanceDict = self.Client.PermissionInheritance:Get()
	return inheritanceDict[permissionGroup] or {}
end


--[=[
	Registers a type with Cmdr
	@param name -- The name of the type
	@param typeData -- The type data to register
]=]
function CmdrServer:RegisterType<T>(name: string, typeData: TypeDefinition<T>): Promise
    return self:PromiseCmdr():andThen(function(cmdr)
		cmdr.Registry:RegisterType(name, typeData)
	end)
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
function CmdrServer:RegisterCommand<T>(commandData: CommandDefinition<T>, commandServerExecutor: ((context: table, ...any) -> ())?)
    assert(commandData, "No commandData")
	assert(commandData.Name, "No commandData.Name")

	commandServerExecutor = commandServerExecutor or function() end
	assert(commandServerExecutor, "No server executor")

	local commandId = ("%s_%s"):format(commandData.Name, HttpService:GenerateGUID(false))

	self._definitionData[commandId] = commandData
	self._executeData[commandId] = commandServerExecutor

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

	self:PromiseCmdr():andThen(function(cmdr)
		cmdr.Registry:RegisterCommand(commandScript, commandServerScript)
	end)
end



--[=[
	Private function used by the execution template to retrieve the execution function.
	@param cmdrCommandId string
	@param ... any
	@private
]=]
function CmdrServer:__executeCommand(cmdrCommandId, ...)
	assert(type(cmdrCommandId) == "string", "Bad cmdrCommandId")
	assert(self._Cmdr, "CmdrServer is not initialized yet")

	local execute = self._executeData[cmdrCommandId]
	if not execute then
		error(("[CmdrServer] - No command definition for cmdrCommandId %q"):format(tostring(cmdrCommandId)))
	end

	return execute(...)
end

--[=[
	@private
]=]
function CmdrServer:_getRawGroupPerms(groupId: number): {string}
	local groupSets = (self.Client.GroupPerms:Get() or {})
	return groupSets[groupId] or groupSets[tostring(groupId)] or {}
end

--------------------------------------------------------------------------------
    --// Service Core //--
--------------------------------------------------------------------------------

-- Initialize properties of the service
function CmdrServer:Init()
	NetWire.Server.setupServiceNetworking(self)

    self._definitionData = {}
    self._executeData = {}
    self._Cmdr = Cmdr
    cmdrReadied:Fire(Cmdr)

    self:PromiseCmdr():andThen(function(cmdr)
        task.spawn(function()
            cmdr.Registry:RegisterDefaultCommands()

			for _, commandModule in script:FindFirstChild("BuiltInCommands"):GetDescendants() do
				if commandModule:IsA("ModuleScript") then
					self:RegisterCommandFromModule(commandModule)
        		end
			end
        end)

        cmdr.Registry:RegisterHook("BeforeRun", function(context: CommandContext<any>)
			-- allow!
			if context.Executor == nil then
				return nil
			end

			local HasPermission = self:HasPermission(context.Executor, context.Name)
			if not HasPermission then
				return "[Server] You do not have permission to run this command."
			end

            return nil
		end)
    end)

	Players.PlayerAdded:Connect(function(player)
		if table.find(DefaultAdmins, player.UserId) then
			self:GivePermissions(player, "Creator")
		end
	end)
end

--------------------------------------------------------------------------------
    --// Registration and Return //--
--------------------------------------------------------------------------------

return CmdrServer