-- Authors: Logan Hunt (Raildex)
-- May 03, 2024

--// Services //--
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")

--// Imports //--
local GroupCache = (setmetatable({}, {__mode = "k"}) :: any) :: {[Player]: {{
    Name: string,
    Id: number,
    Rank: number,
    Role: string,
    IsPrimary: boolean,
}}}

local function RefreshGroupCache(plr: Player)
    task.spawn(function()
        local groups = GroupService:GetGroupsAsync(plr.UserId)
        GroupCache[plr] = groups
        -- if RunService:IsStudio() then
        --     print("[Cmdr] Cached Groups for ", plr.Name, ":", groups)
        -- end
    end)
end

Players.PlayerAdded:Connect(RefreshGroupCache)
for _, plr in ipairs(Players:GetPlayers()) do
    RefreshGroupCache(plr)
end


--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local Util = {}

function Util.getPlayerPermissions(cmdrWrapper, plr: Player, rawPlayerPerms: {string}): {string}
    local playerPerms = table.clone(rawPlayerPerms)

    for _, permissionGroup: string in playerPerms do
		for _, inheritedPerm in cmdrWrapper:GetPermissionInheritance(permissionGroup) do
			if not table.find(playerPerms, inheritedPerm) then
				table.insert(playerPerms, inheritedPerm)
			end
		end
	end

    for _, groupData in GroupCache[plr] or {} do
        for _, groupPerm in Util.getGroupRankPermissions(cmdrWrapper, groupData.Id, groupData.Rank) do
            if not table.find(playerPerms, groupPerm) then
                table.insert(playerPerms, groupPerm)
            end
        end
    end

    return playerPerms
end

function Util.getGroupRankPermissions(cmdrWrapper, groupId: number, rank: number): {string}
    local groupData = cmdrWrapper:_getRawGroupPerms(groupId)
    local rankPerms = {}

	-- This is terribly unoptimized, feel free to optimize it
	for _, groupPermData in groupData do
		if groupPermData.Ranks.Min <= rank and rank <= groupPermData.Ranks.Max then
			for _, permissionGroup: string in groupPermData.Permissions do
				if not table.find(rankPerms, permissionGroup) then
					table.insert(rankPerms, permissionGroup)
				end
				for _, inheritedPerm in cmdrWrapper:GetPermissionInheritance(permissionGroup) do
					if not table.find(rankPerms, inheritedPerm) then
						table.insert(rankPerms, inheritedPerm)
					end
				end
			end
		end
	end

	return rankPerms
end

return Util