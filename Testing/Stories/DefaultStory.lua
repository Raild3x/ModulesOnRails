return function(script)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    return function(Target)
        local t = task.spawn(function()
            local TestEZ = require(ReplicatedStorage.TestEZ)
            local ModuleNameToTest = string.gsub(script.Name, ".story", ""):lower()
            local ModuleToTest = ReplicatedStorage.src:FindFirstChild(ModuleNameToTest):FindFirstChild("src")
    
            TestEZ.TestBootstrap:run({
                ModuleToTest
            })
        end)
        
        return function()
            task.cancel(t)
        end
    end
    
end
