--[=[
	@class TR Getting Started

	TableReplicator replicates [TableManager](/api/TableManager) instances from the
	server to clients. On the server you create a [ServerReplicator](/api/ServerReplicator),
	decide who can see it, and mutate its `.Manager`. Every write is mirrored
	automatically to a matching [ClientReplicator](/api/ClientReplicator) on each
	targeted client.

	This guide walks through the minimal end-to-end setup. For deeper topics see the
	other guides linked at the bottom of the page.

	### 1. Require the module

	The module exposes two entry points — one per realm. Require the one for the side
	you're on:

	```lua
	-- Server scripts
	local ServerReplicator = require(Packages.TableReplicator).Server

	-- Client scripts
	local ClientReplicator = require(Packages.TableReplicator).Client
	```

	### 2. Create a replicator on the server

	`ServerReplicator.new` takes a single config table. The two fields you'll always
	set are `Data` (what to replicate) and `Targets` (who receives it). Mutate the
	replicator's `.Manager` and the change is queued and sent at the end of the frame.

	```lua
	local Players = game:GetService("Players")

	Players.PlayerAdded:Connect(function(player)
		local replicator = ServerReplicator.new({
			Namespace = "PlayerData",      -- how clients discover it
			Data = { Coins = 0, Level = 1 }, -- raw table, or an existing TableManager
			Targets = player,              -- a Player, a { Player } list, or "all"
			Tags = { UserId = player.UserId }, -- optional metadata for filtering
		})

		replicator.Manager:Set("Coins", 100) -- replicated automatically

		player.Destroying:Connect(function()
			replicator:Destroy()
		end)
	end)
	```

	### 3. Read the data on the client

	Clients never create replicators — the server drives their whole lifetime. Use
	`ForEach` to run a callback for every matching replicator (existing **and**
	future), then call `RequestData()` once to pull the initial snapshot.

	```lua
	-- Register listeners BEFORE RequestData so they catch the initial snapshot.
	ClientReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	ClientReplicator.RequestData():andThen(function()
		print("Initial snapshot applied")
	end)
	```

	:::caution Call `RequestData()` once
	Clients must call `ClientReplicator.RequestData()` at least once to receive the 
	initial snapshot. Otherwise replication will never begin. Subsequent calls are safe no-ops.
	:::

	---
	### The config table at a glance

	| Field | Purpose |
	| --- | --- |
	| `Data` | A raw table (auto-wrapped in a `TableManager`) or an existing `TableManager`. Defaults to `{}`. |
	| `Targets` | Who a **top-level** replicator sends to: a `Player`, a `{ Player }` list, or `"all"`. Pass `{}` to start with none. |
	| `Parent` | A parent `ServerReplicator`, for **child** replicators. Mutually exclusive with `Targets`. |
	| `Namespace` | Optional string (or `ReplicationToken`) used for discovery. Omit for anonymous replicators. |
	| `Tags` | Optional `{ [string]: any }` metadata for filtering in `ForEach`/`GetAll`/`GetFirst`. |
	| `Coalesced` | Send only the latest op per key each frame, dropping intermediate writes. |
	| `ImmediateFlush` | Send each op immediately instead of batching per frame. |
	| `Client` | Declares custom remotes (signals/functions). See [TR Custom Remotes](/api/TR%20Custom%20Remotes). |


	### Things to be aware of

	:::caution Exactly one of `Targets` or `Parent`
	A top-level replicator **must** be given `Targets` (pass `{}` for none). A child
	replicator **must** be given `Parent` and inherits its ancestor's targets. Passing
	both, or neither, throws.
	:::

	- **Always destroy when done.** Call `replicator:Destroy()` when a replicator is no
	  longer needed. It also listens to its manager's `OnDestroy`, so destroying the
	  manager tears the replicator down too.
	- **Client code never creates or destroys replicators.** Lifetime is server-driven;
	  calling `Destroy` on a `ClientReplicator` errors.
	- **Call `RequestData()` once at startup.** Subsequent calls are safe no-ops.
	- **Setting up `OnNew` listeners before `RequestData()`.** Listeners added
	  after it resolves may miss replicators that were in the initial snapshot since.
	  `OnNew` only fires for replicators that arrive after the listener is registered.

	---
	### See also

	- **[TR Discovery & Targeting](/api/TR%20Discovery%20&%20Targeting)** — finding replicators and controlling who receives them.
	- **[TR Namespaces & Tokens](/api/TR%20Namespaces%20&%20Tokens)** — namespaces and opt-in collision safety.
	- **[TR Parent-Child Guide](/api/TR%20Parent-Child%20Guide)** — nesting replicators into hierarchies.
	- **[TR Custom Remotes](/api/TR%20Custom%20Remotes)** — sending events and functions alongside data.
	- **[TR Performance & Ordering](/api/TR%20Performance%20&%20Ordering)** — batching, coalescing, and ordering guarantees.
]=]
