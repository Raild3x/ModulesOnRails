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

	### 2. Refine it — selector strings first

	The **selector dialect** is the primary spelling for value requirements: a
	CSS-like string lowered onto the same engine primitives as the chain
	builders (same re-evaluation, same interning — equivalent spellings share
	one engine).

	```lua
	local q = Component.query(
			Query.Selector([[Model.Enemy[$Team = "Red"][$Level >= 10]:not(.Stunned)]], workspace.Arena)
		)
		:with(Targetable)            -- component classes stay code-level (AND)
		:where(function(instance)    -- arbitrary predicate escape hatch
			return instance:GetPivot().Position.Y > 0
		end)
	```

	Grammar: `ClassName` (IsA semantics), `#Name`, `.Tag`,
	`[Prop op value]` / `[$Attr op value]` with ops
	`=  !=  >  >=  <  <=  ~ (Lua pattern, quoted)  :typeof(t)`,
	`:not(compound)`, and comma-separated OR groups. The optional second
	argument scopes the match to a root instance (default `workspace`);
	`[$Attr = 5]` is type-exact (`5` ≠ `"5"`), `!=` matches absent values,
	comparisons match numbers only, and `~` matches strings only.
	`>` / `>>` / `:has()` are reserved for the engine-native Collection
	backend and error for now.

	The chain builders still exist; `:withAny` / `:without` /
	`:withAttribute` / `:withProperty` are **deprecated** in favor of the
	dialect (comma groups, `:not(...)`, and bracket terms) and will be removed
	in v2.0.0. `:with` (component classes / composition) and `:where`
	(function predicates) are permanent.

	```lua
	local q = Component.query(Enemy)
		:with(Targetable)             -- also require this (AND)
		:withAny(Ranged, Melee)       -- DEPRECATED: selector comma groups
		:without(Stunned)             -- DEPRECATED: selector :not(...)
		:withAttribute("Team", "Red") -- DEPRECATED: [$Team = "Red"]
		:withProperty("Anchored", false) -- DEPRECATED: [Anchored = false]
		:where(function(instance)     -- arbitrary predicate (permanent)
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

	`Query.Selector(str, root?)` is the composable node form of the dialect.
	`Query.Attr` / `Query.Prop` remain for what strings cannot express —
	**function matchers** with per-name change re-evaluation:

	```lua
	Component.query(Enemy):with(Query.Attr("Level", function(_, v)
		return typeof(v) == "number" and v % 5 == 0
	end))
	```

	(`Query.And` / `Query.Or` / `Query.Not` / `Query.Pred` still exist at
	runtime but are internal IR now — the dialect's compounds, commas, and
	`:not(...)` are their public spelling, and `:where` covers `Pred`.)

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
