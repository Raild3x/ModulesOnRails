-- Authors: Logan Hunt (Raildex)
-- January 17, 2024
--[=[
    @class Droplet
]=]

--// Services //--
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

if not RunService:IsClient() then
    return {} :: Droplet
end

--// Imports //--
local Packages = script.Parent.Parent.Parent
local DropletUtil = require(script.Parent.Parent.DropletUtil)
local RailUtil = require(Packages.RailUtil)
local SuperClass = require(Packages.BaseObject)

--// Constants //--
local PLAYER_MASS = 150 -- 1_000_000
local MAXIMUM_DISPLAY_COLLECT_DISTANCE = 80 -- The furthest distance a player can be from a droplet for us to show the collection visual

--// Types //--
type ResourceTypeData = DropletUtil.ResourceTypeData

--// References //--
local WorldAlignAttachment = Instance.new("Attachment")
WorldAlignAttachment.Name = "DropletWorldAlignAttachment"
WorldAlignAttachment.Parent = workspace.Terrain

local CharactersList = {}

local ResourceHeightRayParams = RaycastParams.new()
ResourceHeightRayParams.FilterType = Enum.RaycastFilterType.Exclude
ResourceHeightRayParams.CollisionGroup = DropletUtil.DROPLET_COLLISION_GROUP
ResourceHeightRayParams.FilterDescendantsInstances = {}

RailUtil.Player.forEachCharacter(function(Character, janitor)
    table.insert(CharactersList, Character)
    ResourceHeightRayParams.FilterDescendantsInstances = CharactersList

    janitor:Add(function()
        RailUtil.Table.SwapRemoveFirstValue(CharactersList, Character)
        ResourceHeightRayParams.FilterDescendantsInstances = CharactersList
    end)
end)


local BulkRenderData = {
    Size = 0;
    Parts = {};
    CFrames = {};
}

--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local truncate = RailUtil.Vector.truncate

local function TryCall(fn: ((...any) -> (...any))?, ...): (...any)
    if not fn then return end
    return fn(...)
end

local GravitationalConstant = 1 -- 6.67408e-11
local function CalculateGravitationalAttraction(m1: number, m2: number, distance: number)
    return GravitationalConstant * ((m1 * m2) / distance^2)
end

local function GenerateNewActor()
    local ActorTemplate = Instance.new("Actor")
    do
        local CorePart = Instance.new("Part")
        CorePart.Name = "Core"
        CorePart.Size = Vector3.one * 2
        CorePart.Anchored = false
        CorePart.CanCollide = true
        CorePart.CanTouch = false
        CorePart.CanQuery = false
        CorePart.CastShadow = false
        CorePart.Transparency = 1
        CorePart.TopSurface = Enum.SurfaceType.Smooth
        CorePart.BottomSurface = Enum.SurfaceType.Smooth
        CorePart.Shape = Enum.PartType.Ball
        CorePart.CollisionGroup = DropletUtil.DROPLET_COLLISION_GROUP
        CorePart.Parent = ActorTemplate

        local DropletAttachment = Instance.new("Attachment")
        DropletAttachment.Name = "DropletAttachment"
        DropletAttachment.Parent = CorePart
        
        local AlignOrientation = Instance.new("AlignOrientation")
        AlignOrientation.Attachment0 = DropletAttachment
        AlignOrientation.Attachment1 = WorldAlignAttachment
        AlignOrientation.Parent = CorePart

         --// Set up the VectorForce (This causes a slower fall, reducing the force of gravity)
        local VectorForce: VectorForce = Instance.new("VectorForce")
        VectorForce.Attachment0 = DropletAttachment
        VectorForce.Force = Vector3.new(0, 100, 0)
        VectorForce.ApplyAtCenterOfMass = true
        VectorForce.Parent = CorePart

        local AttachmentPart = Instance.new("Part")
        AttachmentPart.Name = "AttachmentPart"
        AttachmentPart.Size = Vector3.one * 0.2
        AttachmentPart.Anchored = false
        AttachmentPart.CanCollide = false
        AttachmentPart.CanTouch = false
        AttachmentPart.CanQuery = false
        AttachmentPart.CastShadow = false
        AttachmentPart.Massless = true
        AttachmentPart.Transparency = 1
        AttachmentPart.Parent = ActorTemplate
    
        local Weld = Instance.new("Weld")
        Weld.Part0 = CorePart
        Weld.Part1 = AttachmentPart
        Weld.C0 = CFrame.new(0, 0, 0)
        Weld.Parent = ActorTemplate
    
        ActorTemplate.Name = "Droplet"
        ActorTemplate.PrimaryPart = CorePart
    end
    return ActorTemplate
end

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local Droplet = setmetatable({}, SuperClass)
Droplet.ClassName = "Droplet"
Droplet.__index = Droplet

--[=[
    @private
    Called by DropletClientManager
]=]
function Droplet.processRendering()
    workspace:BulkMoveTo(BulkRenderData.Parts, BulkRenderData.CFrames, Enum.BulkMoveMode.FireCFrameChanged)
    BulkRenderData.Size = 0
    table.clear(BulkRenderData.Parts)
    table.clear(BulkRenderData.CFrames)
end

--[=[
    @private
    Creates a new Droplet instance. Called by DropletClientManager.
    @param config -- The configuration for the droplet.
    @return Droplet
]=]
function Droplet.new(config: {
    Id: number;
    NetworkPacket: DropletUtil.DropletNetworkPacket;
    ResourceTypeData: DropletUtil.ResourceTypeData;

    Value: any?,
    LifeTime: number,

    DropletClientManager: any,
})
    local self = setmetatable(SuperClass.new(), Droplet)

    self:RegisterSignal("PositionChanged")
    self:RegisterSignal("Timedout")
    self:RegisterSignal("Collected")

    self._RenderClock = 0
    self._FrequencyBoost = 1 + Random.new():NextNumber(-0.1, 0.1)

    self._DropletId = config.Id
    self._Value = config.Value
    self._NetworkPacket = config.NetworkPacket
    self._ResourceTypeData = config.ResourceTypeData

    local DEFAULTS = self._ResourceTypeData.Defaults or {}
    self._CollectionRadius = DEFAULTS.CollectionRadius or 1.5
    self._MaxVelocity = DEFAULTS.MaxVelocity or 150
    self._MaxForce = DEFAULTS.MaxForce or math.huge
    self._Mass = DEFAULTS.Mass or 1

    self._Model = GenerateNewActor()
    self._Weld = self._Model.Weld
    self:BindToInstance(self._Model)

    local RTData = self:GetResourceTypeData()
    if RTData.SetupDroplet then
        self._CustomSetupData = RTData.SetupDroplet(self) or {}
    else
        warn("No Setup function for resource type "..self._NetworkPacket.ResourceType)
    end

    self:AddTask(task.delay(config.LifeTime, function()
        -- warn(`Droplet expired: [{config.NetworkPacket.Seed}][{config.Id}]`)
        self._TimingOut = true
        self:FireSignal("Timedout")
        TryCall(RTData.OnDropletTimeout, self)
        self:Destroy()
    end), nil, "LifeTimeThread")

    --------------------------------
    -- Settle Checkers --
    --------------------------------

    local DropletClientManager = config.DropletClientManager

    local CorePart = self:GetModel().PrimaryPart

    self:AddTask(RunService.Heartbeat:Connect(function(dt)
        if CorePart.AssemblyLinearVelocity.Y < 0 then
            DropletClientManager:_MarkForCollection(self)
            DropletClientManager:_MarkForRender(self)
            self:RemoveTask("CollectionCheck")
        end
    end), nil, "CollectionCheck")


    local settledFor = 0
    self:AddTask(RunService.Heartbeat:Connect(function(dt)
        self:FireSignal("PositionChanged", self:GetPosition())

        if CorePart.AssemblyLinearVelocity.Magnitude * dt <= 0.1 then
            settledFor += dt
            if settledFor >= 0.5 then
                CorePart.Anchored = true
                CorePart.CanCollide = false
                self:RemoveTask("SettleCheck")
            end
        end
    end), nil, "SettleCheck")

    return self
end

--------------------------------------------------------------------------------
    --// Getters //--
--------------------------------------------------------------------------------

--[=[
    
]=]
function Droplet:GetValue(): any
    return self._Value
end

--[=[
    
]=]
function Droplet:GetMetadata(): any?
    return self._NetworkPacket.Metadata
end

--[=[
    
]=]
function Droplet:GetResourceTypeData(): ResourceTypeData
    return self._ResourceTypeData
end

--[=[
    
]=]
function Droplet:GetPosition(): Vector3
    return self:GetPivot().Position;
end

--[=[
    @private
]=]
function Droplet:GetPivot(): CFrame
    return self._Model:GetPivot()
end

--[=[
    
]=]
function Droplet:GetModel(): Actor
    return self._Model;
end


--[=[
    Returns the data that was returned by the ResourceTypeData.Setup function
]=]
function Droplet:GetSetupData(): any
    return self._CustomSetupData;
end

--[=[
    Returns the seed and id of the droplet. Used for internal identification.
    @return number -- The seed of the droplet
    @return number -- The id of the droplet
]=]
function Droplet:Identify(): (number, number)
    return self._NetworkPacket.Seed, self._DropletId
end

--[=[
    Returns whether or not the droplet is in the process of timing out.
]=]
function Droplet:IsTimingOut(): boolean
    return self._TimingOut == true;
end


--------------------------------------------------------------------------------
    --// Methods //--
--------------------------------------------------------------------------------

--[=[
    Attaches a Model or Part to the droplet. Use this to add your visuals to the droplet.
]=]
function Droplet:AttachModel(object: Model | BasePart)
    local CorePart
    if object:IsA("BasePart") then
        CorePart = object
    else
        CorePart = object.PrimaryPart
        assert(CorePart, "Model must have a PrimaryPart")
    end

    (object :: any).Parent = self:GetModel()

    local Weld = Instance.new("Weld")
    Weld.Part0 = self:GetModel():FindFirstChild("AttachmentPart")
    Weld.Part1 = CorePart
    Weld.C0 = CFrame.new(0, 0, 0)
    Weld.Parent = CorePart

    return Weld
end

--[=[
    
]=]
function Droplet:Collect(playerWhoCollected: Player)
    self:RemoveTask("MagnetizationThread")

    local RTData = self:GetResourceTypeData()
    TryCall(RTData.OnClientCollect, playerWhoCollected, self)

    self:FireSignal("Collected", playerWhoCollected)

    task.defer(function()
        self:Destroy()
    end)
end

--[=[
    
]=]
function Droplet:Claim(playerWhoClaimed: Player)
    if self:IsTimingOut() then return warn("Tried to claim but is already Timing Out!") end
    self:RemoveTask("LifeTimeThread")

    self:Magnetize(playerWhoClaimed)

    local RTData = self:GetResourceTypeData()
    TryCall(RTData.OnClientClaim, playerWhoClaimed, self)
end

--[=[
    @private
]=]
function Droplet:Magnetize(playerWhoCollected: Player)
    self:RemoveTask("LifeTimeThread")

    local PlayerExists = playerWhoCollected and playerWhoCollected.Parent == Players
    local Character = PlayerExists and playerWhoCollected.Character

    local GRAVITY = Vector3.new(0, -1, 0)

    local function BeginMagnetization()
        local Model: Actor = self:GetModel()
        local CorePart = Model.PrimaryPart
        assert(CorePart, "Model must have a PrimaryPart")
        CorePart.BrickColor = BrickColor.new("Bright red")

		-- Avoid raycasting to include the visual model of the droplet itself in case it's a [Model].
		ResourceHeightRayParams:AddToFilter(Model)

        CorePart.Anchored = true
        CorePart.CanCollide = false

        local MagnetizationStartTime = os.clock()

        local Velocity = CorePart.AssemblyLinearVelocity * Vector3.new(1,0.5,1)
        local function Update(dt: number)
            -- Handle situation where the player its magnetizing towards leaves the game/dies
            if playerWhoCollected.Parent ~= Players or not playerWhoCollected.Character then
                self:Collect(playerWhoCollected)
                return
            end

            local currentPos = CorePart.Position
            local targetCharacter = playerWhoCollected.Character
            local targetPos = targetCharacter.PrimaryPart.Position - Vector3.new(0,1,0)
            
            local targetVector = (targetPos - currentPos)
            local targetDist = targetVector.Magnitude

            local DesiredVelocity = targetVector.Unit * self._MaxVelocity
            local Steering = DesiredVelocity - Velocity -- find the direction of force we need to apply
            local attractionForce = CalculateGravitationalAttraction(self._Mass, PLAYER_MASS, targetDist)
            Steering += DesiredVelocity * attractionForce
            Steering = truncate(Steering, self._MaxForce) -- limit the steering force
            Steering /= self._Mass

            -- Update our velocities. We multiply by dt to apply the appropriate amount of force based on how much time has passed
            Velocity = truncate(Velocity + Steering * dt, self._MaxVelocity) :: Vector3
            local g = GRAVITY * dt
            if currentPos.Y < targetPos.Y then
                g /= math.max(1, targetPos.Y - currentPos.Y)
            end
            Velocity += g
            
            -- Magnetize towards our target player
            local Displacement = Velocity * dt -- distance moved since last frame
            --local newDist = (targetPos - (currentPos + Displacement)).Magnitude
            local newPos = currentPos + Displacement

            --[[
                Check to see if we would have passed through the ground, if so then shift upwards.
                This is not a perfect solution but it should work for most cases. Used to prevent
                ugly ground clipping. If the droplet has been magnetizing for more than 5 seconds
                then we don't do this check.
            ]]
            if os.clock() - MagnetizationStartTime < 5 then
                local RayHeight = 2
                local rayResults = workspace:Raycast(newPos + Vector3.yAxis*RayHeight, Vector3.new(0,-(RayHeight + 0.5),0), ResourceHeightRayParams)
                if rayResults then
                    if rayResults.Position.Y + 0.5 > newPos.Y then
                        newPos = Vector3.new(
                            newPos.X,
                            rayResults.Position.Y + 0.5,
                            newPos.Z
                        )
                    end
                end
            end
            
            BulkRenderData.Size += 1
            BulkRenderData.Parts[BulkRenderData.Size] = CorePart
            BulkRenderData.CFrames[BulkRenderData.Size] = CFrame.new(newPos)
            --CorePart.Position += (newPos - currentPos) -- is this more efficient than Model:TranslateBy(Displacement)?
            self:FireSignal("PositionChanged", newPos)

            -- Check to see if we would have passed through our target
            local doesIntersect = targetDist <= self._CollectionRadius
            local didIntersect = RailUtil.Vector.lineSegmentIntersectsSphere(currentPos, newPos, targetPos, self._CollectionRadius)
            if doesIntersect or didIntersect then
                self:Collect(playerWhoCollected)
                return
            end
        end

        self:AddTask(RunService.PreAnimation:Connect(Update), nil, "MagnetizationThread")
    end
    
    --Check if its a valid player and if the player is within a reasonable distance (like if the player is >50 studs away)
    if Character and (Character:GetPivot().Position - self:GetPosition()).Magnitude < MAXIMUM_DISPLAY_COLLECT_DISTANCE then
        BeginMagnetization()
    else
        self:Collect(playerWhoCollected)
    end
end

--------------------------------------------------------------------------------
    --// Private Methods //--
--------------------------------------------------------------------------------

--[=[
    @private
]=]
function Droplet:_Render(dt: number)
    local RTData = self:GetResourceTypeData()
    local WeldCFrame = TryCall(RTData.OnRenderUpdate, self, self._RenderClock)
    if WeldCFrame then
        self._Weld.C0 = WeldCFrame
    end

    self._RenderClock += dt * self._FrequencyBoost
end



--[=[
    @within Droplet
    @type Droplet Droplet
]=]
export type Droplet = typeof(Droplet.new({} :: any))

return Droplet