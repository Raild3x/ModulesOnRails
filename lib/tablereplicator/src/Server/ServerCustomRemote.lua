--!strict
-- Authors: Logan Hunt [Raildex]
-- February 21, 2023
--[=[
    @class ServerCustomRemote
    @server
    @unreleased

    Serves as a middleware for handling RemoteObject RemoteEvents

    This class is not intended for end user usage. It is used internally by the TableReplicator class.
]=]

--[[
    [API]
    .new(index: string, replicator: TableReplicator, isUnreliable: boolean?)
    :Destroy()
    :Fire(player: Player, ...any)
    :FireAll(...any)
    :FireExcept(ignoredPlayers: Player | {Player}, ...any)
    :FirePredicate(predicate: (plr: Player, T...) -> boolean, ...: T...)
    :Connect(fn: (...any) -> ()) -> Connection
    :Wait(predicate: (Player | Predicate)?) -> (Player, ...any)
]]

--// Requires //--
local Packages = script.Parent.Parent.Parent
local Signal = require(Packages.Signal)
local Symbol = require(Packages.Symbol)
local NetWire = require(Packages.NetWire)

local KEY_NAME = Symbol("Name")
local KEY_REPLICATOR = Symbol("Replicator")
local KEY_INBOUND_EVENT = Symbol("InboundEvent")
local KEY_IS_UNRELIABLE = Symbol("IsUnreliable")

type Predicate = (plr: Player, ...any) -> boolean
type Connection = any

local function GetActiveReplicationTargetsDictionary(self)
    return self[KEY_REPLICATOR]._Replication.Active
end

local function WarnIfPendingPlayer(self, plr: Player)
    local replicator = self[KEY_REPLICATOR]
    if replicator._Replication.Pending[plr] then
        warn("Requested Fire to player: "..plr.Name.." but they are not yet replicated!")
    end
end

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local ServerCustomRemote = {}
ServerCustomRemote.__index = ServerCustomRemote

function ServerCustomRemote.new(remoteName: string, replicator: any, isUnreliable: boolean?)
    local self = setmetatable({
        [KEY_REPLICATOR] = replicator,
        [KEY_NAME] = remoteName,
        [KEY_INBOUND_EVENT] = Signal.new(),
        [KEY_IS_UNRELIABLE] = isUnreliable,
    }, ServerCustomRemote)

    return self
end

function ServerCustomRemote:Destroy()
    self[KEY_INBOUND_EVENT]:Destroy()
    self[KEY_INBOUND_EVENT] = nil
    self[KEY_REPLICATOR] = nil
    self[KEY_NAME] = nil
    setmetatable(self, nil)
end

-- Not intended for end user usage
function ServerCustomRemote:_FireServer(player: Player, ...: any)
    self[KEY_INBOUND_EVENT]:Fire(player, ...)
end

--[=[
    Fires to a specific client
]=]
function ServerCustomRemote:Fire(player: Player, ...: any)
    --print(self[KEY_NAME],"Firing to player: "..player.Name, ...)
    if not (player and typeof(player) == "Instance" and player:IsA("Player")) then
        if typeof(player) == "table" then
            error("RE MISSING PLAYER! Did you mean to use FireExcept?")
        elseif typeof(player) == "function" then
            error("RE MISSING PLAYER! Did you mean to use FirePredicate?")
        end
        error("RE MISSING PLAYER! Did you mean to use FireAll?")
    end

    local ReplicatorWire = NetWire.Server("TableReplicator")

    WarnIfPendingPlayer(self, player)

    local id, name = self[KEY_REPLICATOR]:GetId(), self[KEY_NAME]
    if self[KEY_IS_UNRELIABLE] then
        ReplicatorWire.NetworkUnreliableEvent:Fire(player, id, name, ...)
    else
        ReplicatorWire.NetworkEvent:Fire(player, id, name, ...)
    end
end

--[=[
    Returns whether or not this remote is unreliable
]=]
function ServerCustomRemote:IsUnreliable(): boolean
    return self[KEY_IS_UNRELIABLE] == true
end

--[=[
    Fires to all currently replicated clients
]=]
function ServerCustomRemote:FireAll(...: any)
    --print(self[KEY_NAME],"Firing to all players: ", ...)
    local replicator = self[KEY_REPLICATOR]
    for player: Player in replicator._Replication.Pending do
        WarnIfPendingPlayer(self, player)
    end

    for player: Player in GetActiveReplicationTargetsDictionary(self) do
        self:Fire(player, ...)
    end
end

--[=[
    Fires to all currently replicated clients except the ones specified
]=]
function ServerCustomRemote:FireExcept(ignoredPlayers: Player | {Player}, ...: any)
    if typeof(ignoredPlayers) == "Instance" then
        assert(ignoredPlayers:IsA("Player"), "Invalid ignoredPlayer type!")
        ignoredPlayers = {ignoredPlayers}
    end
    assert(ignoredPlayers and typeof(ignoredPlayers) == "table", "Invalid ignoredPlayer type!")
    
    for player: Player in GetActiveReplicationTargetsDictionary(self) do
        if not table.find(ignoredPlayers, player) then
            self:Fire(player, ...)
        end
    end
end

--[=[
    Fires to all currently replicated clients that pass the predicate test
]=]
function ServerCustomRemote:FirePredicate(predicate: Predicate, ...: any)
    for player: Player in GetActiveReplicationTargetsDictionary(self) do
        if predicate(player, ...) then
            self:Fire(player, ...)
        end
    end
end

--[=[
    Connects to the event and waits for a replicated client to fire to the server
]=]
function ServerCustomRemote:Connect(callback: (Player: Player, ...any) -> ()): Connection
    return self[KEY_INBOUND_EVENT]:Connect(callback)
end

--[=[
    Connects to the event and waits for a replicated client to fire to the server 
    one time and then disconnects
]=]
function ServerCustomRemote:Once(callback: (Player: Player, ...any) -> ()): Connection
    return self[KEY_INBOUND_EVENT]:Once(callback)
end

--[=[
    Waits for any or a specified client to fire to the server
]=]
function ServerCustomRemote:Wait(predicate: (Player | Predicate)?): (Player, ...any)
    if predicate then
        if typeof(predicate) == "function" then
            local results
            repeat
                results = table.pack(self[KEY_INBOUND_EVENT]:Wait())
            until predicate(results[1], table.unpack(results, 2))
            return table.unpack(results)
        else
            local player: Player = predicate
            assert(typeof(player) == "Instance" and player:IsA("Player"), "Invalid 'Player' argument.")
            local results
            repeat
                results = table.pack(self[KEY_INBOUND_EVENT]:Wait())
            until results[1] == player
            return table.unpack(results)
        end
    end
    return self[KEY_INBOUND_EVENT]:Wait()
end

export type ServerCustomRemote = typeof(ServerCustomRemote.new("", nil, false))

return ServerCustomRemote