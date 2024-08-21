--!strict
-- Authors: Logan Hunt [Raildex]
-- February 21, 2023
--[=[
    @class ClientCustomRemote
    @client
    @unreleased
    @ignore

    Serves as a middleware for handling RemoteObject RemoteEvents.

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

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// References //--
local Import = require(ReplicatedStorage.Orion.Import)

--// Requires //--
local Signal = Import("Signal")
local Symbol = Import("Symbol")
local NetWire = Import("NetWire")

local KEY_NAME = Symbol("Name")
local KEY_REPLICATOR = Symbol("Replicator")
local KEY_INBOUND_EVENT = Symbol("InboundEvent")
local KEY_IS_UNRELIABLE = Symbol("IsUnreliable")

type Connection = any

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local ClientCustomRemote = {}
ClientCustomRemote.__index = ClientCustomRemote
ClientCustomRemote.__call = function(remote, ...)
    local CTR = remote[KEY_REPLICATOR]
    local name = remote[KEY_NAME]
    local wire = NetWire.Client("TableReplicator")
    return wire:RedirectFunction(CTR:GetServerId(), name, ...)
end

function ClientCustomRemote.new(remoteName: string, replicator: any, isUnreliable: boolean?)
    local self = setmetatable({}, ClientCustomRemote)
    self[KEY_NAME] = remoteName
    self[KEY_REPLICATOR] = replicator
    self[KEY_INBOUND_EVENT] = Signal.new()
    self[KEY_IS_UNRELIABLE] = isUnreliable
    return self
end

function ClientCustomRemote:Destroy()
    self[KEY_INBOUND_EVENT]:Destroy()
    self[KEY_INBOUND_EVENT] = nil
    self[KEY_REPLICATOR] = nil
    self[KEY_NAME] = nil
    setmetatable(self, nil)
end

--[=[
    @private
]=]
function ClientCustomRemote:_FireClient(...: any)
    self[KEY_INBOUND_EVENT]:Fire(...)
end

--[=[
    Fires to the server
]=]
function ClientCustomRemote:Fire(...: any)
    local ReplicatorWire = NetWire.Client("TableReplicator")

    local id, name = self[KEY_REPLICATOR]:GetServerId(), self[KEY_NAME]
    if self:IsUnreliable() then
        ReplicatorWire.NetworkUnreliableEvent:Fire(id, name, ...)
    else
        ReplicatorWire.NetworkEvent:Fire(id, name, ...)
    end
end

--[=[
    Fires this as an unreliable event to the server
]=]
function ClientCustomRemote:FireUnreliable(...: any)
    local ReplicatorWire = NetWire.Client("TableReplicator")

    --assert(self[KEY_IS_UNRELIABLE], "This remote is not unreliable")
    local id, name = self[KEY_REPLICATOR]:GetServerId(), self[KEY_NAME]
    ReplicatorWire.NetworkUnreliableEvent:Fire(id, name, ...)
end

--[=[
    @ignore
    Returns whether or not this remote is unreliable
]=]
function ClientCustomRemote:IsUnreliable(): boolean
    return self[KEY_IS_UNRELIABLE] == true
end

--[=[
    Connects to the event and waits for the server to fire to the client
]=]
function ClientCustomRemote:Connect(callback: (...any) -> ()): Connection
    return self[KEY_INBOUND_EVENT]:Connect(callback)
end

--[=[
    Connects to the event and waits for the server to fire to the client
    one time and then disconnects
]=]
function ClientCustomRemote:Once(callback: (...any) -> ()): Connection
    return self[KEY_INBOUND_EVENT]:Once(callback)
end

--[=[
    Waits for any or a specified client to fire to the server
]=]
function ClientCustomRemote:Wait(): (...any)
    return self[KEY_INBOUND_EVENT]:Wait()
end

export type ClientCustomRemote = typeof(ClientCustomRemote.new("Test", nil, false))

return ClientCustomRemote
