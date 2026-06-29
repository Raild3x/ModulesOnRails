--!strict
--[=[
	@class TableReplicator2

	Replicates TableManager2 instances from the server to clients.

	**[SERVER]**
	```lua
	local TableReplicator = require(Packages.TableReplicator2).Server
	local PlayerToken = TableReplicator.Token("PlayerData")

	Players.PlayerAdded:Connect(function(player)
		TableReplicator.new({
			Token = PlayerToken,
			Data = { Coins = 0 },
			ReplicationTargets = player,
			Tags = { UserId = player.UserId },
		})
	end)
	```

	**[CLIENT]**
	```lua
	local TableReplicator = require(Packages.TableReplicator2).Client

	TableReplicator.OnNew("PlayerData", function(replicator)
		replicator:GetManager():Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	TableReplicator.RequestData()
	```
]=]

const RunService = game:GetService("RunService")

export type ServerReplicator = typeof(require("@self/Server/ServerReplicator"))
export type ClientReplicator = typeof(require("@self/Client/ClientReplicator"))

const TableReplicator = {}

if RunService:IsClient() then
	--[=[
		@client
		@within TableReplicator
		@prop Client ClientReplicator
	]=]
	TableReplicator.Client = require("@self/Client/ClientReplicator")
	TableReplicator.Current = TableReplicator.Client :: any
else
	--[=[
		@server
		@within TableReplicator
		@prop Server ServerReplicator
	]=]
	TableReplicator.Server = require("@self/Server/ServerReplicator")
	TableReplicator.Current = TableReplicator.Server :: any
end

setmetatable(TableReplicator, {
    __index = TableReplicator.Current
})

return table.freeze(TableReplicator) :: {
	Server: ServerReplicator,
	Client: ClientReplicator,
	Current: ServerReplicator | ClientReplicator,
}
