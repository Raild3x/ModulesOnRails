--[=[
	@class TR Discovery & Targeting

	Two related questions come up constantly with TableReplicator:

	- **Discovery** — "how does the client (or another server system) find the
	  replicator it cares about?"
	- **Targeting** — "which players does a top-level replicator send its data to?"

	This guide covers both.

	---
	## Discovery

	Every discovery API takes an optional `SearchCondition`. A condition can be one of
	four things:

	| Condition | Matches |
	| --- | --- |
	| a **string** | replicators whose `Namespace` equals the string |
	| a **`ReplicationToken`** | replicators whose namespace equals the token's name |
	| a **tags table** `{ k = v }` | replicators whose tags are a **superset** of the given pairs |
	| a **predicate** `(replicator) -> boolean` | whatever you decide |
	| omitted (`nil`) | every replicator |

	:::note Anonymous replicators
	A replicator created without a `Namespace` never matches a string or token
	condition. Reach it by `Id`, tags, or a predicate instead. See
	[TR Namespaces & Tokens](/api/TR%20Namespaces%20&%20Tokens).
	:::

	### `ForEach` vs `OnNew`

	Both run a callback as replicators appear, and both return a disconnect function.
	The difference is whether already-existing replicators are included:

	```lua
	-- ForEach: runs for existing matches immediately, then for every future one.
	local disconnect = ClientReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	-- OnNew: runs ONLY for replicators created after this call.
	ClientReplicator.OnNew("PlayerData", function(replicator)
		print("A new PlayerData replicator appeared:", replicator.Id)
	end)

	-- Stop receiving callbacks:
	disconnect()
	```

	:::tip Prefer `ForEach`
	`ForEach` is almost always what you want — `OnNew` silently misses replicators that
	already exist (including everything in the initial client snapshot). Only reach for
	`OnNew` when you specifically want *future-only* matches.
	:::

	Conditions work the same across the board — here filtering by tag on the client so a
	callback only runs for the local player's replicator:

	```lua
	local localPlayer = game:GetService("Players").LocalPlayer

	ClientReplicator.ForEach({ UserId = localPlayer.UserId }, function(replicator)
		-- only fires for a replicator tagged with this UserId
	end)
	```

	### One-shot lookups

	When you want a single replicator rather than a running subscription:

	```lua
	-- Synchronous — nil if nothing matches right now.
	local rep = ClientReplicator.GetFirst("PlayerData")
	local byId = ClientReplicator.GetFromId(42)
	local all = ClientReplicator.GetAll({ Team = "Red" }) -- every current match

	-- Promise-based — resolves as soon as a match exists (now or later).
	ClientReplicator.PromiseFirst("PlayerData"):andThen(function(replicator)
		print("Got it:", replicator.Id)
	end)
	ClientReplicator.PromiseFromId(42):andThen(function(replicator) end)
	```

	All of these are static methods available on both [ServerReplicator](/api/ServerReplicator)
	and [ClientReplicator](/api/ClientReplicator). There is also a `ReplicatorCreated`
	signal that fires for every
	new replicator regardless of condition, if you want the raw stream.

	---
	## Targeting

	Targeting decides which players a **top-level** replicator replicates to. (Child
	replicators inherit their top-level ancestor's targets — see
	[TR Parent-Child Guide](/api/TR%20Parent-Child%20Guide).) Set the initial audience
	with the `Targets` field, then
	adjust it live:

	```lua
	local replicator = ServerReplicator.new({
		Namespace = "Match",
		Data = { Score = 0 },
		Targets = {}, -- start with nobody; add players as they join the match
	})

	replicator:AddTarget(player)            -- add one player (or a { Player } list)
	replicator:RemoveTarget(player)         -- remove one player (or a list)
	replicator:SetTargets({ p1, p2 })       -- overwrite the whole target list
	replicator:SetTargets("all")            -- replicate to every current & future player

	local players = replicator:GetTargets() -- { Player } currently targeted
	local isSeen  = replicator:IsReplicatingTo(player) -- boolean
	```

	When you add a player who has already bootstrapped (called `RequestData`), they
	immediately receive a snapshot of the replicator's whole subtree. Removing an active
	player sends them a destroy for it.

	:::caution Top-level only
	`SetTargets`, `AddTarget`, and `RemoveTarget` throw on a child replicator — its
	audience is whatever its top-level ancestor targets. Reparent it instead
	(see [TR Parent-Child Guide](/api/TR%20Parent-Child%20Guide)).
	:::

	---
	### See also

	- **[TR Getting Started](/api/TR%20Getting%20Started)** — the basic create/listen flow.
	- **[TR Namespaces & Tokens](/api/TR%20Namespaces%20&%20Tokens)** — string namespaces vs anonymous vs tokens.
	- **[TR Parent-Child Guide](/api/TR%20Parent-Child%20Guide)** — how children inherit targeting.
]=]
