--[=[
	@class CO Queries

	A [Query](/api/Query) is a reusable, reactive description of "the instances
	matching these requirements". Where [FromInstance](/api/Component#FromInstance)
	answers *about one instance*, a query answers *about the whole world* — and
	keeps answering as instances come and go. Build one with
	[Component.query](/api/Component#query), refine it with chain methods, then
	either observe it (reactive) or read it once.

	### 1. Build a query

	Every argument to `query(...)` is a **requirement** the instance must satisfy. A
	requirement is a component class (satisfied while that component is *started* on
	the instance), a tag string, another Query, a filter node, or a combinator.

	```lua
	local Component = require(Packages.Component)

	-- instances that currently have BOTH the Physics and Velocity components started
	local moving = Component.query(Physics, Velocity)

	-- a raw tag works too, and mixes freely with classes
	local hazards = Component.query("Hazard")
	```

	:::caution Every query needs a bounded source
	A query must have at least one **enumerable** positive requirement — a
	component, a tag, or a sub-query (or an `And`/`Or` of them) — so its candidate
	set is finite. Filter nodes and `Not` only *refine*; a query built from those
	alone errors when read or observed. Add a real source with `query(...)`,
	`:with`, or `:withAny`.
	:::

	### 2. Refine it

	Builders return a **new** query (queries are immutable values), so chains branch
	freely and the receiver is never mutated.

	```lua
	local q = Component.query(Enemy)
		:with(Targetable)             -- also require this (AND)
		:withAny(Ranged, Melee)       -- at least one of these
		:without(Stunned)             -- none of these
		:withAttribute("Team", "Red") -- attribute equals a value
		:withProperty("Anchored", false)
		:where(function(instance)     -- arbitrary predicate
			return instance:GetPivot().Position.Y > 0
		end)
	```

	Matcher lists (for `:withAttribute` / `:withProperty` and the `Attr` / `Prop`
	nodes) are **any-of**: pass several values or `(instance, value) -> boolean`
	predicates and the value need satisfy just one. Pass none to require mere
	existence.

	```lua
	:withAttribute("Rarity", "Epic", "Legendary")           -- Epic OR Legendary
	:withAttribute("Level", function(_, v) return v >= 10 end) -- predicate
	:withProperty("Adornee")                                 -- must merely exist
	```

	### 3. Compose with nodes

	`Query.Attr` / `Query.Prop` / `Query.Pred` are filter nodes, and
	`Query.And` / `Query.Or` / `Query.Not` combine any requirements (they must be
	constructors — `and`/`or`/`not` are reserved words). They nest freely and go
	anywhere a requirement is accepted:

	```lua
	-- "B or C, but not both" (exclusive or)
	Component.query(A):withAny(B, C):without(Query.And(B, C))

	-- a nested boolean requirement
	Component.query(Enemy):with(Query.Or(Ranged, Query.And(Melee, Enraged)))
	```

	### 4. Observe it (reactive)

	`:observe` runs your callback for every instance matching now, and for every one
	that matches later — each with a fresh [Janitor](/api/Janitor) that is cleaned
	up the moment the instance stops matching. Fetch the matched component inside
	with `FromInstance`.

	```lua
	local connection = Component.query(Enemy, Targetable):observe(function(instance, janitor)
		local enemy = Enemy:FromInstance(instance)
		janitor:Add(highlight(instance), "Destroy") -- removed when it stops matching
	end)

	-- stop watching (destroys all active match janitors):
	connection:Disconnect()
	```

	Use `:track()` when you only need cheap repeated reads and no per-match
	callback; it keeps the match set maintained so the reads below are O(1) /
	O(matches). `:observeUnyielding` is the same as `:observe` but runs its callback
	inline on the change thread — the fast path for hot bind/unbind work, at the
	cost that the callback must not yield.

	### 5. Read it once

	The one-shot reads take no subscription. While the query is being observed (or
	tracked) anywhere in the game, they answer straight from the live engine;
	otherwise they compute on the spot.

	```lua
	local all   = q:get()          -- { Instance } of current matches (alias: GetMatches)
	local n     = q:count()        -- how many match
	local one   = q:first()        -- one match, or nil
	local hit   = q:contains(inst) -- does this instance match right now?

	for instance in q:iter() do    -- zero-allocation iteration for hot loops
		-- ...
	end
	```

	:::tip Structurally-equal queries share one engine
	`query(A, B)` and `query(B, A)` normalize to the same thing, so observing either
	anywhere in the process shares a single set of subscriptions and one match set.
	Duplicated requirements collapse too. You don't manage this — just build the
	query you mean.
	:::

	### 6. Compose by value, and `Sub`

	Passing a raw `Query` into another composes it **by value** — its clauses are
	spliced in, so `Component.query(q1):with(B)` is literally `q1:with(B)`. When you
	instead want a query to stay a live *nested* sub-query with its own shared
	engine (worth it for an expensive shared sub-query, or to validate it
	standalone), wrap it with `Query.Sub`:

	```lua
	local expensive = Component.query(Physics):where(heavyPredicate)
	Component.query(Enemy):with(Query.Sub(expensive)) -- kept by reference
	```

	---
	### See also

	- **[Query](/api/Query)** — the full API reference: every builder, node, and terminal.
	- **[CO Getting Started](/api/CO%20Getting%20Started)** — defining the component classes a query matches against.
	- **[CO Lifecycle & Cleanup](/api/CO%20Lifecycle%20&%20Cleanup)** — why a class requirement means *started*, and how teardown removes a match.
]=]
