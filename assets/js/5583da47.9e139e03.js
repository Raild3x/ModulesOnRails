"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[5957],{95620:e=>{e.exports=JSON.parse('{"functions":[{"name":"PromiseCmdr","desc":"Promise that resolves to the Cmdr module data","params":[],"returns":[{"desc":"","lua_type":"Promise<Cmdr>"}],"function_type":"method","source":{"line":62,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterCommandFromModule","desc":"Registers a command from a module with Cmdr. Command modules must return a table of type `CommandModuleData`.\\n```lua\\n-- Commands/Kill.lua\\nreturn {\\n\\tName = \\"kill\\";\\n\\tAliases = {\\"slay\\"};\\n\\tDescription = \\"Kills a player or set of players.\\";\\n\\tGroup = \\"DefaultAdmin\\"; -- The permission group required to run this command\\n\\tArgs = {\\n\\t\\t{\\n\\t\\t\\tType = \\"players\\";\\n\\t\\t\\tName = \\"victims\\";\\n\\t\\t\\tDescription = \\"The players to kill.\\";\\n\\t\\t},\\n\\t};\\n\\n\\t-- Executors\\n\\tClientRun = nil, -- No client side needed\\n\\tServerRun = function (_, players)\\n\\t\\tfor _, player in pairs(players) do\\n\\t\\t\\tif player.Character then\\n\\t\\t\\t\\tplayer.Character:BreakJoints()\\n\\t\\t\\tend\\n\\t\\tend\\n\\t\\treturn (\\"Killed %d players.\\"):format(#players)\\n\\tend\\n}\\n```\\n```lua\\nCmdrServer:RegisterCommandFromModule(script.Parent.Commands.Kill)\\n```","params":[{"name":"module","desc":"The module to register the command from","lua_type":"ModuleScript"}],"returns":[{"desc":"","lua_type":"Promise<nil>"}],"function_type":"method","source":{"line":101,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"ExecuteCommand","desc":"Executes a command with Cmdr from the server\\n```lua\\nCmdrServer:ExecuteCommand(\\"kill Raildex\\"):andThen(function(result)\\n\\tprint(result)\\nend)\\n```","params":[{"name":"commandText","desc":"","lua_type":"string"},{"name":"executor","desc":"","lua_type":"Player?"},{"name":"options","desc":"","lua_type":"{Data: any?, IsHuman: boolean}?"}],"returns":[{"desc":"","lua_type":"Promise<string>"}],"function_type":"method","source":{"line":136,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"ExecuteCommandAsClient","desc":"Executes a command with Cmdr as if it were run by a client\\n```lua\\nCmdrServer:ExecuteCommandAsClient(Players.Raildex, \\"kill\\", \\"*\\")\\nCmdrServer:ExecuteCommandAsClient(Players.Raildex, \\"kill *\\")\\n```","params":[{"name":"executor","desc":"","lua_type":"Player"},{"name":"...","desc":"","lua_type":"string"}],"returns":[],"function_type":"method","source":{"line":150,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"HasPermission","desc":"Checks if a player has permission to run a command","params":[{"name":"plr","desc":"The player to check","lua_type":"Player"},{"name":"commandName","desc":"The name of the command to check","lua_type":"string"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":159,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"GetPermissions","desc":"Gets the permissions for a player","params":[{"name":"plr","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"{any}\\n"}],"function_type":"method","source":{"line":180,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"SetPermissions","desc":"Sets the direct permissions for a player.\\nDoes not override inherited permissions or group permissions.\\n```lua\\nCmdrServer:SetPermissions(Players.Raildex, \\"Admin\\")\\n```\\n:::info\\nThe \'Creator\' permission grants all permissions regardless of group inheritance.\\n:::","params":[{"name":"plr","desc":"","lua_type":"Player"},{"name":"permissions","desc":"","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":195,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"GivePermissions","desc":"Grants a player a permission group(s). Adds the given permissions to the player\'s current permissions.\\n```lua\\nCmdrServer:GivePermissions(Players.Raildex, \\"Admin\\")\\n```","params":[{"name":"plr","desc":"The player to grant permissions to","lua_type":"Player"},{"name":"permissions","desc":"The permissions to grant","lua_type":"string | {string}"}],"returns":[],"function_type":"method","source":{"line":210,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"GetGroupRankPermissions","desc":"Gets the permissions granted to a particular rank in a group.\\n```lua\\nlocal permissions = CmdrServer:GetGroupRankPermissions(15905255, 230)\\n```","params":[{"name":"groupId","desc":"The Roblox group id to get permissions for","lua_type":"number"},{"name":"rank","desc":"The rank to get permissions for","lua_type":"number"}],"returns":[{"desc":"The permissions granted to the rank","lua_type":"{string}"}],"function_type":"method","source":{"line":233,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"GiveGroupPermissions","desc":"Grants a Roblox group permissions to run a command. Takes the ranks to apply the permissions to, and the permissions to grant.\\n```lua\\nlocal revoke = CmdrServer:GiveGroupPermissions(15905255, 230, \\"Admin\\")\\n```","params":[{"name":"groupId","desc":"The Roblox group id to grant permissions to","lua_type":"number"},{"name":"ranks","desc":"The ranks to apply the permissions to. Can be a single rank or a range of ranks.","lua_type":"number | NumberRange"},{"name":"permissions","desc":"The permissions to grant to the group","lua_type":"string | {string}"}],"returns":[{"desc":"A function that can be called to remove the permissions","lua_type":"function"}],"function_type":"method","source":{"line":247,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"SetPermissionInheritance","desc":"Sets the permission inheritance for a permission group.\\nThis will override any previous inheritance.\\n```lua\\nCmdrServer:SetPermissionInheritance(\\"Admin\\", \\"DefaultAdmin\\")\\nCmdrServer:SetPermissionInheritance(\\"Admin\\", {\\"DefaultAdmin\\", \\"Moderator\\"})\\n```","params":[{"name":"permissionGroup","desc":"The permission group to set the inheritance for","lua_type":"string"},{"name":"inheritedGroups","desc":"The groups to inherit permissions from","lua_type":"string | {string}"}],"returns":[{"desc":"","lua_type":"nil"}],"function_type":"method","source":{"line":295,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"GetPermissionInheritance","desc":"Fetches the inherited permission group for a permission group","params":[{"name":"permissionGroup","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"{string}\\n"}],"function_type":"method","source":{"line":308,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterType","desc":"Registers a type with Cmdr","params":[{"name":"name","desc":"The name of the type","lua_type":"string"},{"name":"typeData","desc":"The type data to register","lua_type":"TypeDefinition<T>"}],"returns":[{"desc":"","lua_type":"Promise\\n"}],"function_type":"method","source":{"line":319,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterCommand","desc":"This method is deprecated\\nRegisters a command with Cmdr. This method does not support client-side execution.\\nOriginally ported from Quenty\'s wrapper for Cmdr.","params":[{"name":"commandData","desc":"The command data to register","lua_type":"CommandDefinition<T>"},{"name":"commandServerExecutor","desc":"The server function to execute when the command is run","lua_type":"((context: table, ...any) -> ())?"}],"returns":[],"function_type":"method","private":true,"unreleased":true,"source":{"line":334,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"__executeCommand","desc":"Private function used by the execution template to retrieve the execution function.","params":[{"name":"cmdrCommandId","desc":"","lua_type":"string"},{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","private":true,"source":{"line":380,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"_getRawGroupPerms","desc":"","params":[{"name":"groupId","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"{string}\\n"}],"function_type":"method","private":true,"source":{"line":395,"path":"lib/cmdrhandler/src/Server/init.luau"}}],"properties":[],"types":[],"name":"CmdrServer","desc":"This is a wrapper service for Evaera\'s Cmdr module (https://eryn.io/Cmdr/).\\nIt provides an easier way to interact with Cmdr and autoboots with Roam\'s\\nsystems.","realm":["Server"],"source":{"line":11,"path":"lib/cmdrhandler/src/Server/init.luau"}}')}}]);