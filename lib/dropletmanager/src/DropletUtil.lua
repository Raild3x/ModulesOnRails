-- Authors: Logan Hunt (Raildex)
-- January 17, 2024
--[=[
    @class DropletUtil

    Internal utility functions for droplets
]=]

--// Imports //--
local Packages = script.Parent.Parent
local ProbabilityDistributor = require(Packages.ProbabilityDistributor)

type table = {[any]: any}

-- I had to manually type this bc Luau LSP wont let me make a cyclic reference to get the type from the Droplet File
export type Droplet = {
    -- [Properties]
    -- _Value: any,
    -- _NetworkPacket: DropletNetworkPacket,
    -- _ResourceTypeData: ResourceTypeData,
    -- _CollectionRadius: number,
    -- _MaxVelocity: number,
    -- _MaxForce: number,
    -- _Mass: number,
    -- _Model: Actor,
    -- _Weld: Weld,
    -- _CustomSetupData: any,
    -- _DropletId: number,
    -- _TimingOut: boolean,

    -- [Static Methods]
    -- processRendering: (self: Droplet) -> (),
    -- new: (config: {
    --     Id: number,
    --     NetworkPacket: DropletNetworkPacket,
    --     ResourceTypeData: ResourceTypeData,
    --     Value: any?,
    --     LifeTime: number,
    --     DropletClientManager: any
    -- }) -> Droplet,

    -- [Methods]
    GetValue: (self: Droplet) -> any,
    GetMetadata: (self: Droplet) -> any?,
    GetResourceTypeData: (self: Droplet) -> ResourceTypeData,
    GetPosition: (self: Droplet) -> Vector3,
    GetPivot: (self: Droplet) -> CFrame,
    GetModel: (self: Droplet) -> Actor,
    GetSetupData: (self: Droplet) -> any,
    Identify: (self: Droplet) -> (number, number),
    IsTimingOut: (self: Droplet) -> boolean,
    AttachModel: (self: Droplet, object: Model | BasePart) -> Weld,
    Collect: (self: Droplet, playerWhoCollected: Player) -> (),
    Claim: (self: Droplet, playerWhoClaimed: Player) -> (),
    Magnetize: (self: Droplet, playerWhoCollected: Player) -> (),
    -- _Render: (self: Droplet, dt: number) -> (),
}

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local DropletUtil = {}

--[=[
    @within DropletUtil
    @type WeightedArray<T> { {Weight: number, Value: T} }
    A table of values with weights. The weights are used to calculate the probability
    of a value being chosen. The weights do not need to add up to 1. See `ProbabilityDistributor`
    for more information.
]=]
type WeightedArray<T> = ProbabilityDistributor.WeightedArray<T>

--[=[
    @within DropletUtil
    @type NumOrRange number | NumberRange
]=]
type NumOrRange = number | NumberRange

--[=[
    @within DropletUtil
    @type NumOrRangeOrWeightedArray NumOrRange | WeightedArray<NumOrRange>
]=]
type NumOrRangeOrWeightedArray = NumOrRange | WeightedArray<NumOrRange>

--[=[
    @within DropletUtil
    @interface ResourceTypeData
    .Defaults table
    .SetupDroplet (droplet: Droplet) -> any?
    .OnRenderUpdate ((droplet: Droplet, renderTime: number) -> (CFrame?))?
    .OnDropletTimeout ((droplet: Droplet) -> ())?
    .OnClientClaim ((playerWhoCollected: Player, droplet: Droplet) -> ())?
    .OnClientCollect ((playerWhoCollected: Player, droplet: Droplet) -> ())?
    .OnServerCollect ((playerWhoCollected: Player, value: any, metadata: any) -> ())?

    - `[Defaults]` is a table of default values for the droplet. This can be left empty.
    The values in this table are used to fill in any missing values in the ResourceSpawnData
    when a droplet is spawned as well as overriding certain behaviors internall for things
    like magnetization.

    - `[SetupDroplet]` is called when a new droplet is created. Use this to setup your visuals and
    any variables you need to keep track of. All parts within this should be
    `Anchored = false, CanCollide = false, and Massless = true`.
    The return value of this function can be accessed via Droplet:GetSetupData()

    - `[OnRenderUpdate]` is called every frame that the droplet is within render range of the
    LocalPlayer's Camera. Use this to update the visuals of your droplet.
    The return value, if one is given, must be a CFrame and is used for offsetting the droplet.

    - `[OnDropletTimeout]` is called when the droplet times out. Use this to perform/cleanup
    any visual effects you may have.

    - `[OnClientClaim]` is called when the server acknowledges that the droplet has been claimed.

    - `[OnClientCollect]` is called when the droplet hits the player and is considered collected.
    It should be used for collection effects and other client side things.

    - `[OnServerCollect]` is called once the server is informed by a client that the droplet has
    been collected. This is where you should perform any server side logic like actually
    giving things like Money or Exp.
]=]
export type ResourceTypeData = {
    Defaults: {
        Value: any?;
        CollectorMode: CollectorMode?;
        Count: NumOrRangeOrWeightedArray?,
        LifeTime: NumOrRangeOrWeightedArray?,
        EjectionDuration: NumOrRangeOrWeightedArray?,
        EjectionHorizontalVelocity: NumOrRangeOrWeightedArray?,
        EjectionVerticalVelocity: NumOrRangeOrWeightedArray?,

        Mass: number?,
        MaxForce: number?,
        MaxVelocity: number?,
        CollectionRadius: number?,

        --CalculateAttraction: (droplet: Droplet, player: Player) -> Vector3?,
    };

    SetupDroplet: (droplet: Droplet) -> any?,
    OnRenderUpdate: ((droplet: Droplet, time: number) -> (CFrame?))?,
    OnDropletTimeout: ((droplet: Droplet) -> ())?,
    OnClientClaim: ((playerWhoCollected: Player, droplet: Droplet) -> ())?,
    OnClientCollect: ((playerWhoCollected: Player, droplet: Droplet) -> ())?,
    OnServerCollect: ((playerWhoCollected: Player, value: any, metadata: any) -> ())?,
}

--[=[
    @within DropletUtil
    @interface ResourceSpawnData
    .ResourceType string -- The registered name of the resource type
    .Value any | NumOrRangeOrWeightedArray -- The value of the droplet
    .Metadata any? -- The metadata of the droplet
    .SpawnLocation Vector3 | CFrame | PVInstance -- The location to spawn the droplet
    .CollectorMode CollectorMode? -- The behavior of how the droplet is claimed
    .PlayerTargets Player | {Player}? -- The players that can collect the droplet
    .LifeTime NumOrRange? -- The time before the droplet dissapears
    .Count NumOrRangeOrWeightedArray? -- The number of droplets to spawn
    .EjectionDuration NumOrRangeOrWeightedArray? -- The time it takes to spew out all the droplets
    .EjectionHorizontalVelocity NumOrRangeOrWeightedArray? -- The horizontal velocity of the droplets when they are ejected
    .EjectionVerticalVelocity NumOrRangeOrWeightedArray? -- The vertical velocity of the droplets when they are ejected

    :::caution Special Behaviors
    Any index that takes a `NumOrRangeOrWeightedArray` will be parsed and calculated
    ahead of time internally so that the client and server are synced. For example,
    if you pass in a `NumberRange` for `Value`, the server will calculate a random
    decimal number between the min and max, this number would then be accessed by
    `Droplet:GetValue()` on the client.
    :::
]=]
export type ResourceSpawnData = {
    ResourceType: string,
    Value: any;
    Metadata: any?;
    SpawnLocation: Vector3 | CFrame | PVInstance;
    CollectorMode: CollectorMode?; -- defaults to DEFAULT_COLLECTOR_MODE
    PlayerTargets: (Player | {Player})?; -- defaults to all players
    
    LifeTime: NumOrRange?;
    Count: NumOrRangeOrWeightedArray?;
    EjectionDuration: NumOrRangeOrWeightedArray?;
    EjectionHorizontalVelocity: NumOrRangeOrWeightedArray?,
    EjectionVerticalVelocity: NumOrRangeOrWeightedArray?,
}


-- The data that is sent to the clients
export type DropletNetworkPacket = {
    -- Data set by Server
    Seed: number, -- The seed of the droplet request (akin to the Id)
    Count: number, -- The number of droplets to spawn
    SpawnTime: number, -- The moment the spawn request was made (os.clock)
    CollectorMode: CollectorMode, -- The mode of the collector
    EjectionDuration: number, -- The time it takes to eject/spawn all the droplets (in seconds)
    EjectionHorizontalVelocity: NumOrRangeOrWeightedArray?, -- The horizontal velocity of the droplets when they are ejected
    EjectionVerticalVelocity: NumOrRangeOrWeightedArray?, -- The vertical velocity of the droplets when they are ejected

    -- Data directly passed by ResourceSpawnData
    ResourceType: string,
    Value: any?;
    Metadata: any?;
    SpawnLocation: Vector3 | CFrame | {Obj: PVInstance, CF: CFrame};
    LifeTime: NumOrRange;
}

-- The data that is stored by the server
export type DropletServerCacheData = {
    NetworkPacket: DropletNetworkPacket,
    PlayerTargets: {Player},

    DropletData: {[number]: {
        CollectedBy: {Player}?,
        ClaimedBy: {Player}?,
        ActualValue: any?,
    }}
}

--------------------------------------------------------------------------------
    --// Enums //--
--------------------------------------------------------------------------------

--[=[
    @within DropletUtil
    @prop Enums {CollectorMode: {MultiCollector: CollectorMode, SingleCollector: CollectorMode}}
]=]
local Enums = {}
DropletUtil.Enums = Enums

--[=[
    @within DropletUtil
    @type CollectorMode "MultiCollector" | "SingleCollector"
    The behavior of how the droplet is claimed.

    - `MultiCollector` - Many players can collect this droplet, each has their own individual instance

    - `SingleCollector` - Only one player can collect this droplet
]=]
export type CollectorMode = "MultiCollector" | "SingleCollector"
Enums.CollectorMode = {
    MultiCollector = "MultiCollector", -- Many players can collect this droplet, each has their own individual instance
    SingleCollector = "SingleCollector", -- Only one player can collect this droplet
}

--------------------------------------------------------------------------------
    --// Constants //--
--------------------------------------------------------------------------------

--[=[
    @within DropletUtil
    @private
    @prop DROPLET_COLLISION_GROUP string
    The default collision group for droplets
]=]
DropletUtil.DROPLET_COLLISION_GROUP = "Droplet"

--------------------------------------------------------------------------------
    --// Utility functions //--
--------------------------------------------------------------------------------

local function IsWeightedArray(tbl: table | any): boolean
    if typeof(tbl) ~= "table" then 
        return false 
    end

    local hasNumericIndex = (tbl :: table)[1] ~= nil
    if not hasNumericIndex then return false end

    local hasWeight = (tbl :: table)[1].Weight ~= nil
    local hasValue = (tbl :: table)[1].Value ~= nil

    return hasWeight and hasValue
end

--[=[
    @private
]=]
function DropletUtil.parse(v: NumOrRangeOrWeightedArray | any, numGen: Random): number
    if typeof(v) == "NumberRange" then
        return numGen:NextNumber(v.Min, v.Max)
    elseif IsWeightedArray(v) then
        local distributor = ProbabilityDistributor.new(v :: any, numGen)
        return DropletUtil.parse(distributor:Roll(), numGen)
    end
    assert(typeof(v) == "number", "Invalid value type")
    return v
end

--[=[
    @private
]=]
function DropletUtil.calculateDropletValues(value: any | NumOrRangeOrWeightedArray, count: number, seed: number, lifeTime: NumOrRangeOrWeightedArray)
    local NumGen = Random.new(seed)

    local values = {}
    for i = 1, count do
        values[i] = {
            RawValue = DropletUtil.parse(value, NumGen);
            RawLifeTime = DropletUtil.parse(lifeTime, NumGen);
        }
    end

    return values
end


return DropletUtil