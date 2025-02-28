"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[8731],{95620:e=>{e.exports=JSON.parse('{"functions":[{"name":"PromiseCmdr","desc":"Promise that resolves to the Cmdr module data","params":[],"returns":[{"desc":"","lua_type":"Promise<Cmdr>"}],"function_type":"method","source":{"line":55,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterCommandFromModule","desc":"Registers a command from a module with Cmdr. Command modules must return a table of type `CommandModuleData`.\\n```lua\\n-- Commands/Kill.lua\\nreturn {\\n\\tName = \\"kill\\";\\n\\tAliases = {\\"slay\\"};\\n\\tDescription = \\"Kills a player or set of players.\\";\\n\\tGroup = \\"Admin\\"; -- The permission group required to run this command\\n\\tArgs = {\\n\\t\\t{\\n\\t\\t\\tType = \\"players\\";\\n\\t\\t\\tName = \\"victims\\";\\n\\t\\t\\tDescription = \\"The players to kill.\\";\\n\\t\\t},\\n\\t};\\n\\n\\t-- Executors\\n\\tClientRun = nil, -- No client side needed\\n\\tServerRun = function (context: CommandContext, players: {Player})\\n\\t\\tfor _, player in pairs(players) do\\n\\t\\t\\tif player.Character then\\n\\t\\t\\t\\tplayer.Character:BreakJoints()\\n\\t\\t\\tend\\n\\t\\tend\\n\\t\\treturn (\\"Killed %d players.\\"):format(#players)\\n\\tend\\n}\\n```\\n```lua\\nCmdrServer:RegisterCommandFromModule(script.Parent.Commands.Kill)\\n```","params":[{"name":"module","desc":"The module to register the command from","lua_type":"ModuleScript"}],"returns":[{"desc":"","lua_type":"Promise<nil>"}],"function_type":"method","source":{"line":94,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"ExecuteCommand","desc":"Executes a command with Cmdr from the server. Requires a player to be given as a source of the command.\\nIf `Data` is given, it will be available on the server with `CommandContext.GetData`\\n\\n```lua\\nlocal result = CmdrServer:ExecuteCommand(\\"kill Mophyr\\", Players.Raildex)\\n```","params":[{"name":"commandText","desc":"","lua_type":"string"},{"name":"executor","desc":"","lua_type":"Player"},{"name":"options","desc":"","lua_type":"{Data: any?, IsHuman: boolean}?"}],"returns":[],"function_type":"method","source":{"line":128,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterType","desc":"Registers a type with Cmdr","params":[{"name":"name","desc":"The name of the type","lua_type":"string"},{"name":"typeData","desc":"The type data to register","lua_type":"TypeDefinition"}],"returns":[],"function_type":"method","source":{"line":140,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RegisterCommand","desc":"This method is deprecated\\nRegisters a command with Cmdr. This method does not support client-side execution.\\nOriginally ported from Quenty\'s wrapper for Cmdr.","params":[{"name":"commandData","desc":"The command data to register","lua_type":"CommandDefinition"},{"name":"commandServerExecutor","desc":"The server function to execute when the command is run","lua_type":"((context: table, ...any) -> ())?"}],"returns":[],"function_type":"method","private":true,"unreleased":true,"source":{"line":153,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"__executeCommand","desc":"Private function used by the execution template to retrieve the execution function.","params":[{"name":"cmdrCommandId","desc":"","lua_type":"string"},{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","private":true,"source":{"line":197,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"_getRawGroupPerms","desc":"","params":[{"name":"groupId","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"{string}\\r\\n"}],"function_type":"method","private":true,"source":{"line":212,"path":"lib/cmdrhandler/src/Server/init.luau"}},{"name":"RoamInit","desc":"Starts Cmdr on the Server","params":[],"returns":[],"function_type":"method","source":{"line":224,"path":"lib/cmdrhandler/src/Server/init.luau"}}],"properties":[{"name":"PermissionsHandler","desc":"","lua_type":"PermissionsHandler","source":{"line":49,"path":"lib/cmdrhandler/src/Server/init.luau"}}],"types":[],"name":"CmdrServer","desc":"This is a wrapper service for Evaera\'s Cmdr module (https://eryn.io/Cmdr/).\\nIt provides an easier way to interact with Cmdr and autoboots with Roam\'s\\nsystems.","realm":["Server"],"source":{"line":11,"path":"lib/cmdrhandler/src/Server/init.luau"}}')}}]);