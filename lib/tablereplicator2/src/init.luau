--!strict
--[=[
	@class TableReplicator

	Replicates `TableManager` instances from the server to clients. A
	`ServerReplicator` wraps a `TableManager`, decides which players can see it,
	and mirrors every write to a matching `ClientReplicator` on each targeted client.

	Access the API through `TableReplicator.Server` (server) or
	`TableReplicator.Client` (client).

	**Server**
	```lua
	local ServerReplicator = require(Packages.TableReplicator2).Server

	Players.PlayerAdded:Connect(function(player)
		local replicator = ServerReplicator.new({
			Namespace = "PlayerData",
			Data = { Coins = 0 },
			ReplicationTargets = player,
		})

		replicator.Manager:Set("Coins", 100) -- automatically replicated

		player.Destroying:Connect(function()
			replicator:Destroy()
		end)
	end)
	```

	**Client**
	```lua
	local ClientReplicator = require(Packages.TableReplicator2).Client

	-- Register listeners before requesting data to catch replicators in the snapshot.
	ClientReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	ClientReplicator.RequestData()
	```

	---
	### Core concepts
	- **Namespace** — Optional string class identifier used for discovery
	  (e.g. `"PlayerData"`). Omit for anonymous replicators, which are reachable
	  only by Id, tags, or predicate.
	- **ReplicationTargets** — Which players a top-level replicator sends data to.
	  Accepts a single `Player`, a list, or `"all"`. Child replicators inherit from
	  their top-level ancestor.
	- **Tags** — Arbitrary key/value metadata (e.g. `{ UserId = player.UserId }`)
	  used for filtering in `ForEach`/`GetAll`/`GetFirst`.
	- **Discovery** — Use `ForEach` to react to existing and future replicators by
	  namespace, tag, or predicate. Prefer it over `OnNew`, which misses replicators
	  that already exist at call time.
	- **RequestData** — Clients must call `ClientReplicator.RequestData()` once to
	  receive the initial snapshot. Register `ForEach`/`OnNew` listeners before calling it.

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
	- FireMode

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
export type FireMode = Types.FireMode

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
