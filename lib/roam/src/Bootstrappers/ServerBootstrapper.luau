-- Logan Hunt [Raildex]
-- Sep 13, 2023
-- ServerBootstrapper

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BootstrapperModule = script
local Roam = require(BootstrapperModule.Parent.Parent)
local Promise = require(BootstrapperModule.Parent.Parent.Parent.Promise)

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

local function checkConfig(config: any, field: string, default: any?)
	if config and config[field] ~= nil then
		return config[field]
	end
	return default
end

local function StartGame(
	script,
	config: ({
		AllowYieldingRequires: boolean?, -- Default: false
		StopOnFailedRequire: boolean?, -- Default: true
	} & Roam.StartConfig)?
)
	if script.Name == "start" then -- We may want to remove this check later. It doesn't allow nice custom structures since its tailored to my opinion.
		script:Destroy()
		return Promise.resolve(false)
	end

	-- Register modules under the Server and Shared folders.
	local SRC_NAME = Roam.DEFAULT_SRC_NAME
	local result = Roam.requireModules({
		ServerScriptService[SRC_NAME].Server,
		ReplicatedStorage[SRC_NAME].Shared,
	}, {
		DeepSearch = true,
		StopOnFailedRequire = checkConfig(config, "StopOnFailedRequire", true),
		AllowYieldingRequires = checkConfig(config, "AllowYieldingRequires", false),
		RequirePredicate = function(obj: ModuleScript) -- Only require modules that end in "Service"
			local isService = obj.Name:match("Service$")
			return isService
		end,
		IgnoreDescendantsPredicate = function(obj: Instance) -- Ignore anything under "Client"
			return obj.Name == "Client"
		end,
	})

	if result.Success == false then
		task.spawn(error, "🛑  [SERVER] Failed module requires during server bootstrap  🛑")
		ShutdownServer("Failed module requires during server bootstrap")
		return Promise.resolve(false)
	end

	-- Start Roam
	return Roam.start(config)
		:andThen(function()
			print("[SERVER] Roam Started!")
			workspace:SetAttribute("RoamStarted", true) -- Alert the Client that the Server is ready
			return true
		end)
		:catch(function(err)
			local sanitizedError = tostring(err):gsub("%[(.-):", "") -- Replaces failure warning so I can add a fancier looking one
			task.spawn(error, "🛑  [SERVER] Roam Failed to Start!  🛑" .. sanitizedError)
			ShutdownServer(err)
			return false
		end)
end

return StartGame
