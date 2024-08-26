-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--// Types //--
type table = {[any]: any}

--[=[
    @within BaseTableReplicator
    @type Tags {[string]: any}
    The valid tag format that can be given to a TableReplicator.
    This table will become locked once given to a TableReplicator.
    Do not attempt to modify it after the fact.
    ```lua
    local tags = table.freeze {
        OwnerId = Player.UserId;
        ToolType = "Sword";
    }
    ```
]=]
export type Tags = {[string]: any}


--[=[
    @within ServerTableReplicator
    @type ClassToken {Name: string}
    A unique symbol that identifies the STR Class.
    This is used to identify the STR Class when it is replicated to the client.
    Use `.newClassToken` to generate an object of this type. Do NOT manually create
    the table.
]=]
export type ClassToken = {Name: string} | string

--[[
    @ignore
    @type TRPacket = {any}
    The packet format that is sent across the network boundary.
    Breakdown:
    ```lua
    {
        [1] = (number); -- id
        [2] = (string); -- class token name
        [3] = (Tags); -- tags
        [4] = (table); -- data
    }
    ```
]]
export type TRPacket = {any}
export type ParsedTRPacket = {
    ParentId: string;
    ClassName: string;
    Tags: Tags?;
    Data: table;
}

--------------------------------------------------------------------------------
    --// Util Declaration //--
--------------------------------------------------------------------------------

local Util = {}

--------------------------------------------------------------------------------
    --// Functions //--
--------------------------------------------------------------------------------

--[[
    Takes a packet and returns a table with the packet's data in an easier to read format.
    Used by the client to read the recieved packets.
]]
function Util.ParsePacket(packet: TRPacket): ParsedTRPacket
    return {
        ParentId = packet[1];
        ClassName = packet[2];
        Tags = packet[3];
        Data = packet[4];
    }
end

--------------------------------------------------------------------------------
    --// Final Return //--
--------------------------------------------------------------------------------

return Util