--!strict
--[=[
	@class TableReplicator

	Simple wrapper that replicates TableManager instances from the server to clients.

	Entry point for the TableReplicator package. Use `TableReplicator.Server` or 
	`TableReplicator.Client` to access the server-side or client-side API, respectively.

	**[SERVER]**
	```lua
	local TableReplicator = require(Packages.TableReplicator).Server
	local TableManager = require(Packages.TableManager)
	local PlayerToken = TableReplicator.TOKEN("PlayerData")

	Players.PlayerAdded:Connect(function(player)
		local manager = TableManager.new {
			Coins = 0,
		}

		local replicator = TableReplicator.new({
			Token = PlayerToken,
			Manager = manager,
			ReplicationTargets = player,
		})

		task.spawn(function()
			while player.Parent do
				task.wait(1)
				manager:Increment("Coins", math.random(1, 10))
			end
		end)

		-- simple cleanup
		player.Destroying:Connect(function()
			replicator:Destroy()
			manager:Destroy()
		end)
	end)
	```

	**[CLIENT]**
	```lua
	local TableReplicator = require(Packages.TableReplicator).Client

	TableReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	TableReplicator.RequestData()
	```

	---
	### Exported Types
	- ServerReplicator
	- ClientReplicator
	- BaseReplicator
	- Replicator
	- ReplicationToken
	- ReplicationTargets
	- SearchCondition
	- Tags

]=]

const RunService = game:GetService("RunService")

const Types = require("@self/Shared/Types")

export type ServerReplicatorClass = typeof(require("@self/Server/ServerReplicator"))
export type ClientReplicatorClass = typeof(require("@self/Client/ClientReplicator"))

export type BaseReplicator = Types.BaseReplicator
export type ServerReplicator = Types.ServerReplicator
export type ClientReplicator = Types.ClientReplicator
export type Replicator = ServerReplicator | ClientReplicator

export type ReplicationToken = Types.ReplicationToken
export type ReplicationTargets = Types.ReplicationTargets
export type SearchCondition = Types.SearchCondition
export type Tags = Types.Tags

--------------------------------------------------------------------------------
	--// Entry Point //--
--------------------------------------------------------------------------------

const TableReplicator = {}

if RunService:IsClient() then
	--[=[
		@client
		@prop TableReplicator.Client ClientReplicator
	]=]
	TableReplicator.Client = require("@self/Client/ClientReplicator")
	TableReplicator.Current = TableReplicator.Client :: any
else
	--[=[
		@server
		@prop TableReplicator.Server ServerReplicator
	]=]
	TableReplicator.Server = require("@self/Server/ServerReplicator")
	TableReplicator.Current = TableReplicator.Server :: any
end

setmetatable(TableReplicator, {
    __index = TableReplicator.Current
})

return table.freeze(TableReplicator) :: {
	Server: ServerReplicatorClass,
	Client: ClientReplicatorClass,
	Current: ServerReplicatorClass | ClientReplicatorClass,
}
