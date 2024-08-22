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
local Droplet = require(script.Parent.Droplet)
local RailUtil = require(Packages.RailUtil)
local OctoTree = require(Packages.OctoTree)
local NetWire = require(Packages.NetWire)
local SuperClass = require(Packages.BaseObject)

--// Types //--
type Droplet = Droplet.Droplet
type ResourceTypeData = DropletUtil.ResourceTypeData
type DropletNode = any --OctoTree.Node<Droplet> -- TODO: Add OctoTree types
type DropletOctree = OctoTree.Octree<Droplet>

--// Constants //--
local DEFAULT_COLLECTION_RADIUS = 15

local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

local DropletsFolder = Instance.new("Folder")
DropletsFolder.Name = "Droplets"
DropletsFolder.Parent = workspace

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
--// CLASS //--
--------------------------------------------------------------------------------

local SINGLETON

local DropletClientManager = setmetatable({}, SuperClass)
DropletClientManager.ClassName = "DropletClientManager"
DropletClientManager.__index = DropletClientManager

local function AssertIsSingleton(self)
    assert(self == SINGLETON, "Called method on class instead of singleton")
end

--[=[
    @tag constructor
    @return DropletClientManager

    Creates a new DropletClientManager if one has not already been made,
    returns the existing one if one already exists.
]=]
function DropletClientManager.new()
    if SINGLETON then return SINGLETON end
    local self = setmetatable(SuperClass.new(), DropletClientManager)
    SINGLETON = self

    self._DropletStorage = {}
    self._ResourceTypeDataMap = {}

    if RunService:IsRunning() then
        self._Replicator = NetWire.Client("DropletService")

        self._Replicator.DropletCreated:Connect(function(...)
            self:_OnCreateDroplet(...)
        end)

        self._Replicator.DropletClaimed:Connect(function(...: any)
            self:_OnClaimDroplet(...)
        end)
    else
        warn("Loaded DropletClientManager in edit mode")
    end

    self._RenderOctoTree = OctoTree.new() :: DropletOctree
    self._MagnetOctoTree = OctoTree.new() :: DropletOctree
    self._CollectionTracker = setmetatable({}, {__mode = "k"})

    self._RenderRadius = 100

    self:AddTask(RunService.PreSimulation:Connect(function(dt: number)
        self:_Update(dt)
    end))

    -- self:RegisterResourceType("Test", Import("TestResourceTypeData"))
    
    return self
end


--------------------------------------------------------------------------------
    --// Methods //--
--------------------------------------------------------------------------------

--[=[
    Registers a new resource type.
]=]
function DropletClientManager:RegisterResourceType(resourceType: string, data: ResourceTypeData)
    AssertIsSingleton(self)
    assert(not self._ResourceTypeDataMap[resourceType], "Resource type already registered")
    self._ResourceTypeDataMap[resourceType] = data
end

--[=[
    Returns the resource type data for the given resource type
]=]
function DropletClientManager:GetResourceTypeData(resourceType: string): ResourceTypeData?
    AssertIsSingleton(self)
    return self._ResourceTypeDataMap[resourceType]
end

--[=[
    Gets the distance at which a droplet must be within to be collected by the LocalPlayer
]=]
function DropletClientManager:GetCollectionRadius(): number
    AssertIsSingleton(self)
    return self._Replicator.CollectionRadius:Get() or DEFAULT_COLLECTION_RADIUS
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

    local CollectionTracker = self._CollectionTracker
    
    debug.profilebegin("Droplet Collection Check")
    if LocalPlayer.Character and LocalPlayer.Character.PrimaryPart then
        local PlayerPos = LocalPlayer.Character:GetPivot().Position

        for node: DropletNode in self._MagnetOctoTree:ForEachInRadius(PlayerPos, self:GetCollectionRadius()) do
            local droplet = node.Object
            if not CollectionTracker[droplet] then
                CollectionTracker[droplet] = true
                self:_RequestClaimDroplet(droplet)
            end
        end
    end
    debug.profileend()

    debug.profilebegin("Droplet Position Update")
    Droplet.processRendering()
    debug.profileend()

    debug.profilebegin("Droplet Visualization Update")
    local isOnScreen = RailUtil.Camera.isOnScreen
    local pos: Vector3 = (Camera.CFrame + Camera.CFrame.LookVector * (self._RenderRadius/2)).Position
    for node: DropletNode in self._RenderOctoTree:ForEachInRadius(pos, self._RenderRadius) do
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
    local octree = self._MagnetOctoTree
    local node = octree:CreateNode(droplet:GetPosition(), droplet)

    droplet:GetSignal("PositionChanged"):Connect(function(newPos)
        octree:ChangeNodePosition(node, newPos)
    end)

    local function Remove() octree:RemoveNode(node) end
    droplet:GetSignal("Timedout"):Once(Remove)
    droplet:GetDestroyedSignal():Once(Remove)
end

--[=[
    @private
    Marks a droplet for rendering by placing it into the octree
]=]
function DropletClientManager:_MarkForRender(droplet: Droplet)
    local octree = self._RenderOctoTree
    local node = octree:CreateNode(droplet:GetPosition(), droplet)

    droplet:GetSignal("PositionChanged"):Connect(function(newPos)
        octree:ChangeNodePosition(node, newPos)
    end)
    
    local function Remove() octree:RemoveNode(node) end
    droplet:GetSignal("Timedout"):Once(Remove)
    droplet:GetDestroyedSignal():Once(Remove)
end

--[=[
    @private
    Called when the server informs us that a new droplet has been created
]=]
function DropletClientManager:_OnCreateDroplet(networkPacket: DropletUtil.DropletNetworkPacket)
    local rtData = self:GetResourceTypeData(networkPacket.ResourceType)
    assert(rtData, `Resource type '{tostring(networkPacket.ResourceType)}' not registered`)
    local DEFAULTS = rtData.Defaults

    local Seed = networkPacket.Seed
    local Value = networkPacket.Value
    local Count = networkPacket.Count
    local LifeTime = networkPacket.LifeTime
    networkPacket.Metadata = networkPacket.Metadata or DEFAULTS.Metadata

    local Droplets: {[number]: Droplet} = {}
    self._DropletStorage[Seed] = {
        NetworkPacket = networkPacket,
        Droplets = Droplets,
    }

    local NumGen = Random.new(Seed)
    local EjectionDuration = DropletUtil.parse(networkPacket.EjectionDuration, NumGen)

    for i, rawData in pairs(DropletUtil.calculateDropletValues(Value, Count, Seed, LifeTime)) do
        local droplet = Droplet.new({
            Id = i,
            NetworkPacket = networkPacket,
            ResourceTypeData = self:GetResourceTypeData(networkPacket.ResourceType),

            Value = rawData.RawValue,
            LifeTime = rawData.RawLifeTime,

            DropletClientManager = self,
        })

        droplet:GetDestroyedSignal():Once(function()
            -- print(`Droplet [{Seed}][{i}] destroyed`)
            Droplets[i] = nil
        end)

        droplet:GetSignal("Collected"):Connect(function(collector)
            if collector == LocalPlayer then
                self:_RequestCollectDroplet(droplet)
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
    local dropletRequest = self._DropletStorage[seed]
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
    self._Replicator.DropletClaimed:Fire(seed, dropletId)
end

--[=[
    @private
    Inform the server the client successfully collected the droplet.
]=]
function DropletClientManager:_RequestCollectDroplet(droplet: Droplet)
    local seed, dropletId = droplet:Identify()
    --print(`Requesting collect of droplet [{seed}][{dropletId}]`)
    self._Replicator.DropletCollected:Fire(seed, dropletId)
end


return DropletClientManager