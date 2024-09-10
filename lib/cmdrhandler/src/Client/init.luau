-- Authors: Logan Hunt (Raildex)
-- May 01, 2024
--[=[
	@class CmdrClient
	@client
]=]

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local Signal = require(Packages.Signal)
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local NetWire = require(Packages.NetWire)
local Util = require(script.Parent.Shared.CmdrUtil)
local CmdrTypes = require(script.Parent.Shared.CmdrTypes)

--// Types //--
type Cmdr = any
type Promise = typeof(Promise.new())
type CommandDefinition<T> = CmdrTypes.CommandDefinition<T>
type CommandContext<T> = CmdrTypes.CommandContext<T>
type TypeDefinition<T> = CmdrTypes.TypeDefinition<T>

--// Constants //--
local LocalPlayer = Players.LocalPlayer

--// Volatiles //--
local cmdrReadied = Signal.new()
local cmdrProm = Promise.fromEvent(cmdrReadied)

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

local CmdrClient = {}

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
	if not self._Cmdr then
		return false
	end

	local commandData = self._Cmdr.Registry:GetCommand(commandName) :: CommandDefinition<any>
	if not commandData then
		return false
	end

	local permissions = self:GetPermissions()
	if table.find(permissions, commandData.Group) or table.find(permissions, "Creator") then
		return true
	end
	
	return false
end

--[=[
	Executes a command
	@return Promise<string>
	```lua
	CmdrService:ExecuteCommand("blink")
	```
]=]
function CmdrClient:ExecuteCommand(...: string): Promise
	local args = {...}
	return self:PromiseCmdr():andThen(function(cmdr)
		return cmdr.Dispatcher:Run(table.unpack(args))
	end)
end

--[=[
	Gets the permissions for the local player
	Does not return permissions granted from groups
]=]
function CmdrClient:GetPermissions(): {any}
	local permissions = self.Server.Permissions:Get() or {}
	return Util.getPlayerPermissions(self, LocalPlayer, permissions)
end

--[=[
	Gets the permissions granted to a particular rank in a group
	@param groupId -- The Roblox group id to get permissions for
	@param rank -- The rank to get permissions for
	@return {string} -- The permissions granted to the rank
	```lua
	local permissions = CmdrService:GetGroupRankPermissions(15905255, 230)
	```
]=]
function CmdrClient:GetGroupRankPermissions(groupId: number, rank: number)
	return Util.GetGroupRankPermissions(self, groupId, rank)
end

--[=[
	Fetches the inherited permission group for a permission group
]=]
function CmdrClient:GetPermissionInheritance(permissionGroup: string): {string}
	local inheritanceDict = self.Server.PermissionInheritance:Get() or {}
	return inheritanceDict[permissionGroup] or {}
end

--[=[
	@private
	Sets up the default bindings for Cmdr
]=]
function CmdrClient:_setBindings(cmdr: Cmdr)
	cmdr:SetActivationUnlocksMouse(true)
	cmdr:SetActivationKeys({ Enum.KeyCode.F2 })

	-- enable activation on mobile
	self._Janitor:Add(Players.LocalPlayer.Chatted:Connect(function(chat)
		-- check if the chat string starts with "/cmdr"
		local keyword = "/cmdr"
		if chat:sub(1, #keyword):lower() == keyword then
			cmdr:Show()
		end
	end), nil, "ChatBind")

	-- Race condition
	-- task.defer(function()
	-- 	-- Default blink for debugging purposes
	-- 	cmdr.Dispatcher:Run("bind", Enum.KeyCode.G.Name, "blink")
	-- end)
end

--[=[
	@private
]=]
function CmdrClient:_getRawGroupPerms(groupId: number): {string}
	local groupSets = (self.Server.GroupPerms:Get() or {})
	return groupSets[groupId] or groupSets[tostring(groupId)] or {}
end

--------------------------------------------------------------------------------
	--// Service Core //--
--------------------------------------------------------------------------------

function CmdrClient:Init()
	self.Server = NetWire.Client("CmdrService")
	self._Janitor = Janitor.new()

	self.Server.ExecuteCommand:Connect(function(...: string)
		self:ExecuteCommand(...)
	end)

	task.spawn(function()
		self._Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient") :: any)
		cmdrReadied:Fire(self._Cmdr)
		self:_setBindings(self._Cmdr)
	end)

	self:PromiseCmdr():andThen(function(cmdr)
		cmdr.Registry:RegisterHook("BeforeRun", function(context: CommandContext<any>)
			-- allow!
			if context.Executor == nil then
				return nil
			end

			local HasPermission = self:HasPermission(context.Name)
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