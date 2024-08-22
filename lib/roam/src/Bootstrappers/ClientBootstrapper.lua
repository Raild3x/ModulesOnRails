-- Logan Hunt [Raildex]
-- Sep 13, 2023
-- ClientBootstrapper

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BootstrapperModule = script

local function StartGame(script)
    if script.Name == "start" then
        script:Destroy()
        return
    end
    
    local Roam = require(BootstrapperModule.Parent.Parent)
    local SRC_NAME = Roam.DEFAULT_SRC_NAME
    -- Roam.Debug = true -- Enables prints to see when services Init and Start

    -- Require modules under the Client folder that end.
    Roam.requireModules({
        ReplicatedStorage[SRC_NAME].Client;
        ReplicatedStorage[SRC_NAME].Shared;
    }, {
        DeepSearch = true;
        RequirePredicate = function(obj: ModuleScript) -- Only require modules that end in "Service" or "Controller"
            local isService = obj.Name:match("Service$") or obj.Name:match("Controller$")
            return isService
        end;
        IgnoreDescendantsPredicate = function(obj: Instance) -- Ignore the "node_modules_dependencies" folder and anything under "Server"
            return obj.Name == "Server" -- or obj.Name == DPDN
        end;
    })


    -- Wait for the server to start Orion
    if not workspace:GetAttribute("RoamStarted") then
        workspace:GetAttributeChangedSignal("RoamStarted"):Wait()
    end


    -- Start Roam
    Roam.start():andThen(function()
        print("[CLIENT] Roam Started!")
    end):catch(function(err)
        warn(err)
        error("[CLIENT] Roam Failed to Start!")
    end)    
end

return StartGame