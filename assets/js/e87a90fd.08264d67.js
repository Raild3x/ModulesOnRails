"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[5611],{68331:e=>{e.exports=JSON.parse('{"functions":[{"name":"PlayerHasPermissionForCommand","desc":"Checks if a player has permission to run a command","params":[{"name":"plr","desc":"","lua_type":"Player"},{"name":"commandName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"boolean\\r\\n"}],"function_type":"method","source":{"line":42,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GetPlayerPermissionGroups","desc":"Gets the permissions groups for a player","params":[{"name":"plr","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"{string}\\r\\n"}],"function_type":"method","source":{"line":59,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"SetPlayerPermissionGroups","desc":"Sets the direct permissions for a player.\\nDoes not override inherited permissions or group permissions.\\n```lua\\nPermissionsHandler:SetPlayerPermissionGroups(Players.Raildex, \\"Admin\\")\\n```\\n:::info\\nThe `Creator` permission group grants all permissions regardless of group inheritance.\\n:::","params":[{"name":"plr","desc":"","lua_type":"Player"},{"name":"permissions","desc":"","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":74,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GivePlayerPermissionGroups","desc":"Grants a player a permission group(s). Adds the given permissions to the player\'s current permissions.\\n```lua\\nPermissionsHandler:GivePlayerPermissionGroups(Players.Raildex, \\"Admin\\")\\n```","params":[{"name":"plr","desc":"The player to grant permissions to","lua_type":"Player"},{"name":"permissionGroups","desc":"The permission groups to grant","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":89,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GetRobloxGroupRankPermissionGroups","desc":"Gets the permissions granted to a particular rank in a group.\\n```lua\\nlocal permissions = PermissionsHandler:GetGroupRankPermissions(15905255, 230)\\n```","params":[{"name":"groupId","desc":"The Roblox group id to get permissions for","lua_type":"number"},{"name":"rank","desc":"The rank to get permissions for","lua_type":"number"}],"returns":[{"desc":"The permission groups granted to the rank","lua_type":"{string}"}],"function_type":"method","source":{"line":113,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GiveRobloxGroupRankPermissionGroups","desc":"Grants specified ranks in a Roblox Group permission to use the commands under a given PermissionGroup.\\n```lua\\nlocal revoke = PermissionsHandler:GiveRobloxGroupRankPermissionGroups(15905255, 230, \\"Admin\\")\\n```","params":[{"name":"groupId","desc":"The Roblox group id to grant permissions to","lua_type":"number"},{"name":"ranks","desc":"The ranks to apply the permissions to. Can be a single rank or a range of ranks.","lua_type":"number | NumberRange"},{"name":"permissionGroups","desc":"The permissions to grant to the group","lua_type":"string | {string}"}],"returns":[{"desc":"A function that can be called to remove the permissions","lua_type":"function"}],"function_type":"method","source":{"line":127,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GiveRobloxGroupRolePermissionGroups","desc":"\\t","params":[{"name":"groupId","desc":"","lua_type":"number"},{"name":"role","desc":"","lua_type":"string"},{"name":"permissionGroups","desc":"","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":167,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"SetPermissionGroupInheritance","desc":"Sets the permission inheritance for a permission group.\\n*This will override any previous inheritance.*\\n\\n-- TODO: Add conditional inheritance\\n\\n\\n```lua\\nPermissionsHandler:SetPermissionGroupInheritance(\\"Tester\\", {\\"MoneyCommands\\", \\"InventoryCommands\\"})\\nPermissionsHandler:SetPermissionGroupInheritance(\\"Moderator\\", {\\"BanCommands\\"})\\n```","params":[{"name":"permissionGroup","desc":"The permission group to set the inheritance for","lua_type":"string"},{"name":"inheritedGroups","desc":"The group(s) to inherit permissions from","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":224,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GetPermissionInheritance","desc":"Fetches the inherited Permission Group(s) for a given Permission Group","params":[{"name":"permissionGroup","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"{string}\\r\\n"}],"function_type":"method","source":{"line":238,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}},{"name":"GetCommandsAvailableToPermissionGroup","desc":"TODO: FINISH THIS METHOD","params":[{"name":"permissionGroup","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"{string}\\r\\n"}],"function_type":"method","source":{"line":247,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}}],"properties":[],"types":[],"name":"PermissionsHandler","desc":"","source":{"line":6,"path":"lib/cmdrhandler/src/Server/PermissionsHandler.luau"}}')}}]);