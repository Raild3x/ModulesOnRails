-- Authors: Logan Hunt (Raildex)
-- January 04, 2024
--[=[
    @class ServerTableReplicator
    @server

    ServerTableReplicator handles replication of a given TableManager object to the client.
    This system very closely follows the idea behind ReplicaService and should be familiar to
    anyone who has used it.

    Inherits from BaseTableReplicator. See BaseTableReplicator for inherited methods.
]=]

--// Services //--
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local RailUtil = require(Packages.RailUtil)
local TableManager = require(Packages.TableManager)
local Symbol = require(Packages.Symbol)
local Signal = require(Packages.Signal)
local NetWire = require(Packages.NetWire)
local ServerCustomRemote = require(script.Parent.ServerCustomRemote)
local TableReplicatorUtil = require(script.Parent.Parent.Shared.TableReplicatorUtil)
local BaseTableReplicator = require(script.Parent.Parent.Shared.BaseTableReplicator)


type ServerCustomRemote = ServerCustomRemote.ServerCustomRemote
type TableManager = TableManager.TableManager
type ReplicationToken = TableReplicatorUtil.ReplicationToken
type TRPacket = TableReplicatorUtil.TRPacket
type Tags = TableReplicatorUtil.Tags
type Id = BaseTableReplicator.Id

type table = {[any]: any}
type CreationData = table
type CanBeArray<T> = T | {T}


local USED_CLASS_TOKENS: {string} = {}

local KEY_SELF = Symbol("SelfReference")
local KEY_REMOTE_SIGNALS = Symbol("RemoteSignals")
local KEY_REMOTE_FUNCTIONS = Symbol("RemoteFunctions")


local ClassTokenMT = table.freeze {
    __tostring = function(self)
        return `ReplicationToken<{self.Name}>`
    end;
}

local ClientMT = table.freeze {
    -- __index = function(t, key)
    --     local self = t[KEY_SELF]
    --     local clientFn = self.Client[key]
    --     if clientFn then
    --         return function(...)
    --             return clientFn(self, ...)
    --         end
    --     end
    -- end;
    __newindex = function(t, k, v)
        local self = t[KEY_SELF]
        if self._ClassToken then
            warn("Avoid adding new remotes to STR after it is fully initialized. ", k, v)
        end
		if type(v) == "table" and v[1] == NetWire.createEvent()[1] then
			self:RegisterRemoteSignal(k)
		elseif type(v) == "table" and v[1] == NetWire.createUnreliableEvent()[1] then
			self:RegisterRemoteUnreliableSignal(k)
		elseif type(v) == "function" then
			self:RegisterRemoteFunction(k, v)
		else
			warn("Invalid Client remote data. Expected function or NetWire.createEvent(). ", k, v)
		end
    end
}

local AddedActivePlayerSignal = Signal.new()
local RemovedActivePlayerSignal = Signal.new()

--[=[
    @within ServerTableReplicator
    @type ReplicationTargets "All" | Player | {Player}
    The Player(s) that the STR should replicate to.
    If "All" is given then the STR will replicate to all current and future players.
]=]
export type ReplicationTargets = "All" | Player | {Player}



--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local SwapRemoveFirstValue = RailUtil.Table.SwapRemoveFirstValue

-- local function FormatRemoteSignalName(signalName: string): string
--     return REMOTE_SIGNAL_PREFIX..signalName
-- end

-- Runs a function on a STR and all of its descendant STRs
local function ParseBranch(STR, fn)
    fn(STR)
    for _, child in pairs(STR:GetChildren()) do
        ParseBranch(child, fn)
        -- fn(child) -- Is this needed?
    end
end

local function EnsureIsPlayerArray(arr: Player | {Player}): {Player}
    if typeof(arr) == "Instance" then
        return {arr}
    elseif typeof(arr) == "table" then
        return arr
    end
    error("Invalid type for player array: "..typeof(arr))
end

-- Gets a list of what the activeReplicationTargets should be at the moment of calling
local function TargetsToArray(targets: ReplicationTargets): {Player}
    if targets == "All" then
        targets = Players:GetPlayers()
    elseif typeof(targets) == "Instance" then
        targets = {targets}
    elseif targets == nil then
        targets = {}
    end

    assert(typeof(targets) == "table", "Invalid targets type")
    return targets
end

-- Validates the replication targets and returns a formatted list of targets
local function AssertReplicationTargets(targets: ReplicationTargets): ("All" | {Player})
    if typeof(targets) == "table" then
        for _, target in pairs(targets) do
            assert(typeof(target) == "Instance", "Invalid replication target. Expected Instance")
            assert(target:IsA("Player"), "Invalid replication target. Expected Player")
        end
    end

    local isPlayer = if typeof(targets) == "Instance" then targets:IsA("Player") else false
    if isPlayer then -- wrap the player into an array so we dont have to check for it later
        targets = {targets}
    end
    
    assert(targets == "All" or isPlayer or typeof(targets) == "table", "Invalid replication targets")

    return targets :: ("All" | {Player})
end

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local ServerTableReplicator = setmetatable({}, BaseTableReplicator)
ServerTableReplicator.ClassName = "ServerTableReplicator"
ServerTableReplicator.__index = ServerTableReplicator

ServerTableReplicator.createRemoteEvent = NetWire.createEvent
ServerTableReplicator.createRemoteProperty = NetWire.createProperty


--[=[
    @within ServerTableReplicator
    @prop AddedActivePlayer Signal<Player>
    A signal that fires whenever a player starts being replicated to.
    This happens when their client requests the current data from the server.
]=]
ServerTableReplicator.AddedActivePlayer = AddedActivePlayerSignal

--[=[
    @private
    @within ServerTableReplicator
    @prop RemovedActivePlayer Signal<Player>
    A signal that fires whenever a player stops being replicated to.
    This happens when the player leaves the game.
]=]
ServerTableReplicator.RemovedActivePlayer = RemovedActivePlayerSignal

--------------------------------------------------------------------------------
    --// Core Replication Initialization //-- (Dont touch anything in here)
--------------------------------------------------------------------------------
-- The Player's whose data is being replicated
local ACTIVE_PLAYERS: {[Player]: boolean?} = {}

local Replicator = NetWire.Server("TableReplicator")
Replicator.TR_Create = NetWire.createEvent()
Replicator.TR_Destroy = NetWire.createEvent()

Replicator.ValueChanged = NetWire.createEvent()
Replicator.ArraySet = NetWire.createEvent()
Replicator.ArrayInsert = NetWire.createEvent()
Replicator.ArrayRemove = NetWire.createEvent()

Replicator.TR_SetParent = NetWire.createEvent()
Replicator.NetworkEvent = NetWire.createEvent() -- TODO: Implement network events per TR
--Replicator.NetworkUnreliableEvent = NetWire.createUnreliableEvent() -- TODO: Implement network events per TR

local function NetworkEventConnect(player: Player, id: Id, signalName: string, ...)
    if not ACTIVE_PLAYERS[player] then
        return -- Player is not being replicated to
    end

    if typeof(id) ~= "number" then
        error("Invalid STR id type. Expected: 'number', Got: '" .. typeof(id) .. "'")
    end

    local STR = ServerTableReplicator.getFromServerId(id)
    if STR then
        local signal = STR[KEY_REMOTE_SIGNALS][signalName]
        assert(signal, "Unregistered remote signal name: "..signalName)
        signal:_FireServer(player, ...)
    else
        error("Invalid STR id: "..tostring(id))
    end
end

Replicator.NetworkEvent:Connect(NetworkEventConnect)
--Replicator.NetworkUnreliableEvent:Connect(NetworkEventConnect)

function Replicator:RequestServerData(player: Player)
    if ACTIVE_PLAYERS[player] then
        return -- Player is already being replicated to
    end

    -- Move player from pending replication to active replication for each object
    for _, STR in ServerTableReplicator do
        if STR:IsReplicationTarget(player) then
            STR._Replication.Pending[player] = nil
            STR._Replication.Active[player] = true
            -- print("Moving player from pending to active replication for STR: ", STR:GetId(), STR)
        -- else
            -- print("Player is not a replication target for STR: ", STR:GetId(), STR)
        end
    end
      
    -- Replicate all data to the player in a bulk packet
    local STR_Bulk_Packet: {TRPacket} = {}
    for _, STR in ServerTableReplicator do
        if STR:IsTopLevel() and STR:IsReplicationTarget(player) then
            table.insert(STR_Bulk_Packet, {STR:GetId(), STR._CreationData})
        end
    end

    -- send all current data to the player
    Replicator.TR_Create:Fire(player, STR_Bulk_Packet)

    ACTIVE_PLAYERS[player] = true
    AddedActivePlayerSignal:Fire(player)
end


function Replicator:RedirectFunction(player: Player, id: Id, fnName: string, ...: any)
    local STR = ServerTableReplicator.getFromServerId(id)
    if not STR then
        error("Invalid STR id: "..tostring(id))
    end
    return STR.Client[fnName](STR, player, ...)
end

Players.PlayerRemoving:Connect(function(player: Player)
    for _, STR in ServerTableReplicator do
        local replication = STR._Replication
        replication.Pending[player] = nil
        replication.Active[player] = nil
    end

    ACTIVE_PLAYERS[player] = nil
    RemovedActivePlayerSignal:Fire(player)
end)

--------------------------------------------------------------------------------
    --// Class Static Methods //--
--------------------------------------------------------------------------------

--[=[
    Returns a Token Symbol that is used for identifying the ServerTableReplicator Class.
    We use unique symbols instead of strings to prevent accidental collisions on the server.
    
    :::warning
    This may only be called once per unique string. The returned symbol should
    be used repeatedly instead of calling this function again. Calling this
    function again with the same string will result in an error.
    :::
]=]
function ServerTableReplicator.Token(tokenName: string): ReplicationToken
    assert(type(tokenName) == "string", `Invalid token type. Expected: 'string', Got: '{typeof(tokenName)}'`)
    assert(#tokenName > 0, "ReplicationToken name cannot be empty")

    local existingToken = table.find(USED_CLASS_TOKENS, tokenName)
    if existingToken then
        error(`Class Token '{tokenName}' already exists. Created at: \n{existingToken.Creation}`)
    end
    
    local token = {
        Name = tokenName,
        Creation = debug.traceback(),
    }
    setmetatable(token, ClassTokenMT)
    table.freeze(token)

    table.insert(USED_CLASS_TOKENS, tokenName)
    return token :: any
end
-- Deprecated Aliases. Kept for backwards compat
ServerTableReplicator.newClassToken = ServerTableReplicator.Token
ServerTableReplicator.createClassToken = ServerTableReplicator.Token

--[=[
    Creates a new ServerTableReplicator instance.
    The config must be given a TableManager instance and a Token Symbol.

    A list of replication targets can be provided to specify which
    players the STR should replicate to immediately. If no replication targets
    are specified, the STR will not replicate to any players.

    You can specify a Parent STR instead of giving ReplicationTargets and it will
    inherit the replication targets of the top level STR.

    Optionally, a list of tags can be provided to help identify the STR. The
    tags list will become immutable internally after the STR is created.

    EXAMPLE:
    ```lua
    -- Some Server Script
    local token = ServerTableReplicator.Token("PlayerData")

    Players.PlayerAdded:Connect(function(player)
        local manager = TableManager.new({
            Money = math.random(1, 100);
        })

        local replicator = ServerTableReplicator.new({
            TableManager = manager,
            Token = token,
            ReplicationTargets = "All",
            Tags = {UserId = player.UserId},
        })
    end)
    ```
    ```lua
    -- Some Client Script
    ClientTableReplicator.onNew("PlayerData", function(replicator)
        print("New PlayerData STR: ", replicator:GetTag("UserId"))
        print("Money: ", replicator:GetTableManager():Get("Money"))
    end)
    ```

    :::warning Top Level Replicators
    A replicator must be given either a Parent Replicator or a list of ReplicationTargets.
    If both are given then it will produce an error.

    If you give ReplicationTargets then that Replicator will be known as TopLevel. Only
    TopLevel Replicators can have their ReplicationTargets manually changed.

    If a Parent Replicator is given, the Child Replicator will inherit the replication targets of the Ancestor
    TopLevel Replicator.
    :::
]=]
function ServerTableReplicator.new(config: {
    Token: ReplicationToken,
    TableManager: TableManager,
    ReplicationTargets: ReplicationTargets?,
    Parent: ServerTableReplicator?,
    Tags: {[string]: any}?,
    Client: {[string]: any}?,
})

    --// Validate Config //--
    local cToken = config.Token or (config :: any).ClassToken
    if type(cToken) == "string" then
        warn(`ClassToken '{cToken :: string}' given as string. To silence, use 'ServerTableReplicator.Token' to provide a ClassToken Symbol`)
        if not table.find(USED_CLASS_TOKENS, cToken) then
            warn(`Registering ClassToken '{cToken :: string}' . . .`)
            cToken = ServerTableReplicator.Token(cToken :: string)
        else
            error("ClassToken already registered. Expected ClassToken Symbol, Got: "..tostring(cToken))
        end
    end
    assert(typeof(cToken) == "table" and cToken.Name, "Invalid class token. Expected ClassToken Symbol, Got: "..tostring(cToken))

    -- Validate Parent and ReplicationTargets
    local parent = config.Parent
    local repTargets = config.ReplicationTargets
    if parent then
        assert(not parent.IsDestroyed, "Parent already Destroyed")
        assert(parent.ClassName == "ServerTableReplicator", "Parent must be a STR")
        assert(not repTargets, "Cannot specify replication targets when creating a child STR")
        
    else
        if not repTargets then
            warn("ReplicationTargets set to 'nil', give '{}' instead to silence or pass a 'Parent' if it is not a Top Level Replicator.")
        end
        repTargets = AssertReplicationTargets(repTargets or {})
    end

    -- Validate Client Table
    assert(not config.Client or type(config.Client) == "table", "Invalid Client config. Expected table")

    -- Handle data defaults
    if not config.TableManager then
        warn("No TableManager was provided. Creating an empty TableManager")
        config.TableManager = TableManager.new({})
    elseif config.TableManager.ClassName ~= TableManager.ClassName then
        config.TableManager = TableManager.new(config.TableManager)
    end

    --// !Create Instance! //--
    local self = setmetatable(BaseTableReplicator.new({
        TableManager = config.TableManager;
        Tags = config.Tags;
        IsTopLevel = parent ~= nil;
    }), ServerTableReplicator)


    local creationData
    local replication
    do
        if parent then
            creationData = parent._CreationData
            replication = parent._Replication
        else
            creationData = {}
            replication = {Active = {}, Pending = {}}
        end
    
        -- The creation data for this STR
        local individualCreationData = {
            if parent then parent:GetId() else nil; -- [1] = ParentId?
            cToken.Name; -- [2] = ClassTokenName
            self._Tags; -- [3] = Tags
            self:GetTableManager():_GetRawData(); -- [4] = TableManagerData
        }
        creationData[tostring(self:GetId())] = individualCreationData
    end
    

    --// Initialize Properties //--
    self[KEY_REMOTE_SIGNALS] = {}
    self[KEY_REMOTE_FUNCTIONS] = {}

    self.Client = setmetatable({
        [KEY_SELF] = self;
    }, ClientMT)
	-- register the client functions and signals
    for k, v in pairs(config.Client or {}) do
        self.Client[k] = v
    end

    self._ClassToken = cToken
    self._CreationData = creationData

    self._Parent = parent :: ServerTableReplicator?
    
    self._Replication = replication  :: {
        All: boolean?;
        Active: {[Player]: boolean?};
        Pending: {[Player]: boolean?};
    }


    --// Handle Initialization //--
    self:_InitListeners()

    if not parent then
        self:RegisterSignal("ReplicationTargetsChanged")
        self:SetReplicationTargets(repTargets)
    else
        table.insert(parent._Children, self)
        parent:FireSignal("ChildAdded", self)
        Replicator.TR_Create:FireFor(self:GetActiveReplicationTargets(), self:GetId(), creationData[tostring(self:GetId())])
    end

    self:_FireCreationListeners()

    return self
end


--[=[
    Destroys the Replicator on both the Server and any replicated Clients
]=]
function ServerTableReplicator:Destroy()
    if self:IsTopLevel() then
        self:SetReplicationTargets({})
    end
    getmetatable(ServerTableReplicator).Destroy(self)
end

--------------------------------------------------------------------------------
    --// Private //--
--------------------------------------------------------------------------------

--[=[
    @private
]=]
function ServerTableReplicator:_InitListeners()
    self:AddTask(self:GetTableManager():GetDestroyedSignal():Once(function()
        self:Destroy()
    end))

    ------------------------------------
    --// Data Replication Handling //--
    ------------------------------------
    local TR_Wire = NetWire.Server("TableReplicator")

    local function ConnectToSignal(signalName: string, fn)
        return self:AddTask(self._TableManager:GetSignal(signalName):Connect(fn))
    end

    ConnectToSignal("ValueChanged", function(path, newValue, _)
        for _, target in self:GetActiveReplicationTargets() do
            TR_Wire.ValueChanged:Fire(target, self:GetId(), path, newValue)
        end
    end)

    ConnectToSignal("ArraySet", function(path, index: number, newValue: any, _)
        for _, target in self:GetActiveReplicationTargets() do
            TR_Wire.ArraySet:Fire(target, self:GetId(), path, index, newValue)
        end
    end)

    ConnectToSignal("ArrayInsert", function(path, index: number, insertedValue: any, _)
        for _, target in self:GetActiveReplicationTargets() do
            TR_Wire.ArrayInsert:Fire(target, self:GetId(), path, index, insertedValue)
        end
    end)

    ConnectToSignal("ArrayRemove", function(path, index: number, _, _)
        for _, target in self:GetActiveReplicationTargets() do
            TR_Wire.ArrayRemove:Fire(target, self:GetId(), path, index)
        end
    end)
end

--[=[
    @private
    Serializes the STR into a packet that can be sent to the client.
]=]
function ServerTableReplicator:_GeneratePacket(): TRPacket
    return {
        self:GetId(),
        self._ClassToken.Name,
        self._Tags,
        self:GetTableManager():_GetRawData()
    }
end

--[=[
    @private
    Tells the client to stop replicating to the targets.
]=]
function ServerTableReplicator:_StopReplicatingToTargets(targets: CanBeArray<Player>)
    local plrArray = EnsureIsPlayerArray(targets)

    local pending = self._Replication.Pending
    local active = self._Replication.Active

    for _, player in pairs(plrArray) do
        assert(player:IsA("Player"), "Invalid replication target. Expected Player")
        if pending[player] then
            pending[player] = nil
        elseif active[player] then
            active[player] = nil
            Replicator.TR_Destroy:Fire(player, self:GetId())
        end
    end
end

--[=[
    @private
    Tries to immediately replicate to the targets if not replicated already.
]=]
function ServerTableReplicator:_StartReplicatingToTargets(targets: CanBeArray<Player>)
    local plrArray = EnsureIsPlayerArray(targets)

    local packet = self._CreationData

    local pending = self._Replication.Pending
    local active = self._Replication.Active

    for _, player in pairs(plrArray) do
        if active[player] then
            warn(`Attempted to replicate to player {player.Name} that is already being replicated to`)
            continue
        elseif pending[player] then
            warn(`Attempted to replicate to a player {player.Name} that is already pending replication`)
            continue
        end
    
        if ACTIVE_PLAYERS[player] then
            active[player] = true

            Replicator.TR_Create:Fire(player, self:GetId(), packet)
        else
            pending[player] = true
        end
    end
end

--------------------------------------------------------------------------------
    --// Public Methods //--
--------------------------------------------------------------------------------

 --[=[
    @private
    @unreleased
    Registers a new reliable remote signal.
 ]=]
 function ServerTableReplicator:RegisterRemoteSignal(signalName: string)
	assert(not self[KEY_REMOTE_SIGNALS][signalName], "Remote signal already registered: "..signalName)
	local Remote = self:AddTask(ServerCustomRemote.new(signalName, self))
	self[KEY_REMOTE_SIGNALS][signalName] = Remote
	rawset(self.Client, signalName, Remote)
	return Remote
 end

--[=[
    @private
    @unreleased
    Registers a new unreliable remote signal.
]=]
function ServerTableReplicator:RegisterRemoteUnreliableSignal(signalName: string)
    assert(not self[KEY_REMOTE_SIGNALS][signalName], "Remote signal already registered: "..signalName)
    local Remote = self:AddTask(ServerCustomRemote.new(signalName, self, true))
	self[KEY_REMOTE_SIGNALS][signalName] = Remote
	rawset(self.Client, signalName, Remote)
    return Remote
end

--[=[
    @private
    @unreleased
    Gets an existing RemoteSignal by name. Can be either reliable or unreliable.
]=]
function ServerTableReplicator:GetRemoteSignal(signalName: string): ServerCustomRemote
    local remoteSignal = self[KEY_REMOTE_SIGNALS][signalName]
    assert(remoteSignal, "Remote signal not registered: "..signalName)
    return remoteSignal :: any
end

--[=[
    @private
    @unreleased
]=]
function ServerTableReplicator:RegisterRemoteFunction(fnName: string, fn: (...any) -> ...any)
    local remoteFn = self[KEY_REMOTE_FUNCTIONS][fnName]
    assert(not remoteFn, "Remote function already registered: "..fnName)
    rawset(self.Client, fnName, fn)
	return fn
end

--------------------------------------------------------------------------------
    --// Setters //--
--------------------------------------------------------------------------------

--[=[
    Adds a player or list of players to the replication targets.
]=]
function ServerTableReplicator:Subscribe(targets: ReplicationTargets)
    if typeof(targets) == "Instance" then
        if self:IsReplicationTarget(targets) then
            warn("No Change") -- No change
            return
        end
    end

    if not self:IsReplicatingToAll() then
        if targets == "All" then
            -- warn("Use :SetReplicationTargets(\"All\") instead of :ReplicateFor(\"All\")")
            self:SetReplicationTargets("All")
        else
            local targetsArray = TargetsToArray(AssertReplicationTargets(targets))

            local newTargets = self:GetReplicationTargets()
            for _, target in pairs(targetsArray) do
                if not table.find(newTargets, target) then
                    table.insert(newTargets, target)
                end
            end

            self:SetReplicationTargets(newTargets)
        end
    else
        if targets ~= "All" then
            error("Don't selectively replicate for clients when STR is replicated to 'All' - :DestroyFor(\"All\") first")
        end
    end
end
ServerTableReplicator.ReplicateFor = ServerTableReplicator.Subscribe

--[=[
    Removes a player or list of players from the replication targets.
]=]
function ServerTableReplicator:Unsubscribe(targets: ReplicationTargets)
    if typeof(targets) == "Instance" then
        if not self:IsReplicationTarget(targets) then
            warn("No Change")-- No change
            return 
        end
    end

    if not self:IsReplicatingToAll() then
        if targets == "All" then
            --warn("Use :SetReplicationTargets({}) instead of :DestroyFor(\"All\")")
            self:SetReplicationTargets({})
        else
            local targetsArray = TargetsToArray(AssertReplicationTargets(targets))

            local newTargets = self:GetReplicationTargets()
            for _, target in pairs(targetsArray) do
                RailUtil.Table.SwapRemoveFirstValue(newTargets, target)
            end

            self:SetReplicationTargets(newTargets)
        end

    else -- if we are currently replicating to all players
        if targets ~= "All" then -- we request to destroy for a specific player[s]
            error("Don't selectively destroy for clients when STR is replicated to 'All' - use :DestroyFor(\"All\") first")
        end

        self:SetReplicationTargets({})
    end
end
ServerTableReplicator.DestroyFor = ServerTableReplicator.Unsubscribe

--[=[
    Overwrites the current replication targets with the new targets.
]=]
function ServerTableReplicator:SetSubscribers(targets: ReplicationTargets)
    assert(self:IsTopLevel(), "Cannot set replication targets on a child STR")
    if typeof(targets) == "nil" then
        warn("Please pass an empty array instead of nil to remove all replication targets")
        targets = {}
    end


    local goalTargets: {Player} = TargetsToArray(targets)
    local currentTargets: {Player} = self:GetReplicationTargets() -- TODO: Optimize this into a dictionary

    if targets == "All" then
        if self:IsReplicatingToAll() then
            return -- No change
        else
            self._Replication.All = true
        end
    else
        self._Replication.All = nil
    end

    local targetsToAdd = {}
    local targetsToRemove = {}

    for _, target in pairs(goalTargets) do
        if not table.find(currentTargets, target) then
            table.insert(targetsToAdd, target)
        end
    end

    for _, target in pairs(currentTargets) do
        if not table.find(goalTargets, target) then
            table.insert(targetsToRemove, target)
        end
    end

    self:_StartReplicatingToTargets(targetsToAdd)
    self:_StopReplicatingToTargets(targetsToRemove)

    --print(self:GetTokenName(), "Replication Targets Changed", targetsToAdd, targetsToRemove)
    self:FireSignal("ReplicationTargetsChanged", targets)
end
ServerTableReplicator.SetReplicationTargets = ServerTableReplicator.SetSubscribers

--------------------------------------------------------------------------------
    --// Getters //--
--------------------------------------------------------------------------------

--[=[
    Checks whether the player is a valid target for replication.
    Not whether the player is currently being replicated to.
]=]
function ServerTableReplicator:IsSubscribed(player: Player): boolean
    if self:IsReplicatingToAll() then
        return true
    elseif self._Replication.Active[player] then
        return true
    elseif self._Replication.Pending[player] then
        return true
    end
    return false
end
ServerTableReplicator.IsReplicationTarget = ServerTableReplicator.IsSubscribed

--[=[
    Returns whether or not this STR is replicating to all current and future players.
]=]
function ServerTableReplicator:IsSubscribedToAll(): boolean
    return self._Replication.All == true
end
ServerTableReplicator.IsReplicatingToAll = ServerTableReplicator.IsSubscribedToAll

--[=[
    Gets the list of Players that this Replicator is attempting to replicate to.
]=]
function ServerTableReplicator:GetSubscribers(): {Player}
    if self:IsReplicatingToAll() then
        return Players:GetPlayers()
    end

    local targets = self:GetActiveReplicationTargets()
    for target in pairs(self._Replication.Pending) do
        table.insert(targets, target)
    end

    return targets
end
ServerTableReplicator.GetReplicationTargets = ServerTableReplicator.GetSubscribers

--[=[
    Gets the list of Players that this Replicator is *currently* replicating to.
    This is different from GetReplicationTargets as it does not include pending replication targets.
]=]
function ServerTableReplicator:GetActiveSubscribers(): {Player}
    local players = {}
    for player in pairs(self._Replication.Active) do
        table.insert(players, player)
    end
    return players
end
ServerTableReplicator.GetActiveReplicationTargets = ServerTableReplicator.GetActiveSubscribers

--------------------------------------------------------------------------------
    --// Misc. Setters //--
--------------------------------------------------------------------------------

--[=[
    Sets the Parent of this STR to the given STR.
]=]
function ServerTableReplicator:SetParent(newParent: ServerTableReplicator)
    assert(not self:IsTopLevel(), "Cannot set parent on a top level STR")
    assert(newParent._Replication, "Invalid parent. Expected STR")

    local oldParent = self:GetParent()
    if newParent == oldParent then
        return -- No change
    end

    do -- Check for circular parenting.
        local currentParent = newParent
        while currentParent do
            currentParent = currentParent:GetParent()
            if currentParent == self then
                error("Cannot Parent a STR to its own descendant")
            end
        end
    end

    self._Parent = newParent
    SwapRemoveFirstValue(oldParent._Children, self)
    table.insert(newParent._Children, self)

    local oldReplication = oldParent._Replication
    local newReplication = newParent._Replication

    if oldReplication ~= newReplication then -- Top level ancestor changed
        local oldCreationData = oldParent._CreationData
        local newCreationData = newParent._CreationData

        self._CreationData = newCreationData

        -- Collect all creation data for this STR and its descendants
        local tempCreationData = {} :: {[string]: CreationData}
        do
            ParseBranch(self, function(transferred)
                local id = tostring(transferred:GetId())
                tempCreationData[id] = oldCreationData[id]

                -- swap references from the old STR to the new STR
                transferred._CreationData = newCreationData
                transferred._Replication = newReplication
            end)
            tempCreationData[tostring(self:GetId())][1] = newParent:GetId() -- Change out the parent Id in the creation data
            
            -- Move all of the affected objects from the old creation data to the new creation data
            for stringId, individualCreationData in pairs(tempCreationData) do
                oldCreationData[stringId] = nil
                newCreationData[stringId] = individualCreationData
            end
        end
        

        -- Inform the clients of the change
        do -- 1) Clients who have this STR and the new parent only need to know the new parent Id
            local ClientsToInform = ACTIVE_PLAYERS
            if not newReplication.All then
                ClientsToInform = newReplication.Active
            elseif not oldReplication.All then
                ClientsToInform = oldReplication.Active
            end

            for player in pairs(ClientsToInform) do
                local shouldInform = (oldReplication.Active[player] or oldReplication.All) and (newReplication.Active[player] or newReplication.All)
                if shouldInform then
                    Replicator.TR_SetParent:Fire(player, self:GetId(), newParent:GetId())
                end
            end
        end
       
        do -- 2) Create a new STR for each client that have the new parent but not the old parent
            local ClientsToReplicateTo = {}

            if not oldReplication.All then
                local playersToCheck = if newReplication.All then ACTIVE_PLAYERS else newReplication.Active
                for player in pairs(playersToCheck) do
                    if not oldReplication.Active[player] then
                        table.insert(ClientsToReplicateTo, player)
                    end
                end
            end

            Replicator.TR_Create:FireFor(ClientsToReplicateTo, self:GetId(), tempCreationData)
        end

        do -- 3) Destroy the STR for each client that have the old parent but not the new parent
            local ClientsToDestroy = {}

            if not newReplication.All then
                local playersToCheck = ACTIVE_PLAYERS
                if not oldReplication.All then
                    playersToCheck = oldReplication.Active
                end

                for player in pairs(playersToCheck) do
                    if not newReplication.Active[player] then
                        table.insert(ClientsToDestroy, player)
                    end
                end
            end

            Replicator.TR_Destroy:FireFor(ClientsToDestroy, self:GetId())
        end

    else -- Top level ancestor did NOT change:
        self._CreationData[tostring(self:GetId())][1] = newParent:GetId() -- Change out the parent Id in the creation data
        
        local ClientsToInform = if oldReplication.All then ACTIVE_PLAYERS else oldReplication.Active
        for player in pairs(ClientsToInform) do
            Replicator.TR_SetParent:Fire(player, self:GetId(), newParent:GetId())
        end
    end

    newParent:FireSignal("ChildAdded", self)
    oldParent:FireSignal("ChildRemoved", self)
    self:FireSignal("ParentChanged", newParent, oldParent)
end


--------------------------------------------------------------------------------
    --// TableManager Passthrough //--
--------------------------------------------------------------------------------

--[=[
    @private
    Shortcut to set a value in the TableManager.
]=]
function ServerTableReplicator:Set(...: any)
    return self:GetTableManager():Set(...)
end

--------------------------------------------------------------------------------
    --// Finalization //--
--------------------------------------------------------------------------------

-- Useful common TopLevel Replicators
local serverToken = ServerTableReplicator.Token("Server")
local allToken = ServerTableReplicator.Token("All")

--[=[
    @within ServerTableReplicator
    @prop All ServerTableReplicator
    A STR that replicates to all current and future players.
    Used as a global parent for child STRs that need a home and should
    be replicated to all current and future players. Do not modify
    anything about this STR, only use it as a Parent.
]=]
ServerTableReplicator.All = ServerTableReplicator.new({
    TableManager = TableManager.new({});
    ClassToken = allToken;
    ReplicationTargets = "All";
})

--[=[
    @within ServerTableReplicator
    @prop None ServerTableReplicator
    A STR that doesnt replicate to anyone.
    Used as a global parent for child STRs that shouldnt be replicated.
    Do not modify anything about this STR, only use it as a Parent.
]=]
ServerTableReplicator.None = ServerTableReplicator.new({
    TableManager = TableManager.new({});
    ClassToken = serverToken;
    ReplicationTargets = {};
})


export type ServerTableReplicator = typeof(ServerTableReplicator.new({}))

return ServerTableReplicator