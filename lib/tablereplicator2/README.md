# TableReplicator2

Replicates `TableManager2` instances from the server to clients. A `ServerReplicator`
wraps a `TableManager`, decides who can see it, and mirrors every write to a matching
`ClientReplicator` on each targeted client.

For the full API, see the moonwave docs.

## Quick start

**Server**
```lua
local ServerReplicator = require(Packages.TableReplicator2).Server

Players.PlayerAdded:Connect(function(player)
	local replicator = ServerReplicator.new({
		Namespace = "PlayerData",
		Data = { Coins = 0 },
		ReplicationTargets = player,
		Tags = { UserId = player.UserId },
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

-- Register listeners before requesting data to catch everything in the snapshot.
ClientReplicator.ForEach("PlayerData", function(replicator)
	replicator.Manager:Observe("Coins", function(coins)
		print("Coins:", coins)
	end)
end)

ClientReplicator.RequestData()
```

## Core concepts

| Concept | Description |
| --- | --- |
| **Namespace** | Optional string class identifier. Used for discovery (`ForEach("PlayerData", fn)`). Omit for anonymous replicators, which are reachable only by Id, tags, or predicate. |
| **ReplicationTargets** | Who a top-level replicator sends data to: a `Player`, a list, or `"all"`. Child replicators inherit from their top-level ancestor. |
| **Tags** | Arbitrary key/value metadata (`{ UserId = player.UserId }`) for filtering in `ForEach`/`GetAll`/`GetFirst`. |
| **ForEach vs OnNew** | `ForEach` runs for existing **and** future matches. `OnNew` only fires for replicators created after the call. Prefer `ForEach`. |
| **RequestData** | Clients must call this once to receive the initial snapshot. Register `ForEach`/`OnNew` listeners before calling it. |

### Namespace is optional

Omit `Namespace` entirely for anonymous replicators — still usable via `GetFromId`,
tags, `ForEach(predicate)`, and `ReplicatorCreated`, but intentionally unreachable by
string `OnNew`/`GetAll` searches.

```lua
-- Named (discoverable by Namespace string)
ServerReplicator.new({ Namespace = "Inventory", Data = ..., ReplicationTargets = {} })

-- Anonymous (discoverable only by Id / tags / predicate)
ServerReplicator.new({ Data = ..., ReplicationTargets = {}, Tags = { Kind = "Ephemeral" } })
```

### Opt-in collision safety with `TOKEN()`

For large codebases where accidental namespace reuse across modules would be a problem,
use `TOKEN()` to claim a name exclusively:

```lua
local PlayerToken = ServerReplicator.TOKEN("PlayerData")

ServerReplicator.new({ Namespace = PlayerToken, Data = ..., ReplicationTargets = {} })

-- Release the name after all replicators using it are destroyed:
ServerReplicator.TOKEN.destroy(PlayerToken)
```

Collision rules enforced by the ownership ledger:
- `TOKEN("Name")` throws if `"Name"` is already claimed by another token.
- `TOKEN("Name")` throws if live replicators already use `"Name"` as a raw string.
- Passing a raw string `Namespace` when a token owns that name throws — use the token.
- `TOKEN.destroy(token)` throws if any replicator using that token is still alive.

## Things to be aware of

- **Always destroy when done.** Call `replicator:Destroy()` when a replicator is no
  longer needed. The replicator also listens to its manager's `OnDestroy` and tears
  itself down, so destroying the manager is sufficient when the manager's lifetime
  drives cleanup.
- **Exactly one of `ReplicationTargets` or `Parent` is required** on construction.
  Pass `{}` for `ReplicationTargets` to start with no targets and add players later.
- **Client code never creates or destroys replicators.** Lifetime is server-driven.
- **Call `RequestData()` once at startup.** Subsequent calls are safe but no-ops.
- **Register listeners before `RequestData()`.** `ForEach`/`OnNew` listeners registered
  after `RequestData()` resolves may miss replicators from the initial snapshot.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the internal module map, end-to-end op-flow
diagram, ordering guarantees, and wire format reference.
