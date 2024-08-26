-- Logan Hunt [Raildex]
-- Sep 13, 2023

--------------------------------------------------------------------------------
-- start.Server.lua --
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage.Packages
local Roam = require(Packages.Roam) :: any ---@module Roam

local function StartGame()
	-- Register modules under the Server folder.
	Roam.requireModules(
		{
			ServerScriptService.Orion.Server,
		},
		true,
		function(obj: ModuleScript) -- Only require modules that end in "Service"
			return obj.Name:match("Service$") ~= nil
		end
	)

	-- Start Roam
	return Roam.start()
		:andThen(function()
			print("[SERVER] Roam Started!")
			workspace:SetAttribute("RoamStarted", true) -- Alert the Client that the Server is ready
		end)
		:catch(function(err)
			warn(err)
			error("[SERVER] Roam Failed to Start!")
		end)
end

StartGame()

--------------------------------------------------------------------------------
-- start.Client.lua --
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Roam = require(Packages.Roam) :: any ---@module Roam

local function StartGame()
	-- Require modules under the Client folder that end.
	Roam.requireModules(
		{
			ReplicatedStorage.Orion.Client,
		}
	)

	-- Wait for the server to start Roam
	if not workspace:GetAttribute("RoamStarted") then
		workspace:GetAttributeChangedSignal("RoamStarted"):Wait()
	end

	-- Start Roam
	return Roam.start()
		:andThen(function()
			print("[CLIENT] Roam Started!")
		end)
		:catch(function(err)
			warn(err)
			error("[CLIENT] Roam Failed to Start!")
		end)
end

StartGame()

--------------------------------------------------------------------------------
-- Example Service --
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Roam = require(Packages.Roam) :: any ---@module Roam

local MyService = Roam.createService("MyService") ---@class MyService

function MyService:RoamStart()
	-- Game Logic
end

function MyService:RoamInit()
	-- Initialize the Service
end

return MyService
