-- Authors: Logan Hunt (Raildex)
-- May 02, 2024
--[=[
    @class CmdrTypes
    This class is a collection of types used in Cmdr. Some of the comments here may not be entirely accurate.
]=]

type table = {[any]: any}

--[=[
    @within CmdrTypes
    @interface TypeDefinition
    .DisplayName string
    .Prefixes string
    .Transform nil | (rawText: string, executor: Player) -> any
    .Validate nil | (value: T) -> (boolean, string?)
    .ValidateOnce nil | (value: T) -> (boolean, string?)
    .Autocomplete nil | (value: T) -> ({string}, {IsPartial: boolean?})
    .Parse (value: T) -> any
    .Default (plr: Player) -> string
    .Listable boolean

    | Field | Description |
    | ----- | --- |
    | DisplayName | Optionally overrides the user-facing name of this type in the autocomplete menu. If omitted, the registered name of this type will be used. |
    | Prefixes | String containing default **Prefixed Union Types** for this type. This property should omit the initial type name, so this string should begin with a prefix character, e.g. `Prefixes = "# integer ! boolean"`. |
    | Transform | Transform is an optional function that is passed two values: the raw text, and the player running the command. Then, whatever values this function returns will be passed to all other functions in the type (`Validate`, `Autocomplete`, and `Parse`). |
    | Validate | The `Validate` function is passed whatever is returned from the Transform function (or the raw value if there is no Transform function). If the value is valid for the type, it should return true. If it the value is invalid, it should return two values: false, and a string containing an error message. If this function isn't present, anything will be considered valid. |
    | ValidateOnce | This function works exactly the same as the normal `Validate` function, except it only runs once (after the user presses Enter). This should only be used if the validation process is relatively expensive or needs to yield. For example, the PlayerId type uses this because it needs to call `GetUserIdFromNameAsync` in order to validate. For the vast majority of types, you should just use `Validate` instead. |
    | AutoComplete |  A function that returns a list of possible completions for the value. Returns a list of strings and an optional boolean indicating if the completions are partial. |
    | Parse | Parse is the only required function in a type definition. It is the final step before the value is considered finalized. This function should return the actual parsed value that will be sent to the command functions. |
    | Default | The `Default` function is optional and should return the "default" value for this type, as a string. For example, the default value of the `players` type is the name of the player who ran the command. |
    | Listable | If you set the optional key Listable to true in your table, this will tell Cmdr that comma-separated lists are allowed for this type. Cmdr will automatically split the list and parse each segment through your Transform, Validate, Autocomplete, and Parse functions individually, so you don't have to change the logic of your Type at all. The only limitation is that your Parse function must return a table. The tables from each individual segment's Parse will be merged into one table at the end of the parse step. The uniqueness of values is ensured upon merging, so even if the user lists the same value several times, it will only appear once in the final table.
]=]
export type TypeDefinition = {
    DisplayName: string?,
    Prefixes: string?,
    Transform: nil | (rawText: string, executor: Player) -> any,
    Validate: nil | <T>(value: T) -> (boolean, string?),
    ValidateOnce: nil | <T>(value: T) -> (boolean, string?),
    Autocomplete: nil | <T>(value: T) -> ({string}, {IsPartial: boolean?}),
    Parse: <T>(value: T) -> any,
    Default: ((plr: Player) -> string)?,
    Listable: boolean?,
}


--[=[
    @within CmdrTypes
    @interface ArgumentContext
    .Command CommandContext -- The command context this argument belongs to.
    .Name string -- The name of the argument
    .Type TypeDefinition -- The type definition of the argument
    .Required boolean -- Whether or not this argument is required
    .Executor Player -- The player that ran the command this argument belongs to.
    .RawValue string -- The raw value of the argument
    .RawSegments {string} -- The raw segments of the argument
    .Prefix string -- The prefix of the argument
]=]
export type ArgumentContext = {
    Command: CommandContext,
    Name: string,
    Type: TypeDefinition,
    Required: boolean, -- Whether or not this argument is required
    Executor: Player, -- The player that ran the command this argument belongs to.
    RawValue: string,
    RawSegments: {string},
    Prefix: string,

    GetValue: (self: ArgumentContext) -> any,
    GetTransformedValue: (self: ArgumentContext, segment: number) -> (any),
} -- https://eryn.io/Cmdr/api/ArgumentContext.html#argumentcontext

--[=[
    @within CmdrTypes
    @interface CommandContext
    .Executor Player -- The player who executed the command
    .Name string -- the name of the command
    .Description string -- the description of the command
    .Alias string -- The specific alias of this command that was used to trigger this command (may be the same as Name)
    .Aliases {string} -- The list of aliases that could have been used to trigger this command
    .Group any -- The group this command is a part of. Defined in command definitions, typically a string.
    .RawText string -- the raw text of the command
    .RawArguments {string} -- the raw arguments of the command
    .Arguments {ArgumentContext} -- the parsed arguments of the command
    .Cmdr table
    .Dispatcher table -- the dispatcher that ran the command
    .State table -- A blank table that can be used to store user-defined information about this command's current execution. This could potentially be used with hooks to add information to this table which your command or other hooks could consume.
    
    https://eryn.io/Cmdr/api/CommandContext.html#commandcontext
]=]
export type CommandContext = {
    Executor: Player, -- The player who executed the command
    Name: string, -- the name of the command
    Description: string, -- the description of the command
    Alias: string, -- The specific alias of this command that was used to trigger this command (may be the same as Name)
    Aliases: {string}, -- The list of aliases that could have been used to trigger this command
    Group: any, -- The group this command is a part of. Defined in command definitions, typically a string.
    RawText: string, -- the raw text of the command
    RawArguments: {string}, -- the raw arguments of the command
    Arguments: {ArgumentContext}, -- the parsed arguments of the command
    Cmdr: table,
    Dispatcher: table, -- the dispatcher that ran the command
    State: table, -- A blank table that can be used to store user-defined information about this command's current execution. This could potentially be used with hooks to add information to this table which your command or other hooks could consume.

    GetArgument: (self: CommandContext, index: number) -> ArgumentContext, -- Get an argument by index
    GetData: (self: CommandContext) -> any, -- Returns the command data that was sent along with the command. This is the return value of the Data function from the command definition.
    GetStore: (self: CommandContext, name: string) -> table, -- Returns a table of the given name. Always returns the same table on subsequent calls. Useful for storing things like ban information. Same as Registry.GetStore.
    SendEvent: (self: CommandContext, player: Player, event: string, ...any) -> (),
    BroadcastEvent: (self: CommandContext, event: string, ...any) -> (),
    Reply: (self: CommandContext, message: string, color: Color3?) -> (), -- Prints the given text in the user's console. Useful for when a command needs to print more than one message or is long-running. You should still return a string from the command implementation when you are finished, Reply should only be used to send additional messages before the final message.
    HasImplementation: (self: CommandContext) -> boolean,
}



--[=[
    @within CmdrTypes
    @interface CommandArgument
    .Type string | TypeDefinition -- The argument type (case sensitive), or an inline TypeDefinition object
    .Name string -- The argument name, this is displayed to the user as they type.
    .Description string -- A description of what the argument is, this is also displayed to the user.
    .Optional boolean? -- If this is present and set to `true`, then the user can run the command without filling out this value. The argument will be sent to your commands as `nil`.
    .Default any? -- If present, the argument will be optional and if the user doesn't supply a value, your function will receive whatever you set this to. Default being set implies `Optional = true`, so Optional can be omitted.
]=]
export type CommandArgument = {
    Type: string | TypeDefinition,
    Name: string,
    Description: string,
    Optional: boolean?,
    Default: any?,
}

--[=[
    @within CmdrTypes
    @interface CommandDefinition
    .Name string
    .Description string
    .Aliases {string}
    .Group any?
    .Args {CommandArgument | (context: CommandContext) -> CommandArgument}
    .Data ((context: CommandContext, ...any) -> any)?
    .AutoExec {string}?
    .ClientRun ((context: CommandContext, ...any) -> string?)?

    | Field | Description |
    | ----- | ----------- |
    | Name | The name that's in auto complete and displayed to user. |
    | Description | A description of the command which is displayed to the user. |
    | Aliases | Aliases that are not in the autocomplete, but if matched will run this command just the same. For example, `m` might be an alias of `announce`. |
    | Group | The group this command is a part of |
    | Args | Array of `CommandArgument` objects, or functions that return `CommandArgument` objects. |
    | Data | If your command needs to gather some extra data from the client that's only available on the client, then you can define this function. It should accept the CommandContext for the current command as an argument, and return a single value which will be available in the command with `CommandContext.GetData`. |
    | AutoExec | A list of commands to run automatically when this command is registered at the start of the game. This should primarily be used to register any aliases regarding this command with the built-in `alias` command, but can be used for initializing state as well. Command execution will be deferred until the end of the frame. |
    | ClientRun | An optional function to be run from the executing client |
]=]
export type CommandDefinition = {
    Name: string,
    Description: string,
    Aliases: {string}?,
    Group: any?,
    Args: {CommandArgument | (context: CommandContext) -> CommandArgument},
    Data: ((context: CommandContext, ...any) -> any)?,
    AutoExec: {string}?,
    ClientRun: ((context: CommandContext, ...any) -> string?)?,
}

export type CommandModuleData = CommandDefinition & {
    ServerRun: ((context: CommandContext, ...any) -> string?)?,
}

return {}