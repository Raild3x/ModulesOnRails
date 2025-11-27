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

-- Basic interface for Cmdr registry based on usage in this module
type CmdrRegistry = {
	GetCommand: (self: CmdrRegistry, commandName: string) -> CommandDefinition?,
	GetCommands: (self: CmdrRegistry) -> { CommandDefinition },
}

local Packages = script.Parent.Parent.Parent
local Signal = require(Packages.Signal) :: any

-- Default permission inheritance structure (shared constant)
local DEFAULT_PERMISSION_INHERITANCE: { [string]: { string } } = {
	DefaultAdmin = { "DefaultDebug", "DefaultUtility", "Help" },
	Admin = { "DefaultAdmin" },
	Tester = { "DefaultDebug", "DefaultUtility", "Help" },
}

--------------------------------------------------------------------------------
--// Shared Handler //--
--------------------------------------------------------------------------------

local PermissionsHandler = {}
PermissionsHandler.ClassName = "PermissionsHandler"

-- Events for data changes
PermissionsHandler.PermissionInheritanceChanged = Signal.new() :: any
PermissionsHandler.PlayerPermissionGroupsChanged = Signal.new() :: any
PermissionsHandler.GroupRankPermissionGroupsChanged = Signal.new() :: any
PermissionsHandler.GroupRolePermissionGroupsChanged = Signal.new() :: any

-- Data storage (will be managed by client/server implementations)
local permissionInheritance: { [string]: { string } } = table.clone(DEFAULT_PERMISSION_INHERITANCE)
local playerPermissionGroups: { [Player]: { string } } = {}
-- GroupId can be number or string due to JSON serialization/networking
type GroupId = number | string
local groupRankPermissionGroups: { [GroupId]: { { Ranks: NumberRange, Permissions: { string } } } } = {}
local groupRolePermissionGroups: { [GroupId]: { [string]: { string } } } = {}

-- Reference to the Cmdr registry (will be set by server/client)
local _cmdrRegistry: CmdrRegistry? = nil

-- Helper function to normalize GroupId to string for consistent storage
local function normalizeGroupId(groupId: number): string
	return tostring(groupId)
end

--[=[
	Sets the Cmdr registry reference for command lookups
	@param registry -- The Cmdr registry instance
]=]
function PermissionsHandler:SetCmdrRegistry(registry: CmdrRegistry): ()
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
		warn(`PermissionsHandler: Command [{commandName}] not found in registry!`)
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
function PermissionsHandler:GetPlayerPermissionGroups(plr: Player): { string }
	local permissions = playerPermissionGroups[plr] or {}
	return Util.getPlayerPermissions(PermissionsHandler, plr, permissions)
end

--[=[
	Sets the direct permissions for a player.
	Does not override inherited permissions or group permissions.
	@param plr -- The player to set permissions for
	@param permissions -- The permission group(s) to set
]=]
function PermissionsHandler:SetPlayerPermissionGroups(plr: Player, permissions: string | { string }): ()
	if typeof(permissions) == "string" then
		permissions = { permissions }
	end
	playerPermissionGroups[plr] = permissions :: { string }
	PermissionsHandler.PlayerPermissionGroupsChanged:Fire(plr, permissions)
end

--[=[
	Grants a player permission group(s). Adds the given permissions to the player's current permissions.
	@param plr -- The player to grant permissions to
	@param permissionGroups -- The permission groups to grant
]=]
function PermissionsHandler:GivePlayerPermissionGroups(plr: Player, permissionGroups: string | { string }): ()
	if typeof(permissionGroups) == "string" then
		permissionGroups = { permissionGroups }
	end
	assert(typeof(permissionGroups) == "table", "Bad permissionGroups")
	local currentPermissions = playerPermissionGroups[plr] or {}
	for _, permission: string in permissionGroups do
		if not table.find(currentPermissions, permission) then
			table.insert(currentPermissions, permission)
		end
	end
	PermissionsHandler:SetPlayerPermissionGroups(plr, currentPermissions)
end

--[=[
	Gets the permissions granted to a particular rank in a group.
	@param robloxGroupId -- The Roblox group id to get permissions for
	@param rank -- The rank to get permissions for
	@return {string} -- The permission groups granted to the rank
]=]
function PermissionsHandler:GetRobloxGroupRankPermissionGroups(robloxGroupId: number, rank: number): { string }
	return Util.getGroupRankPermissions(PermissionsHandler, robloxGroupId, rank)
end

--[=[
	Grants specified ranks in a Roblox Group permission to use the commands under a given PermissionGroup.
	@param robloxGroupId -- The Roblox group id to grant permissions to
	@param ranks -- The ranks to apply the permissions to. Can be a single rank or a range of ranks.
	@param permissionGroups -- The permissions to grant to the group
	@return function -- A function that can be called to remove the permissions
]=]
function PermissionsHandler:GiveRobloxGroupRankPermissionGroups(
	robloxGroupId: number,
	ranks: number | NumberRange,
	permissionGroups: string | { string }
): () -> ()
	assert(typeof(robloxGroupId) == "number", "Bad robloxGroupId")
	assert(typeof(ranks) == "number" or typeof(ranks) == "NumberRange", "Bad ranks")
	assert(typeof(permissionGroups) == "string" or typeof(permissionGroups) == "table", "Bad permissions")

	-- Store using string key for consistency (JSON serialization converts numbers to strings)
	local groupIdKey = normalizeGroupId(robloxGroupId)
	local groupPermData = groupRankPermissionGroups[groupIdKey]
	if not groupPermData then
		groupPermData = {}
		groupRankPermissionGroups[groupIdKey] = groupPermData
	end

	if typeof(ranks) == "number" then
		ranks = NumberRange.new(ranks, ranks)
	end

	if typeof(permissionGroups) == "string" then
		permissionGroups = { permissionGroups }
	end

	local rankPermData = {
		Ranks = ranks,
		Permissions = permissionGroups,
	}
	table.insert(groupPermData, rankPermData)
	PermissionsHandler.GroupRankPermissionGroupsChanged:Fire(groupRankPermissionGroups)

	if RunService:IsStudio() then
		print(
			`[PermissionsHandler] - Granted group [{robloxGroupId}] permissions [{table.concat(
				permissionGroups :: any,
				", "
			)}] for ranks [{(ranks :: NumberRange).Min}, {(ranks :: NumberRange).Max}]`
		)
	end

	return function()
		local index = table.find(groupPermData, rankPermData)
		if index then
			table.remove(groupPermData, index)
			PermissionsHandler.GroupRankPermissionGroupsChanged:Fire(groupRankPermissionGroups)
		end
	end
end

--[=[
	Grants specified roles in a Roblox Group permission to use commands under a given PermissionGroup.
	@param robloxGroupId -- The Roblox group id to grant permissions to
	@param role -- The role name to grant permissions to
	@param permissionGroups -- The permission groups to grant
	@return function -- A function that can be called to remove the permissions
]=]
function PermissionsHandler:GiveRobloxGroupRolePermissionGroups(
	robloxGroupId: number,
	role: string,
	permissionGroups: string | { string }
): () -> ()
	error(
		"Using group roles for permissions does not work properly yet since Player:GetRoleInGroup() returns the player rank instead of the role. Use :GiveRobloxGroupRankPermissionGroups() instead."
	)
	assert(typeof(robloxGroupId) == "number", "Bad robloxGroupId")
	assert(typeof(role) == "string", "Bad role")
	assert(typeof(permissionGroups) == "string" or typeof(permissionGroups) == "table", "Bad permissions")

	if typeof(permissionGroups) == "string" then
		permissionGroups = { permissionGroups }
	end
	assert(typeof(permissionGroups) == "table", "Bad permissions")

	-- Store using string key for consistency (JSON serialization converts numbers to strings)
	local groupIdKey = normalizeGroupId(robloxGroupId)
	local groupPermData = groupRolePermissionGroups[groupIdKey]
	if not groupPermData then
		groupPermData = {}
		groupRolePermissionGroups[groupIdKey] = groupPermData
	end

	if not groupPermData[role] then
		groupPermData[role] = {}
	end

	for _, permission: string in permissionGroups do
		if not table.find(groupPermData[role], permission) then
			table.insert(groupPermData[role], permission)
		end
	end

	PermissionsHandler.GroupRolePermissionGroupsChanged:Fire(groupRolePermissionGroups)

	if RunService:IsStudio() then
		print(
			`[PermissionsHandler] - Granted group [{robloxGroupId}] permissions [{table.concat(
				permissionGroups :: any,
				", "
			)}] for role [{role}]`
		)
	end

	return function()
		for _, permission: string in permissionGroups do
			local idx = table.find(groupPermData[role], permission)
			if not idx then
				continue
			end
			table.remove(groupPermData[role], idx)
		end
		PermissionsHandler.GroupRolePermissionGroupsChanged:Fire(groupRolePermissionGroups)
	end
end

--[=[
    Sets the permission inheritance for a permission group.
    @param permissionGroup -- The permission group to set the inheritance for
    @param inheritedGroups -- The group(s) to inherit permissions from
]=]
function PermissionsHandler:SetPermissionGroupInheritance(
	permissionGroup: string,
	inheritedGroups: string | { string }
): ()
	assert(typeof(permissionGroup) == "string", "Bad permissionGroup")
	if typeof(inheritedGroups) == "string" then
		inheritedGroups = { inheritedGroups }
	end
	assert(typeof(inheritedGroups) == "table", "Bad inheritedGroups")
	permissionInheritance[permissionGroup] = inheritedGroups
	PermissionsHandler.PermissionInheritanceChanged:Fire(permissionInheritance)
end

--[=[
	Fetches the inherited Permission Group(s) for a given Permission Group
	@param permissionGroup -- The permission group to get inheritance for
	@return {string} -- Array of inherited permission groups
]=]
function PermissionsHandler:GetPermissionInheritance(permissionGroup: string): { string }
	return permissionInheritance[permissionGroup] or {}
end

--[=[
	Gets all commands available to a permission group
	@param permissionGroup -- The permission group to get commands for
	@return {string} -- Array of command names
]=]
function PermissionsHandler:GetCommandsAvailableToPermissionGroup(permissionGroup: string): { string }
	if not _cmdrRegistry then
		warn("PermissionsHandler: Cmdr registry not set!")
		return {}
	end

	local commands: { string } = {}
	for _, command in _cmdrRegistry:GetCommands() do
		if command.Group == permissionGroup then
			table.insert(commands, command.Name)
		end
	end
	return commands
end

--[=[
	@private
	Gets the raw group rank permissions (used by CmdrUtil)
	@param groupId -- The group ID to get permissions for (can be number or string)
	@return {any} -- Raw group permission data
]=]
function PermissionsHandler:_getRawGroupPerms(groupId: number): { any }
	-- Handle both number and string GroupIds (due to JSON serialization)
	local groupIdKey = normalizeGroupId(groupId)
	return groupRankPermissionGroups[groupId] or groupRankPermissionGroups[groupIdKey] or {}
end

-- Data getters for networking
function PermissionsHandler:_getPermissionInheritanceData(): { [string]: { string } }
	return permissionInheritance
end

function PermissionsHandler:_getPlayerPermissionGroupsData(): { [Player]: { string } }
	return playerPermissionGroups
end

function PermissionsHandler:_getGroupRankPermissionGroupsData(): {
	[GroupId]: { { Ranks: NumberRange, Permissions: { string } } },
}
	return groupRankPermissionGroups
end

function PermissionsHandler:_getGroupRolePermissionGroupsData(): { [GroupId]: { [string]: { string } } }
	return groupRolePermissionGroups
end

-- Data setters for networking (used by client to sync from server)
function PermissionsHandler:_setPermissionInheritanceData(data: { [string]: { string } }?): ()
	if data then
		permissionInheritance = data
	else
		permissionInheritance = table.clone(DEFAULT_PERMISSION_INHERITANCE)
	end
end

function PermissionsHandler:_setPlayerPermissionGroupsData(data: { [Player]: { string } }?): ()
	playerPermissionGroups = data or {}
end

function PermissionsHandler:_setGroupRankPermissionGroupsData(data: {
	[GroupId]: { { Ranks: NumberRange, Permissions: { string } } },
}?): ()
	groupRankPermissionGroups = data or {}
end

function PermissionsHandler:_setGroupRolePermissionGroupsData(data: { [GroupId]: { [string]: { string } } }?): ()
	groupRolePermissionGroups = data or {}
end

return PermissionsHandler
