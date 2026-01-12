-- Authors: Logan Hunt (Raildex)
-- January 17, 2024
--[=[
    @class DropletServerManager
]=]

--// Services //--
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local DropletUtil = require(script.Parent.Parent.DropletUtil)
local ProbabilityDistributor = require(Packages.ProbabilityDistributor)
local RailUtil = require(Packages.RailUtil)
local NetWire = require(Packages.NetWire)

--// Types //--
type table = {[any]: any}
type CollectorMode = DropletUtil.CollectorMode
type WeightedArray<T> = ProbabilityDistributor.WeightedArray<T>

type NumOrRange = number | NumberRange
type NumOrRangeOrWeightedArray = NumOrRange | WeightedArray<NumOrRangeOrWeightedArray>

type ResourceSpawnData = DropletUtil.ResourceSpawnData
type ResourceTypeData = DropletUtil.ResourceTypeData

--// Enums //--
local CollectorMode = DropletUtil.Enums.CollectorMode

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
--// MODULE STATE //--
--------------------------------------------------------------------------------
local DEBUG = false
local DropletServerManager = {}

local ResourceTypeDataMap: {[string]: ResourceTypeData} = {}
local DropletStorage: {[number]: DropletUtil.DropletServerCacheData} = {}

local Replicator = NetWire.Server("DropletServerManager")
Replicator.DropletCreated = NetWire.createEvent()
Replicator.DropletClaimed = NetWire.createEvent()
Replicator.DropletCollected = NetWire.createEvent()
Replicator.CollectionRadius = NetWire.createProperty(15)

Replicator.DropletClaimed:Connect(function(...)
    (DropletServerManager :: any):Claim(...)
end)

Replicator.DropletCollected:Connect(function(...)
    (DropletServerManager :: any):Collect(...)
end)

PhysicsService:RegisterCollisionGroup(DropletUtil.DROPLET_COLLISION_GROUP)
PhysicsService:CollisionGroupSetCollidable(DropletUtil.DROPLET_COLLISION_GROUP, DropletUtil.DROPLET_COLLISION_GROUP, false)

--------------------------------------------------------------------------------
--// MODULE //--
--------------------------------------------------------------------------------

--[=[
    Registers a new resource type. Attempting to register a resource type with the same name as an existing one will error.
    Resource types define how droplets of that type behave on the server and client.
    The same table must be registered to the same name on both server and client.
    ```lua
    local data = require(path.to.ExampleResourceTypeData) -- There is an Example file included in the package you can check out.
    DropletServerManager:RegisterResourceType("Example", data)
    ```
]=]
function DropletServerManager:RegisterResourceType(resourceType: string, data: ResourceTypeData)
    assert(not ResourceTypeDataMap[resourceType], `ResourceType already registered for: '{tostring(resourceType)}'`)
    ResourceTypeDataMap[resourceType] = data
end

--[=[
    Returns the data that was provided for a given registered resource type.
]=]
function DropletServerManager:GetResourceTypeData(resourceType: string): ResourceTypeData?
    return ResourceTypeDataMap[resourceType]
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
        CollectorMode = "MultiCollector";
    })
    ```

    @param data ResourceSpawnData -- The data used to spawn the droplet.
    @return number -- The seed of the droplet request.
]=]
function DropletServerManager:Spawn(data: ResourceSpawnData): number
    local rtData = DropletServerManager:GetResourceTypeData(data.ResourceType)
    assert(rtData, `Resource type '{tostring(data.ResourceType)}' not registered`)
    local DEFAULTS = rtData.Defaults

    local Seed = DropletServerManager:_GenerateSeed()
    local NumGen = Random.new(Seed)

    local VALUE = data.Value or DEFAULTS.Value

    local Count = math.round(ParseNRWT(data.Count or DEFAULTS.Count or DropletUtil.DEFAULT_COUNT, NumGen))
    assert(typeof(Count) == "number" and Count >= 0, "Count must resolve to a non-negative number")
    local EjectionDuration = ParseNRWT(data.EjectionDuration or DEFAULTS.EjectionDuration or DropletUtil.DEFAULT_EJECTION_DURATION, NumGen)
    assert(typeof(EjectionDuration) == "number" and EjectionDuration >= 0, "EjectionDuration must resolve to a non-negative number")
    local LifeTime = data.LifeTime or DEFAULTS.LifeTime or DropletUtil.DEFAULT_LIFETIME
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
            CollectorMode = data.CollectorMode or DEFAULTS.CollectorMode or DropletUtil.DEFAULT_COLLECTOR_MODE,
            EjectionDuration = EjectionDuration,
            EjectionVerticalVelocity = AssertValidNRWT(data.EjectionVerticalVelocity),
            EjectionHorizontalVelocity = AssertValidNRWT(data.EjectionHorizontalVelocity),
            EjectionDirection = data.EjectionDirection or DEFAULTS.EjectionDirection,

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

    DropletStorage[Seed] = {
        NetworkPacket = NetworkPacket,
        DropletData = rawDropletData,
        PlayerTargets = ValidatePlayerTargets(data.PlayerTargets),
    } :: DropletUtil.DropletServerCacheData

    Replicator.DropletCreated:FireFor(DropletStorage[Seed].PlayerTargets, NetworkPacket)

    --// Schedule the droplet to be removed after its lifetime has expired //--
    local LifetimeUpperBound = if typeof(LifeTime) == "NumberRange" then LifeTime.Max else LifeTime
    task.delay(LifetimeUpperBound + 30, function()
        DropletStorage[Seed] = nil
    end)

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
    assert(collector and collector:IsA("Player"), "Invalid collector passed when attempting to claim droplet")
    assert(typeof(seed) == "number", `Invalid Seed passed when attempting to collect droplet: {tostring(seed)}, must be a number`)
    local serverData = DropletServerManager:_GetDropletServerData(seed)
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
                local claimSuccess = DropletServerManager:Claim(collector, seed, key)
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
        local alreadyClaimed = if collectorMode == CollectorMode.SingleCollector then
                #dropletData.ClaimedBy > 0 else table.find(dropletData.ClaimedBy, collector) ~= nil

        if alreadyClaimed then
            warn(`Player '{collector.Name}' has already claimed Droplet [{seed}][{dropletNumber}]`)
            return false
        end
    end

    
    --// Handle collection //--
    table.insert(dropletData.ClaimedBy, collector)
    if collectorMode == CollectorMode.SingleCollector then
        Replicator.DropletClaimed:FireFor(serverData.PlayerTargets, collector, seed, dropletNumber)
    elseif collectorMode == CollectorMode.MultiCollector then
        Replicator.DropletClaimed:Fire(collector, collector, seed, dropletNumber)
    else
        error("Invalid CollectorMode: " .. tostring(collectorMode))
    end

    if DEBUG then
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
    assert(collector and collector:IsA("Player"), "Invalid collector passed when attempting to claim droplet")
    assert(typeof(seed) == "number", `Invalid Seed passed when attempting to collect droplet: {tostring(seed)}, must be a number`)
    local serverData = DropletServerManager:_GetDropletServerData(seed)
    if not serverData then return false end

    --// If no droplet number then collect all droplets
    if typeof(dropletNumber) ~= "number" then
        if not dropletNumber then
            local fullSuccess = true
            for key in pairs(serverData.DropletData) do
                local collectSuccess = DropletServerManager:Collect(collector, seed, key)
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
        local alreadyCollected = if collectorMode == CollectorMode.SingleCollector then
            #dropletData.CollectedBy > 0 else table.find(dropletData.CollectedBy, collector) ~= nil

        if alreadyCollected then
            warn(`Player '{collector.Name}' has already collected droplet with seed '{seed}' and droplet number '{dropletNumber}'`)
            return false
        end
    end
    

    --// Handle collection //--
    local resourceTypeData = DropletServerManager:GetResourceTypeData(dropletInfo.ResourceType)
    TryCall(resourceTypeData.OnServerCollect, collector, dropletData.ActualValue, dropletInfo.Metadata)

    if collectorMode == CollectorMode.SingleCollector then
        serverData.DropletData[dropletNumber] = nil -- Remove this droplet from the droplet data
    
    elseif collectorMode == CollectorMode.MultiCollector then
        table.insert(dropletData.CollectedBy, collector)

        if #dropletData.CollectedBy == #serverData.PlayerTargets then
            serverData.DropletData[dropletNumber] = nil -- Remove this droplet from the droplet data if all players have collected it
        end
    else
        error("Invalid CollectorMode: " .. tostring(collectorMode))
    end

    if DEBUG then
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
            DropletStorage[seed] = nil
        end
    end

    return true
end

--[=[
    @private
    Generates a new unused seed
]=]
function DropletServerManager:_GenerateSeed(): number
    local seed
    repeat
        seed = math.random(1, 2^20)
    until not DropletStorage[seed]
    return seed
end

--[=[
    @private
    Returns the droplet server data for the given seed.
]=]
function DropletServerManager:_GetDropletServerData(seed: number): DropletUtil.DropletServerCacheData?
    return DropletStorage[seed] or warn("Droplet request with seed '" .. tostring(seed) .. "' does not exist")
end

return DropletServerManager