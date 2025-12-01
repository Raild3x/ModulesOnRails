-- Authors: Logan Hunt (Raildex)
-- February 26, 2025
--[=[
    @class PermissionsHandler
    @shared
    
    Shared permissions handler that works on both client and server.
    The actual data storage and networking is handled by the respective
    CmdrServer and CmdrClient implementations.
]=]

--// Roblox Services //--
local RunService = game:GetService("RunService")
--// Imports //--
local Util = require(script.Parent.CmdrUtil)
local CmdrTypes = require(script.Parent.CmdrTypes)

type CommandDefinition = CmdrTypes.CommandDefinition
type CommandContext = CmdrTypes.CommandContext
type TypeDefinition = CmdrTypes.TypeDefinition

local Packages = script.Parent.Parent.Parent
local Signal = require(Packages.Signal)

--------------------------------------------------------------------------------
    --// Shared Handler //--
--------------------------------------------------------------------------------

local PermissionsHandler = {}
PermissionsHandler.ClassName = "PermissionsHandler"

-- Events for data changes
PermissionsHandler.PermissionInheritanceChanged = Signal.new()
PermissionsHandler.PlayerPermissionGroupsChanged = Signal.new()
PermissionsHandler.GroupRankPermissionGroupsChanged = Signal.new()
PermissionsHandler.GroupRolePermissionGroupsChanged = Signal.new()

-- Data storage (will be managed by client/server implementations)
local _permissionInheritance = {
	DefaultAdmin = {"DefaultDebug", "DefaultUtility", "Help"},
	Admin = {"DefaultAdmin"},
	Tester = {"DefaultDebug", "DefaultUtility", "Help"},
}
local _playerPermissionGroups: {[Player]: {string}} = {}
local _groupRankPermissionGroups: {[number]: {{Ranks: NumberRange, Permissions: {string}}}} = {}
local _groupRolePermissionGroups: {[number]: {[string]: {string}}} = {}

-- Reference to the Cmdr registry (will be set by server/client)
local _cmdrRegistry = nil

--[=[
	Sets the Cmdr registry reference for command lookups
	@param registry -- The Cmdr registry instance
]=]
function PermissionsHandler:SetCmdrRegistry(registry)
	_cmdrRegistry = registry
end

--[=[
	Checks if a player has permission to run a command
	@param plr -- The player to check permissions for
	@param commandName -- The name of the command to check
	@return boolean -- Whether the player has permission
]=]
function PermissionsHandler:PlayerHasPermissionForCommand(plr: Player, commandName: string): boolean
	if not _cmdrRegistry then
		warn("PermissionsHandler: Cmdr registry not set!")
		return false
	end
	
	local commandData = _cmdrRegistry:GetCommand(commandName) :: CommandDefinition
	if not commandData then
		return false
	end

	local permissions = PermissionsHandler:GetPlayerPermissionGroups(plr)
	if table.find(permissions, commandData.Group) or table.find(permissions, "Creator") then
		return true
	end
	
	return false
end

--[=[
	Gets the permission groups for a player
	@param plr -- The player to get permissions for
	@return {string} -- Array of permission group names
]=]
function PermissionsHandler:GetPlayerPermissionGroups(plr: Player): {string}
	local permissions = _playerPermissionGroups[plr] or {}
	return Util.getPlayerPermissions(PermissionsHandler, plr, permissions)
end

--[=[
	Sets the direct permissions for a player.
	Does not override inherited permissions or group permissions.
	@param plr -- The player to set permissions for
	@param permissions -- The permission group(s) to set
]=]
function PermissionsHandler:SetPlayerPermissionGroups(plr: Player, permissions: string | {string})
    if typeof(permissions) == "string" then
        permissions = {permissions}
    end
    _playerPermissionGroups[plr] = permissions :: {string}
    PermissionsHandler.PlayerPermissionGroupsChanged:Fire(plr, permissions)
end

--[=[
	Grants a player permission group(s). Adds the given permissions to the player's current permissions.
	@param plr -- The player to grant permissions to
	@param permissionGroups -- The permission groups to grant
]=]
function PermissionsHandler:GivePlayerPermissionGroups(plr: Player, permissionGroups: string | {string})
	if typeof(permissionGroups) == "string" then
		permissionGroups = {permissionGroups}
	end
	assert(typeof(permissionGroups) == "table", "Bad permissionGroups")
	local currentPermissions = _playerPermissionGroups[plr] or {}
	for _, permission: string in permissionGroups do
		if not table.find(currentPermissions, permission) then
			table.insert(currentPermissions, permission)
		end
	end
	PermissionsHandler:SetPlayerPermissionGroups(plr, currentPermissions)
end

--[=[
	Gets the permissions granted to a particular rank in a group.
	@param groupId -- The Roblox group id to get permissions for
	@param rank -- The rank to get permissions for
	@return {string} -- The permission groups granted to the rank
]=]
function PermissionsHandler:GetRobloxGroupRankPermissionGroups(groupId: number, rank: number): {string}
	return Util.getGroupRankPermissions(PermissionsHandler, groupId, rank)
end

--[=[
	Grants specified ranks in a Roblox Group permission to use the commands under a given PermissionGroup.
	@param groupId -- The Roblox group id to grant permissions to
	@param ranks -- The ranks to apply the permissions to. Can be a single rank or a range of ranks.
	@param permissionGroups -- The permissions to grant to the group
	@return function -- A function that can be called to remove the permissions
]=]
function PermissionsHandler:GiveRobloxGroupRankPermissionGroups(groupId: number, ranks: number | NumberRange, permissionGroups: string | {string})
	assert(typeof(groupId) == "number", "Bad groupId")
	assert(typeof(ranks) == "number" or typeof(ranks) == "NumberRange", "Bad ranks")
	assert(typeof(permissionGroups) == "string" or typeof(permissionGroups) == "table", "Bad permissions")

	local groupPermData = _groupRankPermissionGroups[groupId]
	if not groupPermData then
		groupPermData = {}
		_groupRankPermissionGroups[groupId] = groupPermData
	end

	if typeof(ranks) == "number" then
		ranks = NumberRange.new(ranks, ranks)
	end

	if typeof(permissionGroups) == "string" then
		permissionGroups = {permissionGroups}
	end

	local rankPermData = {
		Ranks = ranks,
		Permissions = permissionGroups
	}
	table.insert(groupPermData, rankPermData)
	PermissionsHandler.GroupRankPermissionGroupsChanged:Fire(_groupRankPermissionGroups)

	if RunService:IsStudio() then
		print(`[PermissionsHandler] - Granted group [{groupId}] permissions [{table.concat(permissionGroups :: any, ", ")}] for ranks [{(ranks :: NumberRange).Min}, {(ranks :: NumberRange).Max}]`)
	end

	return function()
        local idx = table.find(groupPermData, rankPermData)
        if idx then
            table.remove(groupPermData, idx)
            PermissionsHandler.GroupRankPermissionGroupsChanged:Fire(_groupRankPermissionGroups)
        end
	end
end

--[=[
	Grants specified roles in a Roblox Group permission to use commands under a given PermissionGroup.
	@param groupId -- The Roblox group id to grant permissions to
	@param role -- The role name to grant permissions to
	@param permissionGroups -- The permission groups to grant
	@return function -- A function that can be called to remove the permissions
]=]
function PermissionsHandler:GiveRobloxGroupRolePermissionGroups(groupId: number, role: string, permissionGroups: string | {string})
	assert(typeof(groupId) == "number", "Bad groupId")
	assert(typeof(role) == "string", "Bad role")
	assert(typeof(permissionGroups) == "string" or typeof(permissionGroups) == "table", "Bad permissions")

	if typeof(permissionGroups) == "string" then
		permissionGroups = {permissionGroups}
	end
	assert(typeof(permissionGroups) == "table", "Bad permissions")

	local groupPermData = _groupRolePermissionGroups[groupId]
	if not groupPermData then
		groupPermData = {}
		_groupRolePermissionGroups[groupId] = groupPermData
	end

	if not groupPermData[role] then
		groupPermData[role] = {}
	end

	for _, permission: string in permissionGroups do
		if not table.find(groupPermData[role], permission) then
			table.insert(groupPermData[role], permission)
		end
	end

	PermissionsHandler.GroupRolePermissionGroupsChanged:Fire(_groupRolePermissionGroups)

	if RunService:IsStudio() then
		print(`[PermissionsHandler] - Granted group [{groupId}] permissions [{table.concat(permissionGroups :: any, ", ")}] for role [{role}]`)
	end

	return function()
		for _, permission: string in permissionGroups do
			local idx = table.find(groupPermData[role], permission)
			if not idx then continue end
			table.remove(groupPermData[role], idx)
		end
		PermissionsHandler.GroupRolePermissionGroupsChanged:Fire(_groupRolePermissionGroups)
	end
end

--[=[
    Sets the permission inheritance for a permission group.
    @param permissionGroup -- The permission group to set the inheritance for
    @param inheritedGroups -- The group(s) to inherit permissions from
]=]
function PermissionsHandler:SetPermissionGroupInheritance(permissionGroup: string, inheritedGroups: string | {string})
	assert(typeof(permissionGroup) == "string", "Bad permissionGroup")
	if typeof(inheritedGroups) == "string" then
		inheritedGroups = {inheritedGroups}
	end
    assert(typeof(inheritedGroups) == "table", "Bad inheritedGroups")
	_permissionInheritance[permissionGroup] = inheritedGroups
	PermissionsHandler.PermissionInheritanceChanged:Fire(_permissionInheritance)
end

--[=[
	Fetches the inherited Permission Group(s) for a given Permission Group
	@param permissionGroup -- The permission group to get inheritance for
	@return {string} -- Array of inherited permission groups
]=]
function PermissionsHandler:GetPermissionInheritance(permissionGroup: string): {string}
	return _permissionInheritance[permissionGroup] or {}
end

--[=[
	@private
	Gets the raw group rank permissions (used by CmdrUtil)
	@param groupId -- The group ID to get permissions for
	@return {any} -- Raw group permission data
]=]
function PermissionsHandler:_getRawGroupPerms(groupId: number): {any}
	return _groupRankPermissionGroups[groupId] or {}
end

--[=[
	Gets all commands available to a permission group
	@param permissionGroup -- The permission group to get commands for
	@return {string} -- Array of command names
]=]
function PermissionsHandler:GetCommandsAvailableToPermissionGroup(permissionGroup: string): {string}
	if not _cmdrRegistry then
		warn("PermissionsHandler: Cmdr registry not set!")
		return {}
	end
	
	local commands = {}
	for _, command in _cmdrRegistry:GetCommands() do
		if command.Group == permissionGroup then
			table.insert(commands, command.Name)
		end
	end
	return commands
end

-- Data getters for networking
function PermissionsHandler:_getPermissionInheritanceData()
	return _permissionInheritance
end

function PermissionsHandler:_getPlayerPermissionGroupsData()
	return _playerPermissionGroups
end

function PermissionsHandler:_getGroupRankPermissionGroupsData()
	return _groupRankPermissionGroups
end

function PermissionsHandler:_getGroupRolePermissionGroupsData()
	return _groupRolePermissionGroups
end

-- Data setters for networking (used by client to sync from server)
function PermissionsHandler:_setPermissionInheritanceData(data)
	_permissionInheritance = data or {}
end

function PermissionsHandler:_setPlayerPermissionGroupsData(data)
	_playerPermissionGroups = data or {}
end

function PermissionsHandler:_setGroupRankPermissionGroupsData(data)
	_groupRankPermissionGroups = data or {}
end

function PermissionsHandler:_setGroupRolePermissionGroupsData(data)
	_groupRolePermissionGroups = data or {}
end

return PermissionsHandler
