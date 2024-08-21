-- Authors: Logan Hunt (Raildex)
-- March 12, 2024
--[=[
    @class TableManager.story
    @ignore

    This is just a class I use to test the TableManager class.
]=]


--// Imports //--
local Class = require(script.Parent)

return function(target: ScreenGui)
    local Object = Class {
        Currency = {
            Coins = 0,
            Gems = 0,
        },
        
        Inventory = {
            Potions = {"Health", "Mana"},
            Equipment = {},
        },
    }

    local thread = task.defer(function()

        Object:ListenToValueChange("Currency.Coins", function(...)
            print("Coins changed:", ...)
        end)

        while true do
            task.wait(1)
            Object:Increment("Currency.Coins", 5)
        end

    end)

    return function()
        task.cancel(thread)
        Object:Destroy()
        print("Object destroyed")
    end
end