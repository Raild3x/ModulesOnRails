-- Logan Hunt [Raildex]
-- Sep 13, 2023
-- ServerBootstrapper

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BootstrapperModule = script

local function ShutdownServer(err)
	local shutdownMsg = `This server has shutdown due to ROAM failing to boot, please contact a dev:\n{err}`

	if RunService:IsStudio() then
		warn(shutdownMsg)
		return
	end

	Players.PlayerAdded:Connect(function(player)
		player:Kick(shutdownMsg)
	end)
	for _, plr in ipairs(Players:GetPlayers()) do
		plr:Kick(shutdownMsg)
	end
end

local function StartGame(script)
	if script.Name == "start" then
		script:Destroy()
		local Promise = require(BootstrapperModule.Parent.Parent.Parent.Promise)
		return Promise.reject()
	end

	local Roam = require(BootstrapperModule.Parent.Parent)
	local SRC_NAME = Roam.DEFAULT_SRC_NAME
	-- Roam.Debug = true -- Enables prints to see when services Init and Start

	-- Register modules under the Server folder.
	Roam.requireModules({
		ServerScriptService[SRC_NAME].Server,
		ReplicatedStorage[SRC_NAME].Shared,
	}, {
		DeepSearch = true,
		RequirePredicate = function(obj: ModuleScript) -- Only require modules that end in "Service"
			local isService = obj.Name:match("Service$")
			return isService
		end,
		IgnoreDescendantsPredicate = function(obj: Instance) -- Ignore the "node_modules_dependencies" folder and anything under "Client"
			return obj.Name == "Client" -- or obj.Name == DPDN
		end,
	})

	-- Start Roam
	return Roam.start()
		:andThen(function()
			print("[SERVER] Roam Started!")
			workspace:SetAttribute("RoamStarted", true) -- Alert the Client that the Server is ready
		end)
		:catch(function(err)
			ShutdownServer(err)
			task.spawn(error, "🛑  [SERVER] Roam Failed to Start!  🛑\n\t" .. tostring(err))
		end)
end

return StartGame