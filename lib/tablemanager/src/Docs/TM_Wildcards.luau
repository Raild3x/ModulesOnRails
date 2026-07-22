--[=[
	@class TM Wildcards

	A `"*"` segment in a path is a **wildcard**: it matches every key present at
	that position. One path grammar covers the whole API — the same `"*"` works
	when you listen ([OnValueChange](/api/TableManager#OnValueChange) and friends),
	write ([Set](/api/TableManager#Set), [Update](/api/TableManager#Update),
	[Increment](/api/TableManager#Increment)), and read in bulk
	([GetMatching](/api/TableManager#GetMatching)).

	```lua
	local manager = TableManager.new({
		Players = {
			p123 = { Health = 100, Stats = { Str = 1, Dex = 2 } },
			p456 = { Health = 70,  Stats = { Str = 3 } },
		},
	})

	manager:OnValueChange("Players.*.Health", function(new, old, metadata)
		print(`{metadata.WildcardMatches[1]} health: {old} -> {new}`)
	end)

	manager:Increment("Players.*.Health", 5) -- everyone heals 5, one listener covers all
	```

	Paths may be dot-strings (`"Players.*.Health"`) or arrays
	(`{ "Players", "*", "Health" }`) — `"*"` is the wildcard in both forms.

	## The governing rule

	**Literal segments keep exact-path semantics; wildcard segments match what
	exists.** A literal segment must resolve (a non-table value along a literal
	prefix errors, exactly as a non-wildcard call would). A `"*"` segment instead
	expands to every key at that level *at call time* — and a branch where the
	remaining path cannot resolve is silently skipped rather than erroring, so a
	heterogeneous collection is safe to sweep.

	```lua
	local manager = TableManager.new({
		Players = {
			A = { Stats = { Str = 1 } },
			B = { Stats = 5 },  -- Stats is not a table
			C = {},             -- no Stats at all
		},
	})

	manager:Set("Players.*.Stats.Str", 9)
	-- only A matches: B's Stats is not a table, C has no Stats -> both skipped
	```

	Because matches are collected *before* any write happens, a mass mutation
	never trips over its own edits (deleting every key while iterating is safe).

	## Multiple wildcards

	A path may contain any number of `"*"` segments. They compose as the **product
	of their branch factors**: `"Players.*.Stats.*"` visits every stat of every
	player.

	```lua
	-- Players = { A = { Stats = { Str, Dex } }, B = { Stats = { Str } } }
	manager:Update("Players.*.Stats.*", function(value)
		return value * 2
	end)
	-- 3 concrete writes: A.Stats.Str, A.Stats.Dex, B.Stats.Str
	```

	`WildcardMatches` (below) carries one entry per `"*"`, left-to-right — so the
	first `"*"` is `WildcardMatches[1]`, the second is `WildcardMatches[2]`, and so
	on.

	## Listening

	Every path listener accepts wildcards, so one registration covers a dynamic
	collection without re-subscribing when keys come and go. The keys a fire
	matched are on `metadata.WildcardMatches`:

	```lua
	manager:OnValueChange("Players.*.Health", function(new, old, metadata)
		local playerId = metadata.WildcardMatches[1]
		print(`{playerId}: {old} -> {new}`)
	end)

	manager:OnKeyAdd("Rooms.*.Occupants", function(key, value, metadata)
		local roomId = metadata.WildcardMatches[1]
		print(`{key} entered room {roomId}`)
	end)
	```

	A literal listener and a wildcard listener that both match the same change
	**both** fire. `WildcardMatches` is `nil` for a listener registered without any
	wildcards.

	:::caution `Once` on a wildcard path
	A listener registered with `Once = true` on a wildcard path fires once
	**total** across all matching keys (it lives on a single tree node), not once
	per key.
	:::

	## Writing

	[Set](/api/TableManager#Set), [Update](/api/TableManager#Update), and
	[Increment](/api/TableManager#Increment) fan out across every matched path.
	When more than one path matches, the writes are wrapped in a single
	[Batch](/api/TableManager#Batch) so listeners observe one coherent flush.

	```lua
	-- Write the same value everywhere (creates the final key where missing):
	manager:Set("Players.*.Shield", 50)

	-- Remove a key from every match (only visits keys that exist):
	manager:Set("Players.*.Shield", nil)

	-- Delete every member of a collection:
	manager:Set("Players.*", nil)

	-- Read-modify-write per match:
	manager:Increment("Players.*.Health", 5)
	```

	`Update`'s callback also receives, after the current value, the keys matched
	by each `"*"` and the fully concrete path — so it can tell which match it is
	handling:

	```lua
	manager:Update("Players.*.Stats.*", function(value, matches, path)
		-- matches[1] = playerId, matches[2] = statName
		-- path       = { "Players", playerId, "Stats", statName }
		return value + 1
	end)
	```

	A few write-specific rules:

	- **Missing final key.** A non-`nil` `Set` creates a missing *final* key on
	  each matched parent (just like a plain `Set`). A `nil` write, and the
	  read-modify-write forms (`Update`/`Increment`), only visit keys that already
	  exist.
	- **Zero matches is a no-op** — no writes, no events.
	- **`buildTablesDynamically`** cannot be combined with a wildcard path (there
	  is no key to invent for `"*"`).
	- **Return value.** `Update`/`Increment` return `nil` on a wildcard path
	  (there is no single result); use `GetMatching` afterward if you need the new
	  values.

	:::caution Sharing a table value across matches
	Writing one **table** value to several matched paths is governed by
	[DuplicateReferenceMode](/api/TableManager#DuplicateReferenceMode): under
	`"allow"` (the default) every matched path shares the SAME table identity;
	use `"copy"` to give each match an independent clone.

	```lua
	manager:Set("Players.*.Loadout", { Weapon = "Sword" })
	-- "allow": Players.A.Loadout == Players.B.Loadout (one shared table)
	-- "copy":  each player gets its own { Weapon = "Sword" }
	```
	:::

	## Reading in bulk

	`Get` returns a single value and does **not** interpret wildcards. To read
	every match, use [GetMatching](/api/TableManager#GetMatching), which returns
	one record per concrete match:

	```lua
	local matches = manager:GetMatching("Players.*.Health")
	-- {
	--   { Path = { "Players", "p123", "Health" }, Value = 100, WildcardMatches = { "p123" } },
	--   { Path = { "Players", "p456", "Health" }, Value = 70,  WildcardMatches = { "p456" } },
	-- }

	for _, match in matches do
		print(match.WildcardMatches[1], "has", match.Value, "health")
	end
	```

	Each record carries the concrete `Path`, the `Value`, and `WildcardMatches`
	(the same convention as listeners). Entry order follows table iteration order
	and is not deterministic for dictionary keys. A path with no wildcards returns
	zero-or-one records, resolved exactly like `Get`.

	## Replication

	Wildcard expansion happens against **local** state, so a wildcard write is
	never shipped as a wildcard: [OnApplied](/api/TableManager#OnApplied) (and
	replication) sees N concrete ops — one per matched path — never a `"*"` path.
	A remote peer therefore replays the exact keys that changed on the origin, not
	a re-expansion against its own (possibly different) data.

	## `"*"` is reserved

	Because `"*"` is a wildcard everywhere the path grammar is interpreted, a
	literal `"*"` **data key** cannot be addressed through `Set`/`Update`/
	`Increment`/`GetMatching` or the listener methods. This is virtually never a
	real key, but if you must work with one, reach past the path grammar:

	- **Write:** `manager.Proxy.parent["*"] = value` — the proxy writes the literal
	  key and still fires change events.
	- **Read:** `manager.Proxy.parent["*"]`, `manager.Raw.parent["*"]`, or
	  `manager:Get({ "parent", "*" })` (`Get` treats `"*"` literally).
	- **Listen:** there is no escape — a literal `"*"` key cannot be observed
	  distinctly from a wildcard.

	---
	### See also

	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — the full listener surface these wildcards plug into.
	- **[TM Batching](/api/TM%20Batching)** — the batch window a multi-match write flushes through.
	- **[TM Proxies & Direct Table Access](/api/TM%20Proxies%20&%20Direct%20Table%20Access)** — the proxy escape hatch for reserved keys.
]=]
