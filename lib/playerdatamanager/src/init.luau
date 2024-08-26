-- Authors: Logan Hunt (Raildex)
-- August 22, 2024
--[=[
    @class PlayerDataManager

    Central access file for PlayerDataManager

    ```lua
    --// Server
    local PlayerDataManager = require(Packages.PlayerDataManager)
    local PlayerProfileManager = -- construct a PlayerProfileManager

    local pdm = PlayerDataManager.Server.new(PlayerProfileManager)

    pdm:RegisterManager("Settings")

    pdm:Start()
    ```
    ```lua
    --// Client
    local PlayerDataManager = require(Packages.PlayerDataManager)

    local pdm = PlayerDataManager.Client.new({
        ProfileSchema = require(Shared.ProfileSchema)
    })

    pdm:RegisterManager("Settings")

    pdm:PromiseManager("Settings"):andThen(function(tm: TableManager)
        -- handle
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