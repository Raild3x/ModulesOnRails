-- Logan Hunt [Raildex]
-- Sep 15, 2023
--[=[
    @class NetWire

    NetWire is a networking library that enables functionality similar to Sleitnick's [Comm](https://sleitnick.github.io/RbxUtil/api/Comm/) library,
    except it doesn't require the usage of intermediate instances.

    Basic usage:
    ```lua
    -- SERVER
    local NetWire = require(Packages.NetWire)
    local myWire = NetWire("MyNetWire")

    myWire.MyEvent = NetWire.createEvent()

    myWire.MyEvent:Connect(function(plr: Player, msg: string)
        print(plr, "said:", msg)
    end)
    ```
    ```lua
    -- CLIENT
    local NetWire = require(Packages.NetWire)
    local myWire = NetWire("MyNetWire")

    myWire.MyEvent:FireAll("Hello, world!")
    ```
]=]

local RunService = game:GetService("RunService")

local NetWire

if RunService:IsServer() then
    NetWire = require(script.ServerWire)
else
    NetWire = require(script.ClientWire)
end

return NetWire