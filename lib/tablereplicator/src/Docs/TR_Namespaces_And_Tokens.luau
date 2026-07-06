--[=[
	@class TR Namespaces & Tokens

	A **namespace** is an optional string that identifies a replicator's "class" so it
	can be discovered by name. Tokens layer opt-in collision safety on top of that.

	### Namespaces are optional

	Pass `Namespace` when you want to find the replicator by string later:

	```lua
	-- Named — discoverable by its namespace string.
	ServerReplicator.new({ Namespace = "Inventory", Data = ..., Targets = {} })

	ClientReplicator.ForEach("Inventory", function(replicator) ... end)
	```

	Omit it for an **anonymous** replicator. Anonymous replicators still work fully —
	they're just intentionally unreachable by string search. Find them by `Id`, by tags,
	or with a predicate instead:

	```lua
	-- Anonymous — reachable only by Id, tags, or predicate.
	local rep = ServerReplicator.new({
		Data = ...,
		Targets = {},
		Tags = { Kind = "Ephemeral" },
	})

	ClientReplicator.ForEach({ Kind = "Ephemeral" }, function(replicator) ... end)
	```

	See [TR Discovery & Targeting](/api/TR%20Discovery%20&%20Targeting) for the full
	set of search conditions.

	### Opt-in collision safety with `TOKEN`

	In a large codebase, two unrelated modules might accidentally pick the same
	namespace string. A `ReplicationToken` claims a name **exclusively** so that can't
	happen silently. Claim it once (usually at the top of a module), store it, and pass
	it as the `Namespace`:

	```lua
	local PlayerToken = ServerReplicator.TOKEN("PlayerData")

	ServerReplicator.new({ Namespace = PlayerToken, Data = ..., Targets = {} })

	-- Release the name once every replicator using it is destroyed:
	ServerReplicator.TOKEN.destroy(PlayerToken)
	```

	`TOKEN` also exposes `TOKEN.new(name)` (identical to calling `TOKEN(name)`) and
	`TOKEN.get(name)` to fetch an already-registered token.

	:::caution Collision rules
	The ownership ledger enforces these — each throws rather than failing silently:

	- `TOKEN("Name")` throws if `"Name"` is already owned by another token.
	- `TOKEN("Name")` throws if live replicators already use `"Name"` as a raw string.
	- Passing the raw string `"Name"` as a `Namespace` throws once a token owns it —
	  pass the **token object** instead.
	- `TOKEN.destroy(token)` throws if any replicator using that token is still alive.

	Because of the second rule, claim your token at module load, **before** any
	replicator with that name is created.
	:::

	### When should I use a token?

	| Situation | Recommendation |
	| --- | --- |
	| Small project, or a namespace only ever used in one place | A plain string is fine — tokens add nothing. |
	| Shared library, or a name used across several modules | Use a `TOKEN` so accidental reuse fails loudly. |
	| Discovery on the client | Either works — a token matches the same string a raw namespace would. |

	Tokens are purely a **server-side** authoring safeguard; on the wire and on the
	client a token is just its name string.

	---
	### See also

	- **[TR Getting Started](/api/TR%20Getting%20Started)** — where `Namespace` fits in the config table.
	- **[TR Discovery & Targeting](/api/TR%20Discovery%20&%20Targeting)** — matching by namespace, token, tags, or predicate.
]=]
