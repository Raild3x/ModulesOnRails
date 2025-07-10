--[=[
    @class NetWireExamples
    @ignore
    
    This file contains comprehensive examples of how to use the NetWire library.
    It serves as both documentation and a reference for best practices.

    ## Basic Usage

    ### Server-side Example
    ```lua
    local NetWire = require(ReplicatedStorage.Packages.NetWire)
    
    -- Create a server wire
    local myWire = NetWire.Server("MyWire")
    
    -- Create events
    myWire.PlayerJoined = NetWire.createEvent()
    myWire.PlayerLeft = NetWire.createEvent()
    
    -- Create properties
    myWire.ServerTime = NetWire.createProperty(0)
    
    -- Create methods
    function myWire:GetPlayerData(player: Player, dataType: string)
        -- Return player data
        return { name = player.Name, dataType = dataType }
    end
    
    -- Listen to events
    myWire.PlayerJoined:Connect(function(player: Player, message: string)
        print(player.Name .. " joined with message: " .. message)
    end)
    
    -- Fire events
    myWire.PlayerJoined:FireAll("Welcome to the server!")
    
    -- Update properties
    myWire.ServerTime:Set(workspace.DistributedGameTime)
    ```

    ### Client-side Example
    ```lua
    local NetWire = require(ReplicatedStorage.Packages.NetWire)
    
    -- Create a client wire (same namespace as server)
    local myWire = NetWire.Client("MyWire")
    
    -- Wait for wire to be ready
    NetWire.onReady(myWire):andThen(function()
        -- Listen to events
        myWire.PlayerJoined:Connect(function(message: string)
            print("Server says: " .. message)
        end)
        
        -- Fire events to server
        myWire.PlayerJoined:Fire("Hello from client!")
        
        -- Call server methods
        myWire:GetPlayerData("inventory"):andThen(function(data)
            print("Player data:", data)
        end)
        
        -- Access properties
        if myWire.ServerTime:IsReady() then
            print("Server time:", myWire.ServerTime:Get())
        end
    end)
    ```

    ## Advanced Usage

    ### Using Middleware
    ```lua
    -- Server-side middleware example
    local function validatePlayerMiddleware(player: Player, args: {any}): (boolean, ...any)
        if player.UserId < 0 then
            return false -- Block guest players
        end
        return true, unpack(args)
    end
    
    local function loggingMiddleware(player: Player, args: {any}): (boolean, ...any)
        print("Player " .. player.Name .. " called remote with args:", args)
        return true, unpack(args)
    end
    
    -- Create event with middleware
    myWire.SecureEvent = NetWire.createEvent(
        {validatePlayerMiddleware, loggingMiddleware}, -- inbound
        {} -- outbound
    )
    ```

    ### Service Integration (with Roam)
    ```lua
    -- Server-side service
    local ExampleService = Roam.createService { 
        Name = "ExampleService" 
    }
    
    -- Define client interface
    ExampleService.Client = {
        PlayerDataChanged = NetWire.createEvent(),
        GetPlayerStats = function(self, player: Player)
            return { level = 1, coins = 100 }
        end,
        ServerStatus = NetWire.createProperty("Online")
    }
    
    function ExampleService:RoamInit()
        -- Setup networking automatically
        NetWire.setupServiceNetworking(self)
    end
    
    function ExampleService:RoamStart()
        -- Now you can use the Client interface
        self.Client.PlayerDataChanged:FireAll("Data updated!")
        self.Client.ServerStatus:Set("Running")
    end
    ```

    ### Error Handling
    ```lua
    -- Client-side error handling
    local myWire = NetWire.Client("MyWire")
    
    -- Handle wire not ready
    if not NetWire.isReady(myWire) then
        NetWire.onReady(myWire):andThen(function()
            -- Wire is now ready
        end):catch(function(err)
            warn("Failed to connect to server:", err)
        end)
    end
    
    -- Handle method calls
    myWire:GetPlayerData("inventory"):andThen(function(data)
        print("Success:", data)
    end):catch(function(err)
        warn("Method call failed:", err)
    end)
    ```

    ## Best Practices

    1. **Consistent Naming**: Use the same namespace on both server and client
    2. **Error Handling**: Always handle promises and check if wires are ready
    3. **Middleware**: Use middleware for validation, logging, and rate limiting
    4. **Type Safety**: Use proper type annotations for better IntelliSense
    5. **Resource Management**: Remember to clean up connections when done

    ## Common Patterns

    ### Player Data Management
    ```lua
    -- Server
    local PlayerDataWire = NetWire.Server("PlayerData")
    
    PlayerDataWire.DataChanged = NetWire.createEvent()
    PlayerDataWire.RequestData = NetWire.createEvent()
    
    function PlayerDataWire:GetData(player: Player, dataType: string)
        return PlayerDataManager:GetData(player, dataType)
    end
    
    function PlayerDataWire:SetData(player: Player, dataType: string, value: any)
        PlayerDataManager:SetData(player, dataType, value)
        self.DataChanged:FireFor({player}, dataType, value)
    end
    ```

    ### Chat System
    ```lua
    -- Server
    local ChatWire = NetWire.Server("Chat")
    
    ChatWire.MessageSent = NetWire.createEvent()
    ChatWire.PlayerMuted = NetWire.createEvent()
    
    function ChatWire:SendMessage(player: Player, message: string)
        if ChatManager:IsPlayerMuted(player) then
            return false
        end
        
        local filteredMessage = ChatManager:FilterMessage(message)
        self.MessageSent:FireAll(player, filteredMessage)
        return true
    end
    ```

    ### Real-time Updates
    ```lua
    -- Server
    local GameStateWire = NetWire.Server("GameState")
    
    GameStateWire.PlayersOnline = NetWire.createProperty(0)
    GameStateWire.ServerHealth = NetWire.createProperty(100)
    
    -- Update properties regularly
    game:GetService("RunService").Heartbeat:Connect(function()
        GameStateWire.PlayersOnline:Set(#game.Players:GetPlayers())
        GameStateWire.ServerHealth:Set(math.random(90, 100))
    end)
    ```
]=]

return nil
