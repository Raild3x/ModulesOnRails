-- Authors: Logan Hunt (Raildex)
-- January 17, 2024
--[=[
    @class DropletClientManager
    @client
]=]

--// Services //--
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local DropletUtil = require(script.Parent.Parent.DropletUtil)
local DropletsFolder = require(script.Parent.DropletsFolder)
local Droplet = require(script.Parent.Droplet)
local Heap = require(Packages.Heap)
local NetWire = require(Packages.NetWire)
local RailUtil = require(Packages.RailUtil)
local OctoTree = require(Packages.OctoTree)

--// Types //--
type ResourceTypeData = DropletUtil.ResourceTypeData
type Droplet = Droplet.Droplet

--// Constants //--
local DEFAULT_COLLECTION_RADIUS = 15
local RENDER_RADIUS: number = 100

local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
--// Util Functions //--
--------------------------------------------------------------------------------

local function CalculateEjectionVelocity(hForce, vForce, NumGen: Random): Vector3

    local HorizontalForce = DropletUtil.parse(hForce, NumGen) or NumGen:NextInteger(2, 25)
    local VerticalForce = DropletUtil.parse(vForce, NumGen) or NumGen:NextInteger(25, 50)

    --// Generate a random force for the X and Z axis from a circular distribution
    local RandomRotation = NumGen:NextNumber(-math.pi, math.pi)
    local RandomDirection = RailUtil.Vector.rotateVector2(Vector2.new(1,0), RandomRotation)
    local RandomForce = RandomDirection * HorizontalForce

    local EjectionVelocity = Vector3.new(RandomForce.X, VerticalForce, RandomForce.Y)
    return EjectionVelocity
end

local function ParseLocation(location): CFrame
    if typeof(location) == "Vector3" then
        return CFrame.new(location)
    elseif typeof(location) == "CFrame" then
        return location
    elseif typeof(location) == "table" then
        if location.Obj then
            return location.Obj:GetPivot()
        end
        return location.CF
    end
    error("Invalid location type: "..tostring(location))
end

--------------------------------------------------------------------------------
--// MODULE STATE //--
--------------------------------------------------------------------------------
local DropletClientManager = {}

local DropletStorage: {[number]: Droplet} = {}
local ResourceTypeDataMap: {[string]: ResourceTypeData} = {}
local RenderOctoTree: OctoTree.Octree<Droplet> = OctoTree.new()
local MagnetOctoTree: OctoTree.Octree<Droplet> = OctoTree.new()
local DistanceHeap: Heap.Heap<number> = Heap.max()
local CollectionTracker = setmetatable({} :: {[Droplet]: boolean}, {__mode = "k"})

local Replicator = NetWire.Client("DropletServerManager")
Replicator.DropletCreated:Connect(function(...)
    (DropletClientManager :: any):_OnCreateDroplet(...)
end)

Replicator.DropletClaimed:Connect(function(...: any)
    (DropletClientManager :: any):_OnClaimDroplet(...)
end)

RunService.PreSimulation:Connect(function(dt: number)
    (DropletClientManager :: any):_Update(dt)
end)

--------------------------------------------------------------------------------
    --// METHODS //--
--------------------------------------------------------------------------------

--[=[
    Registers a new resource type.
]=]
function DropletClientManager:RegisterResourceType(resourceType: string, data: ResourceTypeData)
    assert(not ResourceTypeDataMap[resourceType], "Resource type already registered")
    ResourceTypeDataMap[resourceType] = data
end

--[=[
    Returns the resource type data for the given resource type
]=]
function DropletClientManager:GetResourceTypeData(resourceType: string): ResourceTypeData?
    return ResourceTypeDataMap[resourceType]
end

--------------------------------------------------------------------------------
    --// Private //--
--------------------------------------------------------------------------------

--[=[
    @private
    @param dt The delta time since the last update

    Checks for droplets that are within the collection radius and marks
    them as being collected as well as updates the droplet visualization
]=]
function DropletClientManager:_Update(dt: number)
    dt = dt or 0

    local CollectionTracker: {[Droplet]: boolean} = CollectionTracker
    
    debug.profilebegin("Droplet Collection Check")
    if LocalPlayer.Character and LocalPlayer.Character.PrimaryPart then
        local PlayerPos = LocalPlayer.Character:GetPivot().Position

        -- Use the maximum magnetization radius from the heap to determine search radius
        local maxMagnetizationRadius = DistanceHeap:Peek() or DEFAULT_COLLECTION_RADIUS
        
        for node in MagnetOctoTree:ForEachInRadius(PlayerPos, maxMagnetizationRadius) do
            local droplet = node.Object
            if CollectionTracker[droplet] then
                continue
            end
            local dropletPos = node.Position
            local distance = (PlayerPos - dropletPos).Magnitude
            
            -- Check if within this droplet's specific magnetization radius
            if distance <= droplet:GetMagnetizationRadius() then
                -- Check if it must settle before collecting
                if not droplet:MustSettleBeforeCollect() or droplet:IsSettled() then
                    CollectionTracker[droplet] = true
                    DropletClientManager:_RequestClaimDroplet(droplet)
                end
            end
        end
    end
    debug.profileend()

    debug.profilebegin("Droplet Position Update")
    Droplet.processRendering()
    debug.profileend()

    debug.profilebegin("Droplet Visualization Update")
    local isOnScreen = RailUtil.Camera.isOnScreen
    local pos: Vector3 = (Camera.CFrame + Camera.CFrame.LookVector * (RENDER_RADIUS/2)).Position
    for node in RenderOctoTree:ForEachInRadius(pos, RENDER_RADIUS) do
        if isOnScreen(node.Position) then
            node.Object:_Render(dt)
        end
    end
    debug.profileend()
end

--[=[
    @private
    Marks a droplet to be checked for collection
]=]
function DropletClientManager:_MarkForCollection(droplet: Droplet)
    assert(not MagnetOctoTree:FindFirstNode(droplet), "Droplet already marked for collection")
    local node = MagnetOctoTree:CreateNode(droplet:GetPosition(), droplet)

    droplet:GetSignal("PositionChanged"):Connect(function(newPos)
        MagnetOctoTree:ChangeNodePosition(node, newPos)
    end)

    -- Track magnetization radius in heap for dynamic radius checking
    local magnetizationRadius = droplet:GetMagnetizationRadius()
    DistanceHeap:Push(magnetizationRadius)

    local function Remove() 
        MagnetOctoTree:RemoveNode(node)
        DistanceHeap:RemoveFirstOccurrence(magnetizationRadius)
    end
    droplet:GetSignal("TimedOut"):Once(Remove)
    droplet:GetDestroyedSignal():Once(Remove)
end

--[=[
    @private
    Marks a droplet for rendering by placing it into the octree
]=]
function DropletClientManager:_MarkForRender(droplet: Droplet)
    assert(not RenderOctoTree:FindFirstNode(droplet), "Droplet already marked for render")
    local node = RenderOctoTree:CreateNode(droplet:GetPosition(), droplet)

    droplet:GetSignal("PositionChanged"):Connect(function(newPos)
        RenderOctoTree:ChangeNodePosition(node, newPos)
    end)

    local function Remove() RenderOctoTree:RemoveNode(node) end
    droplet:GetSignal("TimedOut"):Once(Remove)
    droplet:GetDestroyedSignal():Once(Remove)
end

--[=[
    @private
    Called when the server informs us that a new droplet has been created
]=]
function DropletClientManager:_OnCreateDroplet(networkPacket: DropletUtil.DropletNetworkPacket)
    local rtData = DropletClientManager:GetResourceTypeData(networkPacket.ResourceType)
    assert(rtData, `Resource type '{tostring(networkPacket.ResourceType)}' not registered`)
    local DEFAULTS = rtData.Defaults

    local Seed = networkPacket.Seed
    local Value = networkPacket.Value
    local Count = networkPacket.Count
    local LifeTime = networkPacket.LifeTime
    networkPacket.Metadata = networkPacket.Metadata or DEFAULTS.Metadata

    local Droplets: {[number]: Droplet} = {}
    DropletStorage[Seed] = {
        NetworkPacket = networkPacket,
        Droplets = Droplets,
    }

    local NumGen = Random.new(Seed)
    local EjectionDuration = DropletUtil.parse(networkPacket.EjectionDuration, NumGen)

    for i, rawData in DropletUtil.calculateDropletValues(Value, Count, Seed, LifeTime) do
        local droplet = Droplet.new({
            Id = i,
            NetworkPacket = networkPacket,
            ResourceTypeData = DropletClientManager:GetResourceTypeData(networkPacket.ResourceType),

            Value = rawData.RawValue,
            LifeTime = rawData.RawLifeTime,

            DropletClientManager = DropletClientManager,
        })

        droplet:AddTask(function()
            -- print(`Droplet [{Seed}][{i}] destroyed`)
            Droplets[i] = nil
        end)

        droplet:GetSignal("Collected"):Connect(function(collector)
            if collector == LocalPlayer then
                DropletClientManager:_RequestCollectDroplet(droplet)
            end
        end)


        local dropletModel: Model = droplet:GetModel()
        dropletModel:PivotTo(ParseLocation(networkPacket.SpawnLocation))
        dropletModel.Parent = DropletsFolder
        local dropletPrimaryPart = dropletModel.PrimaryPart
        assert(dropletPrimaryPart, "Droplet model has no primary part")
        dropletPrimaryPart.AssemblyLinearVelocity = (CalculateEjectionVelocity(
            networkPacket.EjectionHorizontalVelocity or DEFAULTS.EjectionHorizontalVelocity,
            networkPacket.EjectionVerticalVelocity or DEFAULTS.EjectionVerticalVelocity,
            NumGen
        ))
        

        table.insert(Droplets, droplet)
        task.wait(EjectionDuration/Count)
    end
end


--[=[
    @private
    Called when the server informs us that a droplet has been claimed
]=]
function DropletClientManager:_OnClaimDroplet(collector: Player, seed: number, dropletId: number)
    local dropletRequest = DropletStorage[seed]
    assert(dropletRequest, `No Droplet-Request found with seed '{seed}'`)

    local droplet = dropletRequest.Droplets[dropletId]
    if not droplet then
        warn(dropletRequest.Droplets)
        error(`No Droplet found for [{seed}][{dropletId}]`)
    end

    droplet:Claim(collector)
end


--[=[
    @private
    Ask the server to claim the droplet so that it can be collected by the player
]=]
function DropletClientManager:_RequestClaimDroplet(droplet: Droplet)
    local seed, dropletId = droplet:Identify()
    --print(`Requesting claim of droplet [{seed}][{dropletId}]`)
    Replicator.DropletClaimed:Fire(seed, dropletId)
end

--[=[
    @private
    Inform the server the client successfully collected the droplet.
]=]
function DropletClientManager:_RequestCollectDroplet(droplet: Droplet)
    local seed, dropletId = droplet:Identify()
    --print(`Requesting collect of droplet [{seed}][{dropletId}]`)
    Replicator.DropletCollected:Fire(seed, dropletId)
end


return DropletClientManager