--[=[
	@class TR Custom Remotes

	Sometimes you need to send an *event* or call a *function* alongside replicated
	data — a "you were hit" signal, a "buy this item" request, and so on. Rather than
	managing your own `RemoteEvent`s, TableReplicator lets you attach custom remotes
	directly to a replicator. They're addressed per-replicator and (optionally) ordered
	with that replicator's data ops.

	:::note Two proxies, one convention
	The server talks to clients through `replicator.Client`; the client talks to the
	server through `replicator.Server`. So the side you're **sending to** is the proxy
	you use. A remote registered as `"Hit"` is fired on the server via
	`replicator.Client.Hit` and listened to on the client via `replicator.Server.Hit`.
	:::

	---
	## Declaring remotes

	The quickest way is the `Client` field on `ServerReplicator.new`. Use the sentinel
	helpers for signals, and a plain function for a callable:

	```lua
	local replicator = ServerReplicator.new({
		Namespace = "Combat",
		Targets = player,
		Client = {
			Hit = ServerReplicator.createRemoteEvent(),          -- a signal
			Whiff = ServerReplicator.createUnreliableEvent(),    -- an unreliable signal
			GetLoadout = function(self, player, slot)            -- a function
				return loadouts[player][slot]
			end,
		},
	})
	```

	:::caution **Client** declarations are ordered
	Remotes declared in the `Client` table are registered as their **ordered** variants:
	a signal there behaves like `RegisterOrderedRemoteSignal`, and a function like
	`RegisterOrderedRemoteFunction`. That means their delivery is interleaved with data
	ops in frame order (see [TR Performance & Ordering](/api/TR%20Performance%20&%20Ordering)),
	and clients must call `InvokeAsync` — not `Invoke` — on such functions.
	If you want the **unordered** variants, register them explicitly instead (next
	section). `createUnreliableEvent()` is always unreliable regardless.
	:::

	### Registering explicitly

	Every remote can also be registered after construction. This is the only way to get
	the unordered reliable variants:

	```lua
	replicator:RegisterRemoteSignal("Hit")             -- reliable, unordered
	replicator:RegisterRemoteUnreliableSignal("Whiff") -- unreliable
	replicator:RegisterOrderedRemoteSignal("Combo")    -- reliable, ordered with data

	replicator:RegisterRemoteFunction("GetScore", function(self, player) return 42 end)
	replicator:RegisterOrderedRemoteFunction("Buy", function(self, player, itemId) ... end)
	```

	Here's the full picture — how a remote is declared, what it is, and how the client
	calls it:

	| Register with | Kind | Client uses |
	| --- | --- | --- |
	| `RegisterRemoteSignal` | reliable signal | `Connect` / `Fire` |
	| `RegisterRemoteUnreliableSignal` | unreliable signal | `Connect` / `Fire` |
	| `RegisterOrderedRemoteSignal` *(or a signal in `Client`)* | ordered signal | `Connect` / `Fire` |
	| `RegisterRemoteFunction` | unordered function | `Invoke` (yields) |
	| `RegisterOrderedRemoteFunction` *(or a function in `Client`)* | ordered function | `InvokeAsync` (Promise) |

	---
	## Signals

	Signals are two-way: the server can fire to clients, and clients can fire back.

	**Server → client.** Fire through `replicator.Client[name]`:

	```lua
	replicator.Client.Hit:Fire(player, "headshot")   -- one active player
	replicator.Client.Hit:FireAll("headshot")         -- all active players
	replicator.Client.Hit:FireExcept(player, "...")   -- all except one (or a list)
	replicator.Client.Hit:FirePredicate(function(plr)
		return plr.Team == redTeam
	end, "...")                                        -- a filtered audience
	```

	**Client → server.** Listen and fire through `replicator.Server[name]`:

	```lua
	-- On the client
	replicator.Server.Hit:Connect(function(hitType)
		print("Hit:", hitType)
	end)
	replicator.Server.Hit:Fire("blocked")        -- fire back to the server
	replicator.Server.Hit:FireUnreliable("...")  -- force unreliable delivery

	-- On the server, receive client fires:
	replicator.Client.Hit:Connect(function(player, ...) end)
	replicator.Client.Hit:Wait()                 -- yields until any client fires
	```

	
	## Functions

	A function is registered on the server and called from the client. Which client
	method to use depends on whether it's ordered:

	```lua
	-- Unordered function -> client Invoke (yields for the result)
	replicator:RegisterRemoteFunction("GetScore", function(self, player)
		return scores[player]
	end)
	local score = replicator.Server.GetScore:Invoke()

	-- Ordered function -> client InvokeAsync (returns a Promise; response arrives
	-- after any data ops the server queued in the same frame)
	replicator:RegisterOrderedRemoteFunction("Buy", function(self, player, itemId)
		return purchase(player, itemId)
	end)
	replicator.Server.Buy:InvokeAsync("sword"):andThen(function(ok) end)
	```

	The server-side handler always receives `(self, player, ...)` — `self` is the
	replicator and `player` is the caller.

	:::tip Wrong-method warnings
	Calling `Invoke` on a signal, `Connect` on a function, or `Invoke` on an *ordered*
	function all emit a warning naming the correct method — a handy signal you've mixed
	up a remote's kind.
	:::

	---
	### See also

	- **[TR Getting Started](/api/TR%20Getting%20Started)** — the `Client` config field in context.
	- **[TR Performance & Ordering](/api/TR%20Performance%20&%20Ordering)** — what "ordered" delivery guarantees and costs.
]=]
