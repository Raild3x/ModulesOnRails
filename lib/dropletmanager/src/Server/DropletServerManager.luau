-- Authors: Logan Hunt (Raildex)
-- January 17, 2024
--[=[
    @class DropletServerManager
]=]

--// Services //--
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local DropletUtil = require(script.Parent.Parent.DropletUtil)
local ProbabilityDistributor = require(Packages.ProbabilityDistributor)
local BaseObject = require(Packages.BaseObject)
local RailUtil = require(Packages.RailUtil)
local NetWire = require(Packages.NetWire)

type table = {[any]: any}
type CollectorMode = DropletUtil.CollectorMode
type WeightedArray<T> = ProbabilityDistributor.WeightedArray<T>

type NumOrRange = number | NumberRange
type NumOrRangeOrWeightedArray = NumOrRange | WeightedArray<NumOrRangeOrWeightedArray>

type ResourceSpawnData = DropletUtil.ResourceSpawnData
type ResourceTypeData = DropletUtil.ResourceTypeData

--// Constants //--
local SuperClass = BaseObject
local DropletEnums = DropletUtil.Enums

local DEFAULT_COLLECTOR_MODE = DropletEnums.CollectorMode.MultiCollector
local DEFAULT_LIFE_TIME = NumberRange.new(8, 12)
local DEFAULT_EJECTION_DURATION = 0.1
local DEFAULT_COUNT = 1

--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local function TryCall(fn: ((...any) -> (...any))?, ...): (...any)
    if not fn then return end
    return fn(...)
end

local function IsWeightedArray(tbl: table)
    local isTable = typeof(tbl) == "table"
    if not isTable then return false end

    local hasNumericIndex = tbl[1] ~= nil
    if not hasNumericIndex then return false end

    local hasWeight = tbl[1].Weight ~= nil
    local hasValue = tbl[1].Value ~= nil

    return hasWeight and hasValue
end

local function AssertValidNRWT(v: NumOrRangeOrWeightedArray?)
    if not v then return end
    local dType = typeof(v)
    assert(dType == "number" or dType == "NumberRange" or IsWeightedArray(v :: any), "Invalid type given for NumOrRangeOrWeightedArray. Got: " .. dType)
    return v
end

local function AssertTypes(name: string, value: any, ...: string)
    local types = {...}
    local valid = false
    if typeof(types) == "string" then
        valid = typeof(value) == types
    elseif typeof(types) == "table" then
        for _, v in ipairs(types) do
            if typeof(value) == v then
                valid = true
                break
            end
        end
    end
    assert(valid, "Invalid type for " .. name .. ". Expected [" .. tostring(types) .. "], got " .. typeof(value))
end

local function ValidatePlayerTargets(targets: (Player | {Player})?): {Player}
    local newTargets = targets or Players:GetPlayers()
    if typeof(newTargets) == "Instance" then
        newTargets = {newTargets}
    end
    for _, v in ipairs(newTargets) do
        assert(v:IsA("Player"), "Invalid player target")
    end
    return newTargets
end

local ParseNRWT = DropletUtil.parse

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local SINGLETON

local DropletServerManager = setmetatable({}, SuperClass)
DropletServerManager.ClassName = "DropletServerManager"
DropletServerManager.__index = DropletServerManager

local function AssertIsSingleton(self)
    assert(self == SINGLETON, "Called method on class instead of singleton")
end

--[=[
    @tag constructor
    @return DropletServerManager

    Creates a new DropletServerManager if one has not already been made,
    returns the existing one if one already exists.
]=]
function DropletServerManager.new()
    if SINGLETON then return SINGLETON end
    local self = setmetatable(SuperClass.new(), DropletServerManager)
    SINGLETON = self

    self._ActiveDroplets = {}

    self._ResourceTypeDataMap = {}

    self._DropletStorage = {} -- [seed] = {}

    if RunService:IsRunning() then
        self._Replicator = NetWire.Server("DropletServerManager")
        self._Replicator.DropletCreated = NetWire.createEvent()
        self._Replicator.DropletClaimed = NetWire.createEvent()
        self._Replicator.DropletCollected = NetWire.createEvent()
        self._Replicator.CollectionRadius = NetWire.createProperty(15)

        self._Replicator.DropletClaimed:Connect(function(...: any)
            self:Claim(...)
        end)

        self._Replicator.DropletCollected:Connect(function(...: any)
            self:Collect(...)
        end)
    else
        warn("Loaded DropletServerManager in edit mode")
    end
    

    PhysicsService:RegisterCollisionGroup(DropletUtil.DROPLET_COLLISION_GROUP)
    PhysicsService:CollisionGroupSetCollidable(DropletUtil.DROPLET_COLLISION_GROUP, DropletUtil.DROPLET_COLLISION_GROUP, false)

    -- self:RegisterResourceType("Test", Import("TestResourceTypeData"))

    return self
end
DropletServerManager.new = DropletServerManager.getInstance -- backward compatibility alias 

--[=[
    @private
]=]
function DropletServerManager:Destroy()
    error("Cannot destroy singleton")
end

--[=[
    @private
    Generates a new unused seed
]=]
function DropletServerManager:_GenerateSeed(): number
    local seed
    repeat
        seed = math.random(1, 2^16)
    until not self._DropletStorage[seed]
    return seed
end

--[=[
    Registers a new resource type. Attempting to register a resource type with the same name as an existing one will error.
    ```lua
    local data = Import("ExampleResourceTypeData") -- This is an Example file included in the package you can check out.
    DropletServerManager:RegisterResourceType("Example", data)
    ```
]=]
function DropletServerManager:RegisterResourceType(resourceType: string, data: ResourceTypeData)
    AssertIsSingleton(self)
    assert(not self._ResourceTypeDataMap[resourceType], `ResourceType already registered for: '{tostring(resourceType)}'`)
    self._ResourceTypeDataMap[resourceType] = data
end

--[=[
    Returns the resource type data for the given resource type.
]=]
function DropletServerManager:GetResourceTypeData(resourceType: string): ResourceTypeData?
    AssertIsSingleton(self)
    return self._ResourceTypeDataMap[resourceType]
end

--[=[
    @private
    Returns the droplet server data for the given seed.
]=]
function DropletServerManager:GetDropletServerData(seed: number): DropletUtil.DropletServerCacheData?
    return self._DropletStorage[seed] or warn("Droplet request with seed '" .. tostring(seed) .. "' does not exist")
end

--[=[
    Creates a new droplet request to create some defined number of droplets of a given ResourceType.
    The droplet request will be created on the server and replicated to the clients.
    
    A PlayerTargets array can be passed to specify which players the droplet request should be replicated to,
    if one isnt given it replicates to all connected players at the moment of the request.

    :::caution Caveats
    Some properties of the interface have special behaviors depending on their type.
    See 'ResourceSpawnData' for more info on important caveats and behavior.
    :::

    ```lua
    local Bounds = 35

    local seed = DropletServerManager:Spawn({
        ResourceType = "Example";
        Value = NumberRange.new(0.6, 1.4);
        Count = NumberRange.new(2, 10);
        LifeTime = NumberRange.new(10, 20);
        SpawnLocation = Vector3.new(
            math.random(-Bounds,Bounds),
            7,
            math.random(-Bounds,Bounds)
        );
        CollectorMode = DropletUtil.Enums.CollectorMode.MultiCollector;
    })
    ```

    @param data ResourceSpawnData -- The data used to spawn the droplet.
    @return number -- The seed of the droplet request.
]=]
function DropletServerManager:Spawn(data: ResourceSpawnData): number
    AssertIsSingleton(self)

    local rtData = self:GetResourceTypeData(data.ResourceType)
    assert(rtData, `Resource type '{tostring(data.ResourceType)}' not registered`)
    local DEFAULTS = rtData.Defaults

    local Seed = self:_GenerateSeed()
    local NumGen = Random.new(Seed)

    local VALUE = data.Value or DEFAULTS.Value

    local Count = math.round(ParseNRWT(data.Count or DEFAULTS.Count or DEFAULT_COUNT, NumGen))
    assert(typeof(Count) == "number" and Count >= 0, "Count must resolve to a non-negative number")
    local EjectionDuration = ParseNRWT(data.EjectionDuration or DEFAULTS.EjectionDuration or DEFAULT_EJECTION_DURATION, NumGen)
    assert(typeof(EjectionDuration) == "number" and EjectionDuration >= 0, "EjectionDuration must resolve to a non-negative number")
    local LifeTime = data.LifeTime or DEFAULTS.LifeTime or DEFAULT_LIFE_TIME
    AssertTypes("LifeTime", LifeTime, "number", "NumberRange")
    if typeof(LifeTime) == "NumberRange" then
        assert(LifeTime.Min >= 0 and LifeTime.Max >= 0, "LifeTime must resolve to a positive number")
    elseif typeof(LifeTime) == "number" then
        assert(LifeTime :: number >= 0, "LifeTime must resolve to a positive number")
    end

    --// Generate the Network Packet //--
    local NetworkPacket: DropletUtil.DropletNetworkPacket do
        local SpawnLocation: any = data.SpawnLocation
        if typeof(SpawnLocation) == "Instance" then
            assert(SpawnLocation:IsA("PVInstance"), "Invalid SpawnLocation given, must be a PVInstance")
            SpawnLocation = {
                Obj = SpawnLocation,
                CF = SpawnLocation:GetPivot()
            }
        else
            AssertTypes("SpawnLocation", SpawnLocation, "Vector3", "CFrame", "Instance")
        end

        NetworkPacket = {
            Seed = Seed,
            Count = Count,
            SpawnTime = workspace:GetServerTimeNow(),
            CollectorMode = data.CollectorMode or DEFAULTS.CollectorMode or DEFAULT_COLLECTOR_MODE,
            EjectionDuration = EjectionDuration,
            EjectionVerticalVelocity = AssertValidNRWT(data.EjectionVerticalVelocity),
            EjectionHorizontalVelocity = AssertValidNRWT(data.EjectionHorizontalVelocity),

            ResourceType = data.ResourceType,
            Value = VALUE,
            Metadata = data.Metadata,
            SpawnLocation = SpawnLocation,
            LifeTime = LifeTime,
        }
    end


    --// Calculate the actual droplet values and store them on the server for later lookup //--
    local rawDropletData = {}
    for i, rawData in pairs(DropletUtil.calculateDropletValues(VALUE, Count, Seed, LifeTime)) do
        rawDropletData[i] = { ActualValue = rawData.RawValue }
    end

    self._DropletStorage[Seed] = {
        NetworkPacket = NetworkPacket,
        DropletData = rawDropletData,
        PlayerTargets = ValidatePlayerTargets(data.PlayerTargets),
    } :: DropletUtil.DropletServerCacheData

    self._Replicator.DropletCreated:FireFor(self._DropletStorage[Seed].PlayerTargets, NetworkPacket)

    --// Schedule the droplet to be removed after its lifetime has expired //--
    local LifetimeUpperBound = if typeof(LifeTime) == "NumberRange" then LifeTime.Max else LifeTime
    self:AddTask(task.delay(LifetimeUpperBound + 30, function()
        self._DropletStorage[Seed] = nil
    end), nil, Seed)

    return Seed
end

--[=[
    Force claim a droplet(s) for a player.
    @param collector Player -- The player claiming the droplet.
    @param seed number -- The droplet request identifier.
    @param dropletNumber number? -- The particular droplet number to claim. If nil, all remaining droplets will be claimed.
    @return boolean -- Whether or not the claim was successful.
]=]
function DropletServerManager:Claim(collector: Player, seed: number, dropletNumber: (number)?): boolean
    AssertIsSingleton(self)

    assert(collector and collector:IsA("Player"), "Invalid collector passed when attempting to claim droplet")
    assert(typeof(seed) == "number", `Invalid Seed passed when attempting to collect droplet: {tostring(seed)}, must be a number`)
    local serverData = self:GetDropletServerData(seed)
    if not serverData then 
        warn(`Droplet request with seed '{seed}' does not exist when attempting to claim.`)
        return false 
    end

    --// If no droplet number then collect all droplets
    if typeof(dropletNumber) ~= "number" then
        if not dropletNumber then
            local fullSuccess = true
            local keys = RailUtil.Table.Keys(serverData.DropletData)
            for _, key in ipairs(keys) do
                local claimSuccess = self:Claim(collector, seed, key)
                fullSuccess = fullSuccess and claimSuccess
            end
            return fullSuccess
        end
    end

    local dropletInfo = serverData.NetworkPacket
    local dropletData = serverData.DropletData[dropletNumber]
    local collectorMode = dropletInfo.CollectorMode

    do -- Validation checks to see if player can collect
        assert(table.find(serverData.PlayerTargets, collector), `Player '{collector.Name}' is not a target of droplet request with seed '{seed}'. PlayerTargets: {serverData.PlayerTargets}`)

        if not dropletData then
            warn(`DropletData with seed '{seed}' and droplet number '{dropletNumber}' does not exist. Likely already collected.`)
            return false
        end

        dropletData.ClaimedBy = dropletData.ClaimedBy or {}
        local alreadyClaimed = if collectorMode == DropletEnums.CollectorMode.SingleCollector then
                #dropletData.ClaimedBy > 0 else table.find(dropletData.ClaimedBy, collector) ~= nil

        if alreadyClaimed then
            warn(`Player '{collector.Name}' has already claimed Droplet [{seed}][{dropletNumber}]`)
            return false
        end
    end

    
    --// Handle collection //--
    table.insert(dropletData.ClaimedBy, collector)
    if collectorMode == DropletEnums.CollectorMode.SingleCollector then
        self._Replicator.DropletClaimed:FireFor(serverData.PlayerTargets, collector, seed, dropletNumber)
    elseif collectorMode == DropletEnums.CollectorMode.MultiCollector then
        self._Replicator.DropletClaimed:Fire(collector, collector, seed, dropletNumber)
    else
        error("Invalid CollectorMode: " .. tostring(collectorMode))
    end

    if self._DEBUG then
        print(`{collector.Name} claimed Droplet [{seed}][{dropletNumber}]`)
    end

    return true
end

--[=[
    Force collects a droplet(s) resource and returns whether or not the collection was successful.
    @param collector Player -- The player collecting the resource.
    @param seed number -- The droplet request identifier.
    @param dropletNumber number? -- The particular droplet number to collect. If nil, all droplets will be collected.
    @return boolean -- Whether or not the collection was successful.
]=]
function DropletServerManager:Collect(collector: Player, seed: number, dropletNumber: (number)?): boolean
    AssertIsSingleton(self)

    assert(collector and collector:IsA("Player"), "Invalid collector passed when attempting to claim droplet")
    assert(typeof(seed) == "number", `Invalid Seed passed when attempting to collect droplet: {tostring(seed)}, must be a number`)
    local serverData = self:GetDropletServerData(seed)
    if not serverData then return false end

    --// If no droplet number then collect all droplets
    if typeof(dropletNumber) ~= "number" then
        if not dropletNumber then
            local fullSuccess = true
            for key in pairs(serverData.DropletData) do
                local collectSuccess = self:Collect(collector, seed, key)
                fullSuccess = fullSuccess and collectSuccess
            end
            return fullSuccess
        end
    end

    local dropletInfo = serverData.NetworkPacket
    local dropletData = serverData.DropletData[dropletNumber]
    local collectorMode = dropletInfo.CollectorMode

    do -- Validation checks to see if player can collect
        assert(table.find(serverData.PlayerTargets, collector), `Player '{collector.Name}' is not a target of droplet request with seed '{seed}'. PlayerTargets: {serverData.PlayerTargets}`)

        if not dropletData then
            warn(`DropletData [{seed}][{dropletNumber}] does not exist. Likely already collected.`)
            return false
        end

        dropletData.CollectedBy = dropletData.CollectedBy or {}
        local alreadyCollected = if collectorMode == DropletEnums.CollectorMode.SingleCollector then
            #dropletData.CollectedBy > 0 else table.find(dropletData.CollectedBy, collector) ~= nil

        if alreadyCollected then
            warn(`Player '{collector.Name}' has already collected droplet with seed '{seed}' and droplet number '{dropletNumber}'`)
            return false
        end
    end
    

    --// Handle collection //--
    local resourceTypeData = self:GetResourceTypeData(dropletInfo.ResourceType)
    TryCall(resourceTypeData.OnServerCollect, collector, dropletData.ActualValue, dropletInfo.Metadata)

    if collectorMode == DropletEnums.CollectorMode.SingleCollector then
        serverData.DropletData[dropletNumber] = nil -- Remove this droplet from the droplet data
    
    elseif collectorMode == DropletEnums.CollectorMode.MultiCollector then
        table.insert(dropletData.CollectedBy, collector)

        if #dropletData.CollectedBy == #serverData.PlayerTargets then
            serverData.DropletData[dropletNumber] = nil -- Remove this droplet from the droplet data if all players have collected it
        end
    else
        error("Invalid CollectorMode: " .. tostring(collectorMode))
    end

    if self._DEBUG then
        print(`{collector.Name} collected Droplet [{seed}][{dropletNumber}]`)
    end

    do -- Check to see if all droplets have been collected
        local isAllCollected = true
        for _, v in pairs(serverData.DropletData) do
            if v then
                isAllCollected = false
                break
            end
        end
        if isAllCollected then -- remove the droplet request
            self._DropletStorage[seed] = nil
        end
    end

    return true
end

--[=[
    Gets the collection radius for the given player.
]=]
function DropletServerManager:GetCollectionRadius(player: Player): number
    return self._Replicator.CollectionRadius:GetFor(player)
end

--[=[
    Sets the collection radius for the given player.
]=]
function DropletServerManager:SetCollectionRadius(player: Player, radius: number)
    assert(typeof(radius) == "number" and radius >= 0, "Invalid radius given, must be a non-negative number")
    self._Replicator.CollectionRadius:SetFor(player, radius)
end


return DropletServerManager