-- Authors: Logan Hunt (Raildex)
-- March 12, 2024
--[=[
    @class TableManager.story
    @ignore

    This is just a class I use to test the TableManager class.
]=]

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Imports //--
local Import = require(ReplicatedStorage.Orion.Import)

local Class = Import("TableManager")
local Janitor = Import("Janitor")

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