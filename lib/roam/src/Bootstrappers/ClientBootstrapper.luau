-- Logan Hunt [Raildex]
-- Sep 13, 2023
-- ClientBootstrapper

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BootstrapperModule = script

local function StartGame(script, requireConfig: {
    AllowYieldingRequires: boolean?; -- Default: false
    StopOnFailedRequire: boolean?; -- Default: true
}?)
    local Promise = require(BootstrapperModule.Parent.Parent.Parent.Promise)
    if script.Name == "start" then -- We may want to remove this check later. It doesnt allow nice custom structures since its tailored to my opinion.
        script:Destroy()
        return Promise.reject()
    end
    
    local Roam = require(BootstrapperModule.Parent.Parent)
    local SRC_NAME = Roam.DEFAULT_SRC_NAME
    -- Roam.Debug = true -- Enables prints to see when services Init and Start

    -- Require modules under the Client folder that end in "Service" or "Controller"
    local result = Roam.requireModules({
        ReplicatedStorage[SRC_NAME].Client;
        ReplicatedStorage[SRC_NAME].Shared;
    }, {
        DeepSearch = true;
        StopOnFailedRequire = if requireConfig and requireConfig.StopOnFailedRequire ~= nil then requireConfig.StopOnFailedRequire else true;
        AllowYieldingRequires = if requireConfig and requireConfig.AllowYieldingRequires ~= nil then requireConfig.AllowYieldingRequires else false;
        RequirePredicate = function(obj: ModuleScript) -- Only require modules that end in "Service" or "Controller"
            local isService = obj.Name:match("Service$") or obj.Name:match("Controller$")
            return isService
        end;
        IgnoreDescendantsPredicate = function(obj: Instance) -- Ignore anything under "Server"
            return obj.Name == "Server"
        end;
    })

    if not result.Success then
        return Promise.reject("🛑  [CLIENT] Failed module requires during client bootstrap  🛑")
    end

    -- Wait for the server to start
    if not workspace:GetAttribute("RoamStarted") then
        workspace:GetAttributeChangedSignal("RoamStarted"):Wait()
    end

    -- Start Roam
    return Roam.start():andThen(function()
        print("[CLIENT] Roam Started!")
        return true
    end)
    :catch(function(err)
        local sanitizedError = tostring(err):gsub("%[(.-):", "")
        task.spawn(error, "🛑  [CLIENT] Roam Failed to Start!  🛑" .. sanitizedError)
        return false
    end)
end

return StartGame