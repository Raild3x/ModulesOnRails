-- Authors: Logan Hunt (Raildex)
-- May 02, 2024
--[=[
    @class CmdrTypes
    This class is a collection of types used in Cmdr. Some of the comments here may not be entirely accurate.
]=]

type table = {[any]: any}

--[=[
    @within CmdrTypes
    @interface ArgumentContext<T>
    .Command CommandContext<T> -- The command context this argument belongs to.
    .Name string -- The name of the argument
    .Type TypeDefinition<T> -- The type definition of the argument
    .Required boolean -- Whether or not this argument is required
    .Executor Player -- The player that ran the command this argument belongs to.
    .RawValue string -- The raw value of the argument
    .RawSegments {string} -- The raw segments of the argument
    .Prefix string -- The prefix of the argument
]=]
export type ArgumentContext<T> = {
    Command: CommandContext<T>,
    Name: string,
    Type: TypeDefinition<T>,
    Required: boolean, -- Whether or not this argument is required
    Executor: Player, -- The player that ran the command this argument belongs to.
    RawValue: string,
    RawSegments: {string},
    Prefix: string,

    GetValue: (self: ArgumentContext<T>) -> any,
    GetTransformedValue: (self: ArgumentContext<T>, segment: number) -> (any),
} -- https://eryn.io/Cmdr/api/ArgumentContext.html#argumentcontext

--[=[
    @within CmdrTypes
    @interface CommandContext<T>
    .Executor Player -- The player who executed the command
    .Name string -- the name of the command
    .Description string -- the description of the command
    .Alias string -- The specific alias of this command that was used to trigger this command (may be the same as Name)
    .Aliases {string} -- The list of aliases that could have been used to trigger this command
    .Group any -- The group this command is a part of. Defined in command definitions, typically a string.
    .RawText string -- the raw text of the command
    .RawArguments {string} -- the raw arguments of the command
    .Arguments {ArgumentContext<T>} -- the parsed arguments of the command
    .Cmdr table
    .Dispatcher table -- the dispatcher that ran the command
    .State table -- A blank table that can be used to store user-defined information about this command's current execution. This could potentially be used with hooks to add information to this table which your command or other hooks could consume.
]=]
export type CommandContext<T> = {
    Executor: Player, -- The player who executed the command
    Name: string, -- the name of the command
    Description: string, -- the description of the command
    Alias: string, -- The specific alias of this command that was used to trigger this command (may be the same as Name)
    Aliases: {string}, -- The list of aliases that could have been used to trigger this command
    Group: any, -- The group this command is a part of. Defined in command definitions, typically a string.
    RawText: string, -- the raw text of the command
    RawArguments: {string}, -- the raw arguments of the command
    Arguments: {ArgumentContext<T>}, -- the parsed arguments of the command
    Cmdr: table,
    Dispatcher: table, -- the dispatcher that ran the command
    State: table, -- A blank table that can be used to store user-defined information about this command's current execution. This could potentially be used with hooks to add information to this table which your command or other hooks could consume.

    GetArgument: (self: CommandContext<T>, index: number) -> ArgumentContext<T>, -- Get an argument by index
    GetData: (self: CommandContext<T>) -> any, -- Returns the command data that was sent along with the command. This is the return value of the Data function from the command definition.
    GetStore: (self: CommandContext<T>, name: string) -> table, -- Returns a table of the given name. Always returns the same table on subsequent calls. Useful for storing things like ban information. Same as Registry.GetStore.
    SendEvent: (self: CommandContext<T>, player: Player, event: string, ...any) -> (),
    BroadcastEvent: (self: CommandContext<T>, event: string, ...any) -> (),
    Reply: (self: CommandContext<T>, message: string, color: Color3?) -> (), -- Prints the given text in the user's console. Useful for when a command needs to print more than one message or is long-running. You should still return a string from the command implementation when you are finished, Reply should only be used to send additional messages before the final message.
    HasImplementation: (self: CommandContext<T>) -> boolean,
} -- https://eryn.io/Cmdr/api/CommandContext.html#commandcontext

--[=[
    @within CmdrTypes
    @interface TypeDefinition<T>
    .DisplayName string -- The display name of the type
    .Prefixes string -- The prefixes that this type can use
    .Transform (rawText: string, executor: Player) -> any -- A function that transforms the raw text into the desired type
    .Validate (value: T) -> (boolean, string?) -- A function that validates the value. Returns a boolean and an optional error message.
    .ValidateOnce (value: T) -> (boolean, string?) -- A function that validates the value once. Returns a boolean and an optional error message.
    .Autocomplete (value: T) -> ({string}, {IsPartial: boolean?}) -- A function that returns a list of possible completions for the value. Returns a list of strings and an optional boolean indicating if the completions are partial.
    .Parse (value: T) -> any -- A function that parses the value
    .Default (plr: Player) -> string -- A function that returns the default value for the type
    .Listable boolean -- Whether or not this type is listable
]=]
export type TypeDefinition<T> = {
    DisplayName: string,
    Prefixes: string,
    Transform: ((rawText: string, executor: Player) -> any)?,
    Validate: ((value: T) -> (boolean, string?))?,
    ValidateOnce: ((value: T) -> (boolean, string?))?,
    Autocomplete: ((value: T) -> ({string}, {IsPartial: boolean?}))?,
    Parse: (value: T) -> any,
    Default: ((plr: Player) -> string)?,
    Listable: boolean?,
}

--[=[
    @within CmdrTypes
    @interface CommandArgument
    .Type string | TypeDefinition<any> -- The type of the argument
    .Name string -- The name of the argument
    .Description string -- The description of the argument
    .Optional boolean -- Whether or not this argument is optional
    .Default any -- The default value of the argument
]=]
export type CommandArgument = {
    Type: string | TypeDefinition<any>,
    Name: string,
    Description: string,
    Optional: boolean?,
    Default: any?,
}

--[=[
    @within CmdrTypes
    @interface CommandDefinition<T>
    .Name string -- The name of the command
    .Description string -- The description of the command
    .Aliases {string}? -- The aliases of the command
    .Group any? -- The group this command is a part of
    .Args {CommandArgument | (context: CommandContext<T>) -> CommandArgument} -- The arguments of the command
    .Data ((context: CommandContext<T>, ...any) -> any)? -- The data of the command
    .AutoExec {string}? -- The autoexec of the command
    .ClientRun ((context: CommandContext<T>, ...any) -> string?)? -- The client run of the command
]=]
export type CommandDefinition<T> = {
    Name: string,
    Description: string,
    Aliases: {string}?,
    Group: any?,
    Args: {CommandArgument | (context: CommandContext<T>) -> CommandArgument},
    Data: ((context: CommandContext<T>, ...any) -> any)?,
    AutoExec: {string}?,
    ClientRun: ((context: CommandContext<T>, ...any) -> string?)?,
}

export type CommandModuleData<T> = CommandDefinition<T> & {
    ServerRun: ((context: CommandContext<T>, ...any) -> string?)?,
}

return {}