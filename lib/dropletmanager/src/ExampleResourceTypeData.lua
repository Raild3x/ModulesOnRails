-- Authors: Logan Hunt (Raildex)
-- January 19, 2024
    
--[=[
    @class ExampleResourceTypeData
    An Example ResourceTypeData file. This is used to define the general
    behavior of a droplet type.

    ```lua
    local GenericPart = Instance.new("Part")
    GenericPart.Name = "GenericPart"
    GenericPart.Transparency = 1
    GenericPart.Size = Vector3.one
    GenericPart.Anchored = true
    GenericPart.CanCollide = false
    GenericPart.CanTouch = false
    GenericPart.CanQuery = false
    GenericPart.Massless = true


    --------------------------------------------------------------------------------
        --// Data //--
    --------------------------------------------------------------------------------

    return {
        
        Defaults = {
            Value = NumberRange.new(0.6, 1.4); -- The value you want the droplet to have. This can be anything.
            -- Metadata = {}; -- You typically shouldnt default metadata.
            
            Count = NumberRange.new(2, 5); -- Number of droplets to spawn
            LifeTime = NumberRange.new(50, 60); -- Time before the droplet dissapears
            EjectionDuration = 1; -- Time it takes to spew out all the droplets
            EjectionHorizontalVelocity = NumberRange.new(0, 25);
            EjectionVerticalVelocity = NumberRange.new(25, 50);
            CollectorMode = DropletUtil.Enums.CollectorMode.MultiCollector;
            
            Mass = 1; -- Mass of the droplet (Used in magnitization calculations)
            MaxForce = math.huge; -- Maximum steering force applied to the droplet when magnitized to a player
            MaxVelocity = 150; -- Maxiumum velocity of the droplet when magnitized to a player
            CollectionRadius = 1.5; -- Radius from center of player the droplet must be to be considered 'collected'
            MagnetizationRadius = 12; -- Radius from player in which the droplet will start being attracted to the player
            MustSettleBeforeCollect = false; -- Whether the droplet must come to a complete stop before it can be collected
        };

        --[[
            Called when a new droplet is created. Use this to setup your visuals and
            any variables you need to keep track of. All parts within this should be
            Anchored = false, CanCollide = false, and Massless = true.
            The return value of this function can be accessed via Droplet:GetSetupData()
        ]]
        SetupDroplet = function(droplet: Droplet)
            local Value = droplet:GetValue() :: number

            local VisualModel = Instance.new("Model")
            VisualModel.Name = "VisualModel"

            local OuterPart = GenericPart:Clone()
            OuterPart.Name = "Outer"
            OuterPart.Material = Enum.Material.Glass
            OuterPart.Transparency = 0.5
            OuterPart.Color = Color3.fromRGB(16, 206, 16)
            OuterPart.Size = Vector3.one * Value
            OuterPart.Anchored = false
            OuterPart.Parent = VisualModel
            VisualModel.PrimaryPart = OuterPart

            local NumGen = Random.new()

            local InnerPart = OuterPart:Clone()
            InnerPart.Material = Enum.Material.Neon
            InnerPart.Name = "Inner"
            InnerPart.Color = Color3.fromRGB(219, 189, 18)
            InnerPart.Transparency = 0
            InnerPart.CastShadow = false
            InnerPart.Size *= 0.6 + NumGen:NextNumber(-0.1, 0.1)
            InnerPart.CFrame = OuterPart.CFrame + Vector3.new(
                NumGen:NextNumber(-0.1, 0.1),
                NumGen:NextNumber(-0.1, 0.1),
                NumGen:NextNumber(-0.1, 0.1)
            )
            InnerPart.Parent = VisualModel

            local Weld = Instance.new("WeldConstraint")
            Weld.Part0 = OuterPart
            Weld.Part1 = InnerPart
            Weld.Parent = VisualModel

            droplet:AddTask(task.spawn(function()
                for i = 0.025, 1, 0.025 do
                    VisualModel:ScaleTo(i)
                    task.wait()
                end
                VisualModel:ScaleTo(1)
            end), nil, "GrowThread")
            
            droplet:AttachModel(VisualModel)

            return {
                VisualModel = VisualModel;
                SpinDirection = if math.random() > 0.5 then 1 else -1;
            }
        end;

        -- Ran when the droplet is within render range of the LocalPlayer's Camera
        OnRenderUpdate = function(droplet: Droplet, rendertimeElapsed: number)
            local SetupData = droplet:GetSetupData()
            local OffsetCFrame = CFrame.new()

            do -- Bobbing
                local AMPLITUDE = 1 -- Studs of vertical movement (+- half of this)
                local FREQUENCY = 0.25 -- Cycles per second
            
                local Y = (AMPLITUDE * 0.5) * -math.cos((rendertimeElapsed*math.pi) * (FREQUENCY))
                OffsetCFrame *= CFrame.new(0, AMPLITUDE + Y, 0)
            end

            do -- Rotating
                local TimeToMakeOneRotation = 4
                local RotationsPerSecond = 1/TimeToMakeOneRotation
                OffsetCFrame *= CFrame.Angles(0, (rendertimeElapsed*math.pi) * RotationsPerSecond * SetupData.SpinDirection , 0)
            end

            return OffsetCFrame
        end;

        OnDropletTimeout = function(droplet: Droplet)
            local VisualModel = droplet:GetSetupData().VisualModel
            droplet:RemoveTask("GrowThread")
            for i = 1, 0.025, -0.025 do
                VisualModel:ScaleTo(i)
                task.wait()
            end
        end;

        OnClientClaim = function(playerWhoClaimed: Player, droplet: Droplet)
            -- droplet:Collect(playerWhoClaimed)
        end;

        --[[
            Called when the droplet hits the player and is considered collected.
            This is ran on the client only. It should be used for collection effects
            and other client side things.
        ]]
        OnClientCollect = function(playerWhoCollected: Player, droplet: Droplet)
            local Value = droplet:GetValue() :: number

            local Part = GenericPart:Clone()
            Part.CFrame = droplet:GetPivot()

            task.delay(2, function()
                Part:Destroy()
            end)

            local CollectionSound = Instance.new("Sound")
            CollectionSound.SoundId = "rbxassetid://402143943"
            CollectionSound.Volume = 0.25
            
            local PitchShift = Instance.new("PitchShiftSoundEffect")
            PitchShift.Octave = 2 - Value/1.5

            PitchShift.Parent = CollectionSound
            CollectionSound.Parent = Part
            Part.Parent = workspace

            CollectionSound:Play()
        end;

        --[[
            Called once the client informs the server that it has collected the droplet.
        ]]
        OnServerCollect = function(playerWhoCollected: Player, value: any, metadata: any)
            local ExpValue: number = value

            local leaderstats = playerWhoCollected:FindFirstChild("leaderstats")
            if not leaderstats then
                leaderstats = Instance.new("Folder")
                leaderstats.Name = "leaderstats"
                leaderstats.Parent = playerWhoCollected
            end

            local expStat = leaderstats:FindFirstChild("Exp")
            if not expStat then
                expStat = Instance.new("NumberValue")
                expStat.Name = "Exp"
                expStat.Parent = leaderstats
            end

            expStat.Value += ExpValue
            -- Add the value to the player's "exp". This is just an example.
        end;
    }
    ```
]=]

--// Imports //--
local DropletManager = require(script.Parent)
local DropletUtil = DropletManager.Util

type Droplet = DropletManager.Droplet

local GenericPart = Instance.new("Part")
GenericPart.Name = "GenericPart"
GenericPart.Transparency = 1
GenericPart.Size = Vector3.one
GenericPart.Anchored = true
GenericPart.CanCollide = false
GenericPart.CanTouch = false
GenericPart.CanQuery = false
GenericPart.Massless = true


--------------------------------------------------------------------------------
    --// Data //--
--------------------------------------------------------------------------------

return {
    Defaults = {
        Value = NumberRange.new(0.6, 1.4); -- The value you want the droplet to have. This can be anything.
        -- Metadata = {}; -- You typically shouldnt default metadata.

        Count = NumberRange.new(2, 5); -- Number of droplets to spawn
        LifeTime = NumberRange.new(50, 60); -- Time before the droplet dissapears
        EjectionDuration = 1; -- Time it takes to spew out all the droplets
        EjectionHorizontalVelocity = NumberRange.new(0, 25);
        EjectionVerticalVelocity = NumberRange.new(25, 50);
        CollectorMode = DropletUtil.Enums.CollectorMode.MultiCollector;

        Mass = 1; -- Mass of the droplet (Used in magnitization calculations)
        MaxForce = math.huge; -- Maximum steering force applied to the droplet when magnitized to a player
        MaxVelocity = 150; -- Maxiumum velocity of the droplet when magnitized to a player
        CollectionRadius = 1.5; -- Radius from center of player the droplet must be to be considered 'collected'
        MagnetizationRadius = 12; -- Radius from player in which the droplet will start being attracted to the player
        MustSettleBeforeCollect = true; -- Whether the droplet must come to a complete stop before it can be collected
    };

    --[[
        Called when a new droplet is created. Use this to setup your visuals and
        any variables you need to keep track of. All parts within this should be
        Anchored = false, CanCollide = false, and Massless = true.
        The return value of this function can be accessed via Droplet:GetSetupData()
    ]]
    SetupDroplet = function(droplet: Droplet)
        local Value = droplet:GetValue() :: number

        local VisualModel = Instance.new("Model")
        VisualModel.Name = "VisualModel"

        local OuterPart = GenericPart:Clone()
        OuterPart.Name = "Outer"
        OuterPart.Material = Enum.Material.Glass
        OuterPart.Transparency = 0.5
        OuterPart.Color = Color3.fromRGB(16, 206, 16)
        OuterPart.Size = Vector3.one * Value
        OuterPart.Anchored = false
        OuterPart.Parent = VisualModel
        VisualModel.PrimaryPart = OuterPart

        local NumGen = Random.new()

        local InnerPart = OuterPart:Clone()
        InnerPart.Material = Enum.Material.Neon
        InnerPart.Name = "Inner"
        InnerPart.Color = Color3.fromRGB(219, 189, 18)
        InnerPart.Transparency = 0
        InnerPart.CastShadow = false
        InnerPart.Size *= 0.6 + NumGen:NextNumber(-0.1, 0.1)
        InnerPart.CFrame = OuterPart.CFrame + Vector3.new(
            NumGen:NextNumber(-0.1, 0.1),
            NumGen:NextNumber(-0.1, 0.1),
            NumGen:NextNumber(-0.1, 0.1)
        )
        InnerPart.Parent = VisualModel

        local Weld = Instance.new("WeldConstraint")
        Weld.Part0 = OuterPart
        Weld.Part1 = InnerPart
        Weld.Parent = VisualModel

        droplet:AddTask(task.spawn(function()
            for i = 0.025, 1, 0.025 do
                VisualModel:ScaleTo(i)
                task.wait()
            end
            VisualModel:ScaleTo(1)
        end), nil, "GrowThread")
        
        droplet:AttachModel(VisualModel)

        return {
            VisualModel = VisualModel;
            SpinDirection = if math.random() > 0.5 then 1 else -1;
        }
    end;

    -- Ran when the droplet is within render range of the LocalPlayer's Camera
    OnRenderUpdate = function(droplet: Droplet, rendertimeElapsed: number)
        local SetupData = droplet:GetSetupData()
        local OffsetCFrame = CFrame.new()

        do -- Bobbing
            local AMPLITUDE = 1 -- Studs of vertical movement (+- half of this)
            local FREQUENCY = 0.25 -- Cycles per second
        
            local Y = (AMPLITUDE * 0.5) * -math.cos((rendertimeElapsed*math.pi) * (FREQUENCY))
            OffsetCFrame *= CFrame.new(0, AMPLITUDE + Y, 0)
        end

        do -- Rotating
            local TimeToMakeOneRotation = 4
            local RotationsPerSecond = 1/TimeToMakeOneRotation
            OffsetCFrame *= CFrame.Angles(0, (rendertimeElapsed*math.pi) * RotationsPerSecond * SetupData.SpinDirection , 0)
        end

        return OffsetCFrame
    end;

    OnDropletTimeout = function(droplet: Droplet)
        local VisualModel = droplet:GetSetupData().VisualModel
        droplet:RemoveTask("GrowThread")
        for i = 1, 0.025, -0.025 do
            VisualModel:ScaleTo(i)
            task.wait()
        end
    end;

    OnClientClaim = function(playerWhoClaimed: Player, droplet: Droplet)
        -- droplet:Collect(playerWhoClaimed)
    end;

    --[[
        Called when the droplet hits the player and is considered collected.
        This is ran on the client only. It should be used for collection effects
        and other client side things.
    ]]
    OnClientCollect = function(playerWhoCollected: Player, droplet: Droplet)
        local Value = droplet:GetValue() :: number

        local Part = GenericPart:Clone()
        Part.CFrame = droplet:GetPivot()

        task.delay(2, function()
            Part:Destroy()
        end)

        local CollectionSound = Instance.new("Sound")
        CollectionSound.SoundId = "rbxassetid://402143943"
        CollectionSound.Volume = 0.25
        
        local PitchShift = Instance.new("PitchShiftSoundEffect")
        PitchShift.Octave = 2 - Value/1.5

        PitchShift.Parent = CollectionSound
        CollectionSound.Parent = Part
        Part.Parent = workspace

        CollectionSound:Play()
    end;

    --[[
        Called once the client informs the server that it has collected the droplet.
    ]]
    OnServerCollect = function(playerWhoCollected: Player, value: any, metadata: any)
        local ExpValue: number = value

        local leaderstats = playerWhoCollected:FindFirstChild("leaderstats")
        if not leaderstats then
            leaderstats = Instance.new("Folder")
            leaderstats.Name = "leaderstats"
            leaderstats.Parent = playerWhoCollected
        end

        local expStat = leaderstats:FindFirstChild("Exp")
        if not expStat then
            expStat = Instance.new("NumberValue")
            expStat.Name = "Exp"
            expStat.Parent = leaderstats
        end

        expStat.Value += ExpValue
        -- Add the value to the player's "exp". This is just an example.
    end;
}