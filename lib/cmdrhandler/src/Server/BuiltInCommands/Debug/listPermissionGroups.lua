--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Imports //--
local Import = require(ReplicatedStorage.Orion.Import)
local CmdrTypes ---@module CmdrTypes

local Command = {
    Name = "listPermissionGroups";
    Description = "Prints the permission groups of a player";
    Group = "Help";
    Args = {
        {
            Type = "player";
            Name = "Player";
            Description = "Lists the permission groups";
            Default = Players.LocalPlayer;
            Optional = true;
        },
    };

    -- ClientRun = function(context)
    --     context.Cmdr:HandleEvent("PermissionGroupList", function(list)
    --         context:Reply("Permission Groups: " .. table.concat(list, ", "))
    --         print("Permission Groups: " .. table.concat(list, ", "))
    --     end)
    -- end,

    ServerRun = function(context, player: Player)
        local CmdrService = Import("CmdrService")
        player = player or context.Executor
        --context:SendEvent(context.Executor, "PermissionGroupList", CmdrService:GetPermissions(player))
        return "Permission Groups: " .. table.concat(CmdrService:GetPermissions(player), ", ")
    end,
} :: CmdrTypes.CommandModuleData<any>

return Command