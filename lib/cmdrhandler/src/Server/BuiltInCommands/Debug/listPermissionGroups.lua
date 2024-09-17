--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Imports //--
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
        local CmdrService = require(ReplicatedStorage:FindFirstChild("CmdrHandler", true) :: any).Server
        player = player or context.Executor
        --context:SendEvent(context.Executor, "PermissionGroupList", CmdrService:GetPermissions(player))
        return "Permission Groups: " .. table.concat(CmdrService:GetPermissions(player), ", ")
    end,
}

return Command