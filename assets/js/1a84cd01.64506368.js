"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[4343],{76718:e=>{e.exports=JSON.parse('{"functions":[],"properties":[],"types":[{"name":"ArgumentContext<T>","desc":"","fields":[{"name":"Command","lua_type":"CommandContext<T>","desc":"The command context this argument belongs to."},{"name":"Name","lua_type":"string","desc":"The name of the argument"},{"name":"Type","lua_type":"TypeDefinition<T>","desc":"The type definition of the argument"},{"name":"Required","lua_type":"boolean","desc":"Whether or not this argument is required"},{"name":"Executor","lua_type":"Player","desc":"The player that ran the command this argument belongs to."},{"name":"RawValue","lua_type":"string","desc":"The raw value of the argument"},{"name":"RawSegments","lua_type":"{string}","desc":"The raw segments of the argument"},{"name":"Prefix","lua_type":"string","desc":"The prefix of the argument"}],"source":{"line":22,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}},{"name":"CommandContext<T>","desc":"","fields":[{"name":"Executor","lua_type":"Player","desc":"The player who executed the command"},{"name":"Name","lua_type":"string","desc":"the name of the command"},{"name":"Description","lua_type":"string","desc":"the description of the command"},{"name":"Alias","lua_type":"string","desc":"The specific alias of this command that was used to trigger this command (may be the same as Name)"},{"name":"Aliases","lua_type":"{string}","desc":"The list of aliases that could have been used to trigger this command"},{"name":"Group","lua_type":"any","desc":"The group this command is a part of. Defined in command definitions, typically a string."},{"name":"RawText","lua_type":"string","desc":"the raw text of the command"},{"name":"RawArguments","lua_type":"{string}","desc":"the raw arguments of the command"},{"name":"Arguments","lua_type":"{ArgumentContext<T>}","desc":"the parsed arguments of the command"},{"name":"Cmdr","lua_type":"table","desc":""},{"name":"Dispatcher","lua_type":"table","desc":"the dispatcher that ran the command"},{"name":"State","lua_type":"table","desc":"A blank table that can be used to store user-defined information about this command\'s current execution. This could potentially be used with hooks to add information to this table which your command or other hooks could consume."}],"source":{"line":52,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}},{"name":"TypeDefinition<T>","desc":"","fields":[{"name":"DisplayName","lua_type":"string","desc":"The display name of the type"},{"name":"Prefixes","lua_type":"string","desc":"The prefixes that this type can use"},{"name":"Transform","lua_type":"(rawText: string, executor: Player) -> any","desc":"A function that transforms the raw text into the desired type"},{"name":"Validate","lua_type":"(value: T) -> (boolean, string?)","desc":"A function that validates the value. Returns a boolean and an optional error message."},{"name":"ValidateOnce","lua_type":"(value: T) -> (boolean, string?)","desc":"A function that validates the value once. Returns a boolean and an optional error message."},{"name":"Autocomplete","lua_type":"(value: T) -> ({string}, {IsPartial: boolean?})","desc":"A function that returns a list of possible completions for the value. Returns a list of strings and an optional boolean indicating if the completions are partial."},{"name":"Parse","lua_type":"(value: T) -> any","desc":"A function that parses the value"},{"name":"Default","lua_type":"(plr: Player) -> string","desc":"A function that returns the default value for the type"},{"name":"Listable","lua_type":"boolean","desc":"Whether or not this type is listable"}],"source":{"line":88,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}},{"name":"CommandArgument","desc":"","fields":[{"name":"Type","lua_type":"string | TypeDefinition<any>","desc":"The type of the argument"},{"name":"Name","lua_type":"string","desc":"The name of the argument"},{"name":"Description","lua_type":"string","desc":"The description of the argument"},{"name":"Optional","lua_type":"boolean","desc":"Whether or not this argument is optional"},{"name":"Default","lua_type":"any","desc":"The default value of the argument"}],"source":{"line":109,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}},{"name":"CommandDefinition<T>","desc":"","fields":[{"name":"Name","lua_type":"string","desc":"The name of the command"},{"name":"Description","lua_type":"string","desc":"The description of the command"},{"name":"Aliases","lua_type":"{string}?","desc":"The aliases of the command"},{"name":"Group","lua_type":"any?","desc":"The group this command is a part of"},{"name":"Args","lua_type":"{CommandArgument | (context: CommandContext<T>) -> CommandArgument}","desc":"The arguments of the command"},{"name":"Data","lua_type":"((context: CommandContext<T>, ...any) -> any)?","desc":"The data of the command"},{"name":"AutoExec","lua_type":"{string}?","desc":"The autoexec of the command"},{"name":"ClientRun","lua_type":"((context: CommandContext<T>, ...any) -> string?)?","desc":"The client run of the command"}],"source":{"line":129,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}}],"name":"CmdrTypes","desc":"This class is a collection of types used in Cmdr. Some of the comments here may not be entirely accurate.","source":{"line":7,"path":"lib/cmdrhandler/src/Shared/CmdrTypes.luau"}}')}}]);