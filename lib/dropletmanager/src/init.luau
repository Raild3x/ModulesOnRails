-- Authors: Logan Hunt (Raildex)
-- January 19, 2024
--[=[
    @class DropletManager

    The DropletManager is the main entry point for the DropletSystem API.
    The DropletSystem is a system for creating, managing, and collecting droplets in your game.
    It aims to handle all the annoying parts of droplets for you, such as physics, collection, and
    replication. Once you create a new droplet type, spawning them is extremely easy.

    To get started look at DropletServerManager's methods `:RegisterResourceType` and `:Spawn`.
    For more info on how to create a new droplet type, you can take a look at the included
    'ExampleResourceTypeData' file, which will show you an example of a working ResourceType
    data table.
    
    In order for the DropletSystem to work, you must have a Server and Client DropletManager,
    accessing them through this file on both server and client should initialize them so that
    replication can be established.

    This file in particular exposes access to the Server and Client DropletManagers,
    Enums, and several common public types.

    ![Droplet Example Gif](https://media.discordapp.net/attachments/450332579351232522/1263222333573697616/RobloxStudioBeta_Pn6C5N5srT.gif?ex=66c79779&is=66c645f9&hm=7f658c7b0d92f1b2855c5323a303962dffc49295fc4678a7cb1bd86caaecf000&=&width=1080&height=805)
    
    ----
    EXAMPLE USAGE:
    ----
    
    [ExampleData.lua]
    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local DropletManager = require(ReplicatedStorage.DropletManager)

    type Droplet = DropletManager.Droplet

    return {
        Defaults = {
            LifeTime = NumberRange.new(20, 30);
        };

        SetupDroplet = function(droplet: Droplet): table?
            local Model = Instance.new("Model")
            Model.Name = "ExampleDroplet"

            local Part = Instance.new("Part")
            Part.Size = Vector3.one
            -- All attached parts should typically have these properties set to the following values
            Part.Anchored = false
            Part.CanCollide = false
            Part.CanTouch = false
            Part.CanQuery = false
            Part.Massless = true

            Part.Parent = Model
            Model.PrimaryPart = Part

            -- Weld our model to the droplet
            droplet:Attach(Model)

            -- Create metadata to be used in in the render functions
            local SetupData = {
                Direction = if math.random() > 0.5 then 1 else -1 end;
            }
            return SetupData
        end;

        -- Ran when the droplet is within render range/view of the LocalPlayer's Camera
        OnRenderUpdate = function(droplet: Droplet, rendertimeElapsed: number): CFrame?
            local SetupData = droplet:GetSetupData()
            local OffsetCFrame = CFrame.new()

            do -- Rotating
                local TimeToMakeOneRotation = 4
                local RotationsPerSecond = 1/TimeToMakeOneRotation
                OffsetCFrame *= CFrame.Angles(0, tPi * RotationsPerSecond * SetupData.SpinDirection, 0)
            end

            return OffsetCFrame
        end;

        OnClientCollect = function(playerWhoCollected: Player, droplet: Droplet)
            print(playerWhoCollected, "collected droplet worth", droplet:GetValue())
        end;

        OnServerCollect = function(playerWhoCollected: Player, value: any)
            print(playerWhoCollected, "collected droplet worth", value)
        end;
    }
    ```
    ----
    Some Server Script:
    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local DropletManager = require(ReplicatedStorage.DropletManager)
    local ExampleData = require(ReplicatedStorage.ExampleData)

    DropletManager.Server:RegisterResourceType("Example", ExampleData) -- Register the Example ResourceType on the Server

    while true do
        DropletManager.Server:Spawn({
            ResourceType = "Example";
            Value = NumberRange.new(1, 5);
            Count = NumberRange.new(5, 10);
            SpawnPosition = Vector3.new(
                math.random(0, 10),
                5,
                math.random(0, 10)
            );
        })

        task.wait(1)
    end
    ```
    ----
    Some Client Script:
    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local DropletManager = require(ReplicatedStorage.DropletManager)
    local ExampleData = require(ReplicatedStorage.ExampleData)

    DropletManager.Client:RegisterResourceType("Example", ExampleData) -- Register the Example ResourceType on the Client
    ```
]=]

local RunService = game:GetService("RunService")

local DropletUtil = require(script.DropletUtil)
local Droplet = require(script.Client.Droplet)

--[=[
    @within DropletManager
    @type Droplet Droplet
]=]
export type Droplet = Droplet.Droplet

--[=[
    @within DropletManager
    @type ResourceTypeData ResourceTypeData
]=]
export type ResourceTypeData = DropletUtil.ResourceTypeData

--[=[
    @within DropletManager
    @type ResourceSpawnData ResourceSpawnData
]=]
export type ResourceSpawnData = DropletUtil.ResourceSpawnData

local DropletManager = {}

--[=[
    @within DropletManager
    @prop Server DropletServerManager
    @server
    Accessing this will automatically create a new DropletServerManager if one does not exist.
]=]
DropletManager.Server = nil :: typeof(require(script.Server.DropletServerManager))

--[=[
    @within DropletManager
    @prop Client DropletClientManager
    @client
    Accessing this will automatically create a new DropletClientManager if one does not exist.
]=]
DropletManager.Client = nil :: typeof(require(script.Client.DropletClientManager))

--[=[
    @within DropletManager
    @prop Util DropletUtil
]=]
DropletManager.Util = DropletUtil

-- Handles lazy initialization of the DropletManager
setmetatable(DropletManager, {
    __index = function(t, k)
        if k == "Server" then
            assert(RunService:IsServer(), "Attempted to access DropletManager.Server on client")
            t[k] = require(script.Server.DropletServerManager).new()
        elseif k == "Client" then
            assert(RunService:IsClient(), "Attempted to access DropletManager.Client on server")
            t[k] = require(script.Client.DropletClientManager).new()
        end
        return t[k]
    end
})

return DropletManager