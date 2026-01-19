-- Logan Hunt [Raildex]
-- Sep 13, 2023
-- ClientBootstrapper

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BootstrapperModule = script
local Roam = require(BootstrapperModule.Parent.Parent)
local Promise = require(BootstrapperModule.Parent.Parent.Parent.Promise)

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
	if script.Name == "start" then -- We may want to remove this check later. It doesnt allow nice custom structures since its tailored to my opinion.
		script:Destroy()
		return Promise.resolve(false)
	end

	-- Require modules under the Client and Shared folder that end in "Service" or "Controller"
	local SRC_NAME = Roam.DEFAULT_SRC_NAME
	local result = Roam.requireModules({
		ReplicatedStorage[SRC_NAME].Client,
		ReplicatedStorage[SRC_NAME].Shared,
	}, {
		DeepSearch = true,
		StopOnFailedRequire = checkConfig(config, "StopOnFailedRequire", true),
		AllowYieldingRequires = checkConfig(config, "AllowYieldingRequires", false),
		RequirePredicate = function(obj: ModuleScript) -- Only require modules that end in "Service" or "Controller"
			local isService = obj.Name:match("Service$") or obj.Name:match("Controller$")
			return isService
		end,
		IgnoreDescendantsPredicate = function(obj: Instance) -- Ignore anything under "Server"
			return obj.Name == "Server"
		end,
	})

	if not result.Success then
		task.spawn(error, "🛑  [CLIENT] Failed module requires during client bootstrap  🛑")
		return Promise.resolve(false)
	end

	-- Wait for the server to start
	if not workspace:GetAttribute("RoamStarted") then
		workspace:GetAttributeChangedSignal("RoamStarted"):Wait()
	end

	-- Start Roam
	return Roam.start(config)
		:andThen(function()
			print("[CLIENT] Roam Started!")
			return true
		end)
		:catch(function(err)
			local sanitizedError = tostring(err):gsub("%[(.-):", "") -- Replaces failure warning so I can add a fancier looking one
			task.spawn(error, "🛑  [CLIENT] Roam Failed to Start!  🛑" .. sanitizedError)
			return false
		end)
end

return StartGame
