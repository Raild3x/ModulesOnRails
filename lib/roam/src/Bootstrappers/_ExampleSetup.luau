-- Logan Hunt [Raildex]
-- Sep 13, 2023

--------------------------------------------------------------------------------
-- start.Server.lua --
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage.Packages
local Roam = require(Packages.Roam)

local function StartGame()
	for _, module in ServerScriptService.Server:QueryDescendants("ModuleScript") do
		require(module)
	end

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
local Roam = require(Packages.Roam)

local function StartGame()
	for _, module in ReplicatedStorage.Client:QueryDescendants("ModuleScript") do
		require(module)
	end

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

local MyService = {}

function MyService:RoamStart()
	-- Game Logic
end

function MyService:RoamInit()
	-- Initialize the Service
end

local Roam = require(Packages.Roam)
Roam.registerService(MyService, "MyService")

return MyService
