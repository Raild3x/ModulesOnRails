-- Authors: Logan Hunt [Raildex]
-- September 09, 2024
--[=[
    @class CmdrHandler

    Package entrypoint file. Use this to initialize the client and server files.

    ```lua
    -- Server
    local CmdrHandler = require(script.CmdrHandler)
    local CmdrServer = CmdrHandler.Server

    CmdrServer:Init()
    ```
    ```lua
    -- Client
    local CmdrHandler = require(script.CmdrHandler)
    local CmdrClient = CmdrHandler.Client

    CmdrClient:Init()
]=]

local RunService = game:GetService("RunService")

local Server : typeof(require(script.Server)) = nil
local Client : typeof(require(script.Client)) = nil

if RunService:IsServer() then
    Server = require(script.Server)
else
    Client = require(script.Client)
end

--[=[
    @within CmdrHandler
    @prop Server CmdrServer
]=]

--[=[
    @within CmdrHandler
    @prop Client CmdrClient
]=]

local CmdrHandler = {
    Server = Server,
    Client = Client
}

return CmdrHandler
