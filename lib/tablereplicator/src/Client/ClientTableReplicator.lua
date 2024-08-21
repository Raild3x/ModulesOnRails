-- Authors: Logan Hunt (Raildex)
-- January 04, 2024
--[=[
    @class ClientTableReplicator
    @client

    Inherits from [BaseTableReplicator](#BaseTableReplicator)

    :::warning
    You must call `ClientTableReplicator.requestServerData()` in order to begin
    replication to the client. It should only be called ideally once and after
    all listeners have been registered.
    :::
]=]

-- Convert the imports to requires
local Packages = script.Parent.Parent.Parent
local Symbol = require(Packages.Symbol)
local NetWire = require(Packages.NetWire)
local Promise = require(Packages.Promise)
local RailUtil = require(Packages.RailUtil)
local TableManager = require(Packages.TableManager)
local TableReplicatorUtil = require(script.Parent.Parent.Shared.TableReplicatorUtil)
local BaseTableReplicator = require(script.Parent.Parent.Shared.BaseTableReplicator)
local TableReplicatorSingleton = require(script.Parent.TableReplicatorSingleton)
local ClientCustomRemote = require(script.Parent.ClientCustomRemote)

--// Types //--
type ClientCustomRemote = ClientCustomRemote.ClientCustomRemote
type TableManager = TableManager.TableManager
type Promise = typeof(Promise.new())

type Tags = TableReplicatorUtil.Tags
type Id = number
type table = {[any]: any}

type BindableClass<T> = { -- UNUSED
    ClassName: string;
    OnStart: (<T>(replicator: ClientTableReplicator) -> (T));
    OnStop: (<T>(replicator: T) -> ());
    [any]: any;
}

--// Constants //--
local DEBUG = false

local bootProm = nil
local function IsBooted(): boolean
    if bootProm then
        return bootProm.Status == Promise.Status.Resolved
    end
    return false
end

local SwapRemoveFirstValue = RailUtil.Table.SwapRemoveFirstValue

local KEY_SELF = Symbol("Self")
local ServerMT = {
    __index = function(t, key)
        local CTR = t[KEY_SELF]
        local remote = CTR:AddTask(ClientCustomRemote.new(key, CTR))
        rawset(CTR.Server, key, remote)
        task.defer(function()
            CTR:FireSignal("RemoteSetup", key, remote)
        end)
        return remote
    end,
    __newindex = function(_, key, value)
        error(`Attempted to set '{key}' to '{value}' on the Server table of a ClientTableReplicator`)
    end
}

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local ClientTableReplicator = setmetatable({}, BaseTableReplicator)
ClientTableReplicator.ClassName = "ClientTableReplicator"
ClientTableReplicator.__index = ClientTableReplicator

--[=[
    @tag Static
    @within ClientTableReplicator
    @function fromTemplate

    Creates a ReplicatedTableSingleton object from the given template configuration.

    See [TableReplicatorSingleton.new](TableReplicatorSingleton#new) for more information.
]=]
ClientTableReplicator.fromTemplate = TableReplicatorSingleton.new

--[=[
    @private
    @unreleased
    Binds the given table to a ClientTableReplicator ClassName.
]=]
function ClientTableReplicator.bind(tblOrStr: table | string): table
    assert(not IsBooted(), "ClientTableReplicator has already booted.")
    assert(typeof(tblOrStr) == "string" or typeof(tblOrStr) == "table", "Argument 1 must be a string or table")

    local boundTable
    local classTokenName: string

    if typeof(tblOrStr) == "string" then
        classTokenName = tblOrStr
        boundTable = {
            ClassName = classTokenName;
        }
    else
        classTokenName = tblOrStr.ClassName
        boundTable = tblOrStr
        assert(typeof(classTokenName) == "string", "ClassName is required")
    end

    ClientTableReplicator.listenForNewReplicator(classTokenName, function(replicator)
        local object = replicator
        if boundTable.OnStart then
            object = boundTable.OnStart(replicator) or replicator
        end

        replicator:GetSignal("Stopping"):Once(function()
            if boundTable.OnStop then
                boundTable.OnStop(object)
            end
        end)
    end)

    return boundTable
end

--[=[
    @private
    The CTR constructor. is private because it should not be called externally.
]=]
function ClientTableReplicator._newReplicator(config: {
    Id: Id;
    Parent: ClientTableReplicator?;
    TableManager: TableManager;
    ClassTokenName: string?;
    Tags: Tags?;
})
    assert(config.Id, "Id is required")

    local self = setmetatable(BaseTableReplicator.new({
        ServerId = config.Id;
        Tags = config.Tags;
        TableManager = config.TableManager;
    }), ClientTableReplicator)

    assert(typeof(config.ClassTokenName) == "string", "ClassTokenName is required")
    self._ClassTokenName = config.ClassTokenName;

    self._Parent = config.Parent

    self.Server = setmetatable({[KEY_SELF] = self}, ServerMT)

    self:RegisterSignal("RemoteSetup")
    self:RegisterSignal("Stopping")

    self:AddTask(self:GetTableManager(), nil, "TableManager")

    if DEBUG then
        warn("\t[CLIENT] Created CTR:", self, config)
    end

    return self
end

--[=[
    @private
    This method exists to catch people trying to do something they shouldnt.
]=]
function ClientTableReplicator.new(...: any)
    error("ClientTableReplicator.new() should not be called.")
end


--[=[
    Listens for a new ClientTableReplicator of the given ClassName.
]=]
function ClientTableReplicator.listenForNewReplicator(classTokenName: string, fn: (replicator: ClientTableReplicator) -> ()): (() -> ())
    if bootProm then
        warn(`.listenForNewReplicator("{classTokenName}") was called after the ClientTableReplicator has already booted.`)
    end
    return BaseTableReplicator.listenForNewReplicator(classTokenName, fn)
end

--------------------------------------------------------------------------------
    --// Private //--
--------------------------------------------------------------------------------

--[=[
    @private
    Overrides the default Destroy method to prevent the user from destroying
]=]
function ClientTableReplicator:Destroy()
    error("You are not allowed to destroy a ClientTableReplicator from the client.")
end

--[=[
    @private
    This is the actual Destroy method.
]=]
function ClientTableReplicator:_Destroy()
    self._IsDestroying = true

    for _, child in ipairs(self:GetChildren()) do
        child:_Destroy()
    end

    self:FireSignal("Stopping")
    getmetatable(ClientTableReplicator).Destroy(self)
end


--------------------------------------------------------------------------------
    --// Getters //--
--------------------------------------------------------------------------------

--[[
    @within ClientTableReplicator
    @private
    @unreleased
    Gets a remote signal with the given name.
    If one doesnt exist it will create one at runtime.
]]
-- function ClientTableReplicator:GetRemoteSignal(remoteName: string): ClientCustomRemote
--     if not self[KEY_REMOTE_SIGNALS][remoteName] then
--         self[KEY_REMOTE_SIGNALS][remoteName] = ClientCustomRemote.new(remoteName, self)
--     end
--     return self[KEY_REMOTE_SIGNALS][remoteName] :: any
-- end

--------------------------------------------------------------------------------
    --// Core Replication Handling //--
--------------------------------------------------------------------------------

local function CreateBranch(entries, createdReplicators) -- This is a bunch of black magic
    createdReplicators = createdReplicators or {}

    --print("[CLIENT] Creating branch:", entries)

    local sortedEntries = {}
    for id, creationData in pairs(entries) do
        local parsedData = TableReplicatorUtil.ParsePacket(creationData)
        parsedData.Id = tonumber(id)
        --print("[CLIENT] Parsed data:", parsedData, "from", creationData)
        table.insert(sortedEntries, parsedData)
    end
    table.sort(sortedEntries, function(a, b)
        return a.Id < b.Id
    end)

    local waitingForParent = {} -- [ParentId] = {CTR, ...}

    -- for each entry, create a CTR
    for _, entry in pairs(sortedEntries) do
        local id = entry.Id
        local classTokenName = entry.ClassName
        local tags = entry.Tags
        local data = entry.Data

        -- Try Fetching Parent
        local waitForParent = false
        local parent
        if entry.ParentId then
            parent = ClientTableReplicator.getFromServerId(entry.ParentId)
            if not parent then
                waitForParent = true
            end
        end

        --print("[CLIENT] Creating CTR:", entry, "|", id, classTokenName, tags, data)
        local object = ClientTableReplicator._newReplicator({
            Id = id;
            Parent = parent or entry.ParentId;
            ClassTokenName = classTokenName;
            Tags = tags;
            TableManager = TableManager.new(data);
        })

        if parent then
           table.insert(parent._Children, object)
        elseif waitForParent then
            waitingForParent[entry.ParentId] = waitingForParent[entry.ParentId] or {}
            table.insert(waitingForParent[entry.ParentId], object)
        end

        table.insert(createdReplicators, object)

        -- Set the parents of any waiting children
        local childrenWaiting = waitingForParent[id]
        if childrenWaiting then
            waitingForParent[id] = nil
            for _, child in pairs(childrenWaiting) do
                child._Parent = object
                table.insert(object._Children, child)
            end
        end
    end

    if next(waitingForParent) then
        warn(waitingForParent)
        error("[CLIENT] Something went wrong during replication.")
    end

    return createdReplicators
end

--[=[
    Requests all the existing replicators from the server. This should only
    be called once, calling it multiple times will return the same promise.
    All replicator listeners should be registered before calling this method.
]=]
function ClientTableReplicator.requestServerData(): Promise
    if bootProm then
        return bootProm
    end

    local Replicator = NetWire.Client("TableReplicator")

    Replicator.TR_Create:Connect(function(...) -- TODO: Im begging my future self to change this to something reasonable
        if DEBUG then
            warn("[CLIENT] Received creation packet:", ...)
        end

        local p1, p2 = ...

        local createdReplicators = {}

        if typeof(p1) == "table" then
            local bulkPacket: {table} = ...

            -- Sort top level entries by id
            table.sort(bulkPacket, function(a, b)
                return a[1] < b[1]
            end)
            
            for _, packet in pairs(bulkPacket) do
                local creationData = packet[2]
                CreateBranch(creationData, createdReplicators)
            end

        else
            local creationData = p2
            if p2[2] ~= nil then
                creationData = {[tostring(p1)] = p2}
            end

            CreateBranch(creationData, createdReplicators)
        end

        -- Broadcast the creation of the CSTR
        table.sort(createdReplicators, function(a, b)
            return a:GetServerId() < b:GetServerId()
        end)

        -- 1) Child added:
        for _, replicator in pairs(createdReplicators) do
            local parentReplicator = replicator:GetParent()
            if parentReplicator then
                parentReplicator:FireSignal("ChildAdded", replicator)
            end
        end

        -- 2) New CTR created:
        --print("Firing listeners for ", #createdReplicators, " replicators", createdReplicators)
        if DEBUG then
            warn("[CLIENT] Firing creation listeners for ", #createdReplicators, " replicators", createdReplicators)
        end
        for _, replicator in ipairs(createdReplicators) do
            replicator:_FireCreationListeners()
            --print("Fired listener for ", replicator)
        end
    end)


    Replicator.TR_Destroy:Connect(function(id: Id)
        local CTR = ClientTableReplicator.getFromServerId(id) :: ClientTableReplicator
        assert(CTR, `CTR[{id}] not found.`)
        CTR:_Destroy()
    end)


    Replicator.TR_SetParent:Connect(function(childId: Id, parentId: Id)
        local child = ClientTableReplicator.getFromServerId(childId) :: ClientTableReplicator
        assert(child, `child CTR[{childId}] not found.`)

        local oldParent = child:GetParent()
        local newParent = ClientTableReplicator.getFromServerId(parentId) :: ClientTableReplicator
        assert(newParent, `newParent CTR[{parentId}] not found.`)

        SwapRemoveFirstValue(oldParent._Children, child)
        table.insert(newParent._Children, child)
        child._Parent = newParent

        oldParent:FireSignal("ChildRemoved", child)
        newParent:FireSignal("ChildAdded", child)
        child:FireSignal("ParentChanged", newParent, oldParent)
    end)


    local function AssertGetTableManager(id: Id): TableManager
        local CTR = ClientTableReplicator.getFromServerId(id) :: ClientTableReplicator
        assert(CTR, `CTR[{id}] not found.`)
        return CTR:GetTableManager()
    end


    Replicator.ValueChanged:Connect(function(id: Id, path: string, value: any)
        AssertGetTableManager(id):SetValue(path, value)
    end)

    Replicator.ArrayInsert:Connect(function(id: Id, path: string, ...)
        AssertGetTableManager(id):ArrayInsert(path, ...)
    end)

    Replicator.ArrayRemove:Connect(function(id: Id, path: string, idx: number)
        AssertGetTableManager(id):ArrayRemove(path, idx)
    end)

    Replicator.ArraySet:Connect(function(id: Id, path: string, ...)
        AssertGetTableManager(id):ArraySet(path, ...)
    end)


    Replicator.NetworkEvent:Connect(function(id: Id, remoteName: string, ...)
        local CTR = ClientTableReplicator.getFromServerId(id) :: ClientTableReplicator
        assert(CTR, `CTR[{id}] not found.`)

        local remote = rawget(CTR.Server, remoteName)
        if not remote then
            Promise.fromEvent(CTR:GetSignal("RemoteSetup"), function(name)
                return name == remoteName
            end)
            :timeout(10, `Exhausted Timeout: No Event with name '{remoteName}' has been connected to!`)
            :andThen(function(_, newRemote)
                remote = newRemote
            end)
            :catch(warn):await()
        end
        if remote then
            remote:_FireClient(...)
        end
    end)

    

    -- Replicator.NetworkUnreliableEvent:Connect(function(id: Id, remoteName: string, ...)
    --     local CTR = ClientTableReplicator.getFromServerId(id) :: ClientTableReplicator
    --     assert(CTR, `CTR[{id}] not found.`)

    --     local remote = CTR:GetRemoteSignal(remoteName)
    --     remote:_FireClient(...)
    -- end)


    bootProm = Replicator:RequestServerData() :: Promise
    return bootProm
end


do -- This is a reminder for new users to call ClientTableReplicator.requestServerData()
    local WARN_DELAY = 10
    task.delay(WARN_DELAY, function()
        if not bootProm then
            warn(`ClientTableReplicator has not yet been booted. Please remember to call ClientTableReplicator.requestServerData() in your code.`)
        end
    end)
end


export type ClientTableReplicator = typeof(ClientTableReplicator._new({})) -- export the class

return ClientTableReplicator