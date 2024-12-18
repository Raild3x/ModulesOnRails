-- Authors: Logan Hunt (Raildex)
-- August 22, 2024
--[=[
    @class PlayerDataManager

    Central access file for PlayerDataManager.

    Example Usage:

    ---
    SERVER
    ---
    ```lua
    -- Require Packages
    local PlayerDataManager = require(Packages.PlayerDataManager).Server
    local PlayerProfileManager = require(Packages.PlayerProfileManager)

    -- Register various managers
    PlayerDataManager:RegisterManager("Settings", function(player, profile)
        return {
            Data = profile.Data.Settings
            ReplicationTargets = player
        }
    end)
    
    -- Create the PlayerProfileManager
    local ppm = PlayerProfileManager.new(someProfileConfig)

    -- Start the PlayerDataManager. Begins listening for player connections and creation of managers
    PlayerDataManager:Start(ppm)
    ```
    ```lua
    -- Some example usage for the Settings manager
    PlayerDataManager:ForEachPlayer(function(player: Player)
        local settings = PlayerDataManager:GetManager(player, "Settings")

        for i = 1, 10 do
            settings:Increment("Volume", math.random())
        end
    end)
    ```

    CLIENT
    ---
    ```lua
    --// Client //--
    local PlayerDataManager = require(Packages.PlayerDataManager).Client

    PlayerDataManager:Start()

    pdm:PromiseManager("Settings"):andThen(function(settings: TableManager)
        settings:Observe("Volume", function(currentVolume: number)
            print("Volume is:", newVolume)
        end)
    end)
    ```
]=]

--// Services //--
local RunService = game:GetService("RunService")

--// Imports //--
local ClientModule = script.ClientPlayerDataManager
local ServerModule = script.ServerPlayerDataManager
local Client : typeof(require(script.ClientPlayerDataManager)) = nil
local Server : typeof(require(script.ServerPlayerDataManager)) = nil

export type ServerPlayerDataManager = typeof(require(script.ServerPlayerDataManager))
export type ClientPlayerDataManager = typeof(require(script.ClientPlayerDataManager))
export type PlayerDataManager = ServerPlayerDataManager | ClientPlayerDataManager

local CurrentContextModule
if RunService:IsClient() then
    CurrentContextModule = require(ClientModule)
    Client = CurrentContextModule
else
    CurrentContextModule = require(ServerModule)
    Server = CurrentContextModule
end

local DEFAULT_MANAGER_NAME = "DefaultManager"
CurrentContextModule.DEFAULT_MANAGER_NAME = DEFAULT_MANAGER_NAME

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

--[=[
    @within PlayerDataManager
    @type ServerPlayerDataManager ServerPlayerDataManager
]=]

--[=[
    @within PlayerDataManager
    @type ClientPlayerDataManager ClientPlayerDataManager
]=]

--[=[
    @server
    @within PlayerDataManager
    @prop Server ServerPlayerDataManager
    The ServerPlayerDataManager class.  
]=]

--[=[
    @client
    @within PlayerDataManager
    @prop Client ClientPlayerDataManager
    The ClientPlayerDataManager class.
]=]

local Manager = {
    Client = Client;
    Server = Server;
}

setmetatable(Manager, {
    __index = CurrentContextModule;
})

return Manager