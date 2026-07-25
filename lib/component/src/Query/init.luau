--!strict
-- World-level component query engine.
-- Authors: Logan Hunt [Raildex]
--[=[
	@class Query

	A reusable, reactive query over tagged instances. Built with
	`Component.query(...)` and refined with chain methods, then either observed
	(`:observe`) or read once (`:get`/`:GetMatches`, `:iter`, `:count`, `:first`,
	`:contains`).

	A *requirement* is a **component class** (satisfied while that component is
	*started* on the instance), a **tag string** (satisfied while the instance has
	the raw CollectionService tag), **another Query** (satisfied while the
	instance matches it), a **filter node** (`Query.Attr` / `Query.Prop` /
	`Query.Pred` — satisfied while the value test passes), or a **combinator
	node** (`Query.And` / `Query.Or` / `Query.Not` — boolean composition of any
	requirements, nesting freely). An instance *matches* while:

	- every positional / `:with` requirement is satisfied,
	- every `:withAny(...)` group has at least one satisfied,
	- no `:without` requirement is satisfied,
	- every `:withAttribute` matches,
	- every `:withProperty` matches, and
	- every `:where` predicate returns true.

	A query must have at least one ENUMERABLE positive requirement (component /
	tag / sub-query — or an `And`/`Or` of them) so its candidate set is bounded;
	filter nodes and `Not` only refine, and a query with no enumerable source
	errors when observed or read.

	## Composition: by value, normalized at build time

	Every requirement is canonicalized as it enters a query, so one logical
	shape has ONE internal form — and therefore one signature, one plan, and one
	interned engine — no matter how it was spelled:

	- `Query(q1):with(B)` is **literally** `q1:with(B)` (a raw `Query` composes
	  by value: its clauses are spliced in positive position, or lowered to an
	  equivalent node in `withAny`/`without`, where the query must stay atomic);
	- `with(Query.And(a, b))` == `with(a, b)`; `with(Query.Or(a, b))` ==
	  `withAny(a, b)`; `with(Query.Not(x))` == `without(x)`;
	- `with(Query.Attr/Prop/Pred(...))` == `withAttribute` / `withProperty` /
	  `where`; duplicated requirements do not split signatures.

	`Query.Sub(q)` is the one deliberate exception: it composes **by
	reference**, keeping `q` as a live nested sub-query with its own (shared)
	reactive engine — see [Query.Sub] for when that is worth it.

	Boolean recipes compose from `And`/`Or`/`Not` (a functionally complete
	basis; variadic `Not(...)` is "none of" — i.e. NOR). E.g. exclusive-or,
	"B or C but not both":

	```lua
	Component.query(A):withAny(B, C):without(Query.And(B, C))
	```

	:::caution Canonicalization can change the ORDER (and short-circuit count)
	in which user predicate functions run relative to the exact spelling used.
	Match results are unaffected; do not rely on side effects inside `Pred` /
	`where` / function matchers. :::

	See the Component `CONTEXT.md` for the glossary and the `README` for examples.
]=]

const Types = require(script.Types)
const Build = require(script.Build)
require(script.Plan) -- attaches validation / plan / matching methods to the shared prototype
require(script.Runtime) -- attaches interning / engine / terminal methods to the shared prototype

export type Matcher = Types.Matcher
export type RecheckSignal = Types.RecheckSignal
export type Filter = Types.Filter
export type Combinator = Types.Combinator
export type Sub = Types.Sub
export type Queryable = Types.Queryable
export type QueryConnection = Types.QueryConnection
export type Query = Types.Query

-- Module table: static constructors (`new`, `Attr`, `Prop`, `Pred`, `And`,
-- `Or`, `Not`, `Sub`) plus the instance `prototype`. Made callable (`Query(...)`
-- == `Query.new(...)`) at the bottom of the file.
const Query = {}
Query.prototype = Build.prototype
Query.new = Build.new
Query.Attr = Build.Attr
Query.Prop = Build.Prop
Query.Pred = Build.Pred
Query.And = Build.And
Query.Or = Build.Or
Query.Not = Build.Not
Query.Sub = Build.Sub

-- Callable module: `Query(...)` == `Query.new(...)`. Query INSTANCES are
-- unaffected — their metatable is `prototype`; this metatable is the module's.
setmetatable(Query, {
	__call = function(_, ...: Queryable): Query
		return Query.new(...)
	end,
})

return Query
