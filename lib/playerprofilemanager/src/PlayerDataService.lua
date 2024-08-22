-- Logan Hunt (Raildex)
-- Aug 20, 2024
--[=[
    @class PlayerDataService

    ```lua
    local manager: TableManager = PlayerDataService:GetManager(Players.Raildex, "Settings")
    manager:Set("Volume", 0.5)
    ```
]=]

--// Service //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Imports //--
local Packages = ReplicatedStorage.Packages
local Knit = require(Packages.knit)
local Signal = require(Packages.signal)
local Promise = require(Packages.Promise)
local RailUtil = require(Packages.RailUtil)
local Janitor = require(Packages.Janitor)
--local ProfileLoader = require(Packages.ProfileLoader)
local TableManager = require(Packages.TableManager)
local TableReplicator = require(Packages.TableReplicator)
local ProfileSchema = require(script.Parent.ProfileSchema)

--local PlayerProfileManager = require(script.Parent.PlayerProfileManager)

--// Types //--
type Promise = any -- temporary fix
type Janitor = any
type TableManager = any

--// Constants //--
local DEFAULT_TIMEOUT = 60
local DEFAULT_MANAGER_NAME = ProfileSchema.DEFAULT_REPLICATED_DATA_KEY

--------------------------------------------------------------------------------
--// Service Def //--
--------------------------------------------------------------------------------

local PlayerDataService = Knit.CreateService {
    Name = "PlayerDataService";
    Client = {};
}
-- Server Signals
PlayerDataService.PlayerDataReady = Signal.new()
-- FLAGS
PlayerDataService._DEBUG = true

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[[
    Promise that resolves when the player's data is ready to be used.
]]
function PlayerDataService:OnReady(player: Player): Promise
    if self:IsReady(player) then return Promise.resolve(self._PlayerData[player]) end
    return Promise.fromEvent(self.PlayerDataReady, function(readiedPlayer: Player)
        return readiedPlayer == player
    end)
    :andThen(function()
        return self._PlayerData[player]
    end)
    :timeout(DEFAULT_TIMEOUT, `PlayerData failed to become ready in time [{DEFAULT_TIMEOUT} Seconds].`)
end

--[[
    Checks whether or not a given player's data is ready
]]
function PlayerDataService:IsReady(player: Player): boolean
    return self._PlayerData and self._PlayerData[player] ~= nil
end

--[[
    Fetches one of the given Player's DataManagers. If one is not specified then it will assume the default one. 
]]
function PlayerDataService:GetManager(player: Player, managerName: string?): TableManager?
    if not self:IsReady(player) then
        warn("Player data is not ready")
        return nil
    end
    managerName = managerName or DEFAULT_MANAGER_NAME
    return self._PlayerData[player][managerName]:GetTableManager()
end
PlayerDataService.Get = PlayerDataService.GetManager
PlayerDataService.GetTableManager = PlayerDataService.GetManager

--[[
    Runs a function for all existing loaded player data and all future player data.
]]
function PlayerDataService:ForEach(fn: (player: Player, data: any) -> ())
    for player, data in pairs(self._PlayerData) do
        task.spawn(fn, player, data)
    end
    return self.PlayerDataReady:Connect(function(player: Player)
        fn(player, self._PlayerData[player])
    end)
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

-- Cache and fetch the class token for a given name
local ReplicatorClassTokens = {}
function PlayerDataService:_UpsertToken(name: string)
    if not ReplicatorClassTokens[name] then
        ReplicatorClassTokens[name] = TableReplicator.newClassToken(name)
    end
    return ReplicatorClassTokens[name]
end


function PlayerDataService:_SetupPlayerDataManagers(player: Player, profile)
    print("Setting up player data managers for", player)
    local jani = Janitor.new()
    local pData = profile.Data

    local DataContainer = {}

    local function InitializeManager(name, tbl)
        local classToken = self:_UpsertToken(name)
        local tm = jani:Add(TableManager.new(tbl))
        DataContainer[name] = jani:Add(TableReplicator.new({
            ClassToken = classToken;
            TableManager = tm;
            ReplicationTargets = player;
            Tags = {UserId = player.UserId};
        }));
        return DataContainer[name]
    end

    InitializeManager(DEFAULT_MANAGER_NAME, pData[DEFAULT_MANAGER_NAME])
    -------------------------------------------
    -- Setup your various data managers here --
    -------------------------------------------
    
    InitializeManager("Settings", pData.Settings)
    InitializeManager("Inventory", pData.Inventory)
    InitializeManager("PlayerStats", pData.PlayerStats)
    InitializeManager("Currency", pData.Currency)

    return DataContainer, jani
end


function PlayerDataService:KnitStart()
    RailUtil.Player.forEachPlayer(function(plr: Player, jani: Janitor)
        local profile = RailUtil.Table.Copy({Data = ProfileSchema.Template}, true)


        local dataContainer, cleanup = self:_SetupPlayerDataManagers(plr, profile)
        self._PlayerData[plr] = dataContainer

        jani:Add(cleanup)
        jani:Add(function()
            self._PlayerData[plr] = nil
        end)

        self.PlayerDataReady:Fire(plr)

        if self._DEBUG then
            print("Player Data Ready", plr)
        end
    end)
    print("PDS Started")
end


function PlayerDataService:KnitInit()
    self._PlayerData = {}
end

return PlayerDataService