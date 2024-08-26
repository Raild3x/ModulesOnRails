local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(Target)
    local t = task.spawn(function()
        local TestEZ = require(ReplicatedStorage.TestEZ)
        TestEZ.TestBootstrap:run({
            game.ReplicatedStorage.src
        })
    end)
    
    return function()
        task.cancel(t)
    end
end
