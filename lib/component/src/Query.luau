--!strict
-- World-level component query engine.
-- Authors: Logan Hunt [Raildex]
--[=[
	@class Query
	@ignore

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

const CollectionService = game:GetService("CollectionService")

const Packages = script.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)

const Keys = require(script.Parent.Keys)

type Janitor = Janitor.Janitor

-- Minimal structural view of a component class and its instances (see
-- `ComponentClass` / `TypedClass` in `init.luau`); declared here so real
-- classes are subtypes without a cyclic require of `init.luau`. Props are
-- `read` (covariant) and the class API is self-generic, matching the real
-- types, so both class variants satisfy this view.
type ComponentLike = { read Instance: Instance }
type ComponentClassLike = {
	read Tag: string,
	read Instance: Instance,
	-- `unknown`, not a structural signal type: `Signal`'s generics are
	-- invariant (via `Fire`), so no one signal type accepts every class's
	-- signal. Cast to `ClassSignalView` at the connect site.
	read Started: unknown,
	read Stopped: unknown,
	read FromInstance: <T>(self: T, instance: Instance) -> T?,
	read GetAll: <T>(self: T) -> { T },
}

-- Runtime connection shape shared by better-signal and RBXScriptSignal.
type ConnectionLike = { Disconnect: (self: ConnectionLike) -> () }

-- Connect-only view a class's Started/Stopped signal is cast to.
type ClassSignalView = {
	Connect: (self: ClassSignalView, fn: (ComponentLike) -> ()) -> ConnectionLike,
}

-- Connect-only view a `:where` recheck signal is duck-cast to; accepts any
-- signal-like value (better-signal, RBXScriptSignal, ...) with `:Connect`.
type RecheckSignalView = {
	Connect: (self: RecheckSignalView, fn: () -> ()) -> ConnectionLike,
}

-- A single matcher for an attribute/property value: either a value the value
-- must EQUAL, or a predicate `(instance, value) -> boolean`. `unknown` because a
-- value can be anything; the predicate case is duck-detected via `type == "function"`.
export type Matcher = unknown

-- Caller-owned signal that forces a re-evaluation of all bounded instances when
-- fired. Structural so it accepts both better-signal `Signal` and RBXScriptSignal.
export type RecheckSignal = {
	Connect: (self: RecheckSignal, callback: () -> ()) -> { Disconnect: (self: any) -> () },
}

-- ── Composable nodes ─────────────────────────────────────────────────────────
-- A Filter is a leaf refinement: it tests ONE instance and contributes NO
-- candidate source, so it is valid only nested inside a bounded query (via
-- with / withAny / without / a combinator), never as a query's sole bound.
-- Built by Query.Attr / Query.Prop / Query.Pred; never constructed by hand.
export type Filter = {
	_node: "filter",
	op: "attr" | "prop" | "where",
	name: string?, -- attr / prop
	-- attr/prop: the compiled MatchSpec (existence flag + packed any-of matcher
	-- list; explicit `nil` matchers survive via table.pack). Opaque to users.
	spec: unknown?,
	fn: ((instance: Instance) -> boolean)?, -- where
	signal: RecheckSignal?, -- where: optional recheck
}

-- A Combinator composes child Queryables under a boolean operator. `not`, and
-- an `or` with any unbounded child, are refinement-only; `and` is bounded when
-- any child is (see the boundedness rules in `_validate`). Built by
-- Query.And / Query.Or / Query.Not.
export type Combinator = {
	_node: "combinator",
	op: "not" | "or" | "and",
	children: { Queryable },
}

-- Compose-BY-REFERENCE marker: `Query.Sub(q)` keeps `q` as a live nested
-- sub-query (own reactive engine, shared by every parent referencing an
-- equivalent shape) instead of lowering its clauses into the parent. A raw
-- `Query` passed anywhere composes BY VALUE (its clauses are spliced/lowered
-- at build time); `Sub` is the only spelling that nests.
export type Sub = {
	_node: "sub",
	query: Query,
}

export type Queryable = ComponentClassLike | string | Query | Filter | Combinator | Sub

--[=[
	@interface QueryConnection
	@within Query
	.IsConnected boolean
	.Disconnect () -> ()
	.Destroy () -> ()
	Returned by [Query:observe].
]=]
export type QueryConnection = {
	IsConnected: boolean,
	Disconnect: () -> (),
	Destroy: () -> (),
}

export type Query = {
	with: (self: Query, ...Queryable) -> Query,
	withAny: (self: Query, ...Queryable) -> Query,
	without: (self: Query, ...Queryable) -> Query,
	withAttribute: (self: Query, name: string, ...Matcher) -> Query,
	withProperty: (self: Query, name: string, ...Matcher) -> Query,
	where: (self: Query, predicate: (Instance) -> boolean, recheckSignal: RecheckSignal?) -> Query,
	observe: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
	observeUnyielding: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
	track: (self: Query) -> QueryConnection,
	get: (self: Query) -> { Instance },
	iter: (self: Query) -> () -> Instance?,
	contains: (self: Query, instance: Instance) -> boolean,
	count: (self: Query) -> number,
	first: (self: Query) -> Instance?,
}

-- satisfiedFn(query, instance): is `instance` currently matching `query`?
-- Supplied by caller so the same predicate logic serves both the reactive
-- engine (sub-query engines) and the one-shot GetMatches (static membership).
type SatisfiedFn = (QueryInternal, Instance) -> boolean

-- Unified attribute/property clause used by BOTH the fast-path lists
-- (`_attributes` / `_properties`) and compiled attr/prop nodes. `exists`
-- short-circuits to an existence check (0-matcher form); otherwise match =
-- value satisfies ANY matcher (any-of). The list may legitimately hold `nil`
-- matchers ("value == nil"), so `count` (table.pack's `n`) sizes it, never `#`.
type MatchSpec = {
	name: string,
	exists: boolean,
	matchers: { Matcher },
	count: number,
}

-- One `:where` requirement; `signal` is duck-cast to `RecheckSignalView` when
-- the engine activates.
type PredicateRequirement = {
	fn: (Instance) -> boolean,
	signal: RecheckSignal?,
}

type Observer = {
	callback: (Instance, Janitor) -> (),
	janitors: { [Instance]: Janitor },
	-- `observeUnyielding` observers run their callback inline (no per-match
	-- thread) and must neither yield nor error; a violation is reported loudly.
	unyielding: boolean,
}

type ChangedSignal = Signal.Signal<(Instance, boolean) -> (), Instance, boolean>

-- One requirement, compiled: its kind resolved once and, for component classes,
-- the class's live started sparse set captured directly (see
-- `Keys.ClassInternal`). Checking a class requirement per candidate is then a
-- SINGLE table lookup — membership in `startedMap` IS "started" — and
-- `startedList` gives `get()` an O(1)-sized, already-filtered seed source.
type PlanReq = {
	kind: "tag" | "class" | "classlike" | "query" | "attr" | "prop" | "where" | "not" | "or" | "and",
	buildIndex: number, -- declaration position; tiebreak for the stable sort
	tag: string?,
	startedList: { Instance }?, -- class: live dense started-instance array
	startedMap: { [Instance]: number }?, -- class: live instance -> list index
	class: ComponentClassLike?, -- foreign class-like: FromInstance fallback
	query: QueryInternal?,
	spec: MatchSpec?, -- attr / prop node
	fn: ((Instance) -> boolean)?, -- where node
	signal: RecheckSignal?, -- where node
	children: { PlanReq }?, -- not / or / and (compiled recursively)
}

-- The compiled shape of a query: requirement lists as PlanReqs plus presence
-- flags so empty clauses cost nothing per candidate. Cached on the query and
-- rebuilt by `_invalidate` (i.e. on any mutation).
type Plan = {
	required: { PlanReq },
	anyOf: { { PlanReq } },
	negative: { PlanReq },
	hasNegative: boolean,
	hasAttributes: boolean,
	hasProperties: boolean,
	hasPredicates: boolean,
	-- True when any clause references a sub-query; `get()` only builds its
	-- per-call memoization machinery (and a real SatisfiedFn) when it is.
	hasQueryRefs: boolean,
}

-- Reactive state backing an activated query (ref-counted, shared when a query
-- is used more than once).
type Engine = {
	-- Sparse-set pair: `matched[instance]` is its 1-based position in
	-- `matchedList` (the map doubles as the membership set), and `matchedList`
	-- is the dense, insertion-ordered array reads iterate/clone. Removal is a
	-- swap-remove, so both stay O(1) per transition.
	matched: { [Instance]: number },
	matchedList: { Instance },
	changed: ChangedSignal,
	observers: { [Observer]: boolean },
	janitor: Janitor,
	positiveSet: { [Instance]: boolean }, -- [Instance]: true while positively bounded (candidate universe)
	attrConns: { [Instance]: ConnectionLike }, -- one AttributeChanged sub per candidate
	propConns: { [Instance]: { ConnectionLike } }, -- one GetPropertyChangedSignal sub per watched property, per candidate
	subEngines: { [QueryInternal]: Engine },
	-- Interning bookkeeping: the canonical signature this engine is registered
	-- under, total activations across every equivalent query sharing it, and
	-- the queries currently attached (so their `_engine` pointers can be
	-- cleared when the engine dies).
	signature: string,
	refcount: number,
	holders: { [QueryInternal]: boolean },
}

type QueryInternal = Query & {
	_positive: { Queryable },
	_anyOf: { { Queryable } }, -- array of groups
	_negative: { Queryable },
	_attributes: { MatchSpec },
	_properties: { MatchSpec },
	_predicates: { PredicateRequirement },
	_engine: Engine?,
	_refcount: number,
	-- Lazily-built caches. Queries are immutable after construction (builders
	-- copy-on-write), so none of these can ever go stale.
	_validated: boolean,
	_sources: { Queryable }?,
	_planned: Plan?,
	_signatureCache: string?,

	_plan: (self: QueryInternal) -> Plan,
	_signature: (self: QueryInternal) -> string,
	_positiveSources: (self: QueryInternal) -> { Queryable },
	_validate: (self: QueryInternal) -> (),
	_allReferences: (self: QueryInternal) -> { Queryable },
	_positiveCandidate: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_universeCandidate: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_attributesMatch: (self: QueryInternal, instance: Instance) -> boolean,
	_propertiesMatch: (self: QueryInternal, instance: Instance) -> boolean,
	_predicatesPass: (self: QueryInternal, instance: Instance) -> boolean,
	_matchesRest: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_fullMatch: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_activate: (self: QueryInternal) -> Engine,
	_deactivate: (self: QueryInternal) -> (),
	_enumerate: (
		self: QueryInternal,
		reactive: boolean,
		subSets: { [QueryInternal]: { [Instance]: boolean } }?
	) -> { [Instance]: boolean },
	_singleSource: (self: QueryInternal) -> PlanReq?,
	_staticSub: (
		self: QueryInternal,
		plan: Plan
	) -> (SatisfiedFn, ((QueryInternal) -> { [Instance]: boolean })?, { [QueryInternal]: { [Instance]: boolean } }?),
	_collect: (self: QueryInternal, onMatch: (Instance) -> boolean?) -> (),
}

const INTERNAL = Keys.Internal -- hoisted for the plan compiler's class probe

-- Module table: static constructors (`new`, `Attr`, `Prop`, `Pred`, `And`,
-- `Or`, `Not`) plus the instance `prototype`. Made callable (`Query(...)` ==
-- `Query.new(...)`) at the bottom of the file.
const Query = {}
-- Instance methods live on `prototype` (mirrors `Component.prototype`), keeping
-- the static namespace free — `and`/`or`/`not` are reserved words, so combinators
-- must be statics, and statics must not collide with method names.
const prototype = {}
prototype.__index = prototype
Query.prototype = prototype

-- Node prototypes: Filters/Combinators are tagged tables built through these so
-- a later fluent matcher DSL can attach methods without changing representation.
const FilterProto = {}
FilterProto.__index = FilterProto
const ComboProto = {}
ComboProto.__index = ComboProto
const SubProto = {}
SubProto.__index = SubProto

const function isQuery(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == prototype
end

const function isFilter(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == FilterProto
end

const function isCombinator(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == ComboProto
end

const function isSub(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == SubProto
end

const function isComponentClass(value: unknown): boolean
	if type(value) ~= "table" or isQuery(value) or isFilter(value) or isCombinator(value) or isSub(value) then
		return false
	end
	return type((value :: { read Tag: unknown }).Tag) == "string"
end

const function assertQueryable(value: Queryable, method: string)
	if
		type(value) == "string"
		or isQuery(value)
		or isFilter(value)
		or isCombinator(value)
		or isSub(value)
		or isComponentClass(value)
	then
		return
	end
	error(
		`[Component] :{method}() expects a component class, tag string, Query, or Query.Attr/Prop/Pred/And/Or/Not/Sub node`,
		3
	)
end

--[=[
	@within Component
	@function query
	@param ... Queryable -- component classes, tag strings, and/or sub-queries
	@return Query

	Creates a new query whose positional arguments are all required.
]=]
const function rawNew(): QueryInternal
	-- Cast through `any`: without it the solver stamps `@metatable` onto the
	-- table and rejects the internal type (same as TableManager's constructor).
	return (
		setmetatable({
			_positive = {},
			_anyOf = {},
			_negative = {},
			_attributes = {},
			_properties = {},
			_predicates = {},
			_engine = nil,
			_refcount = 0,
			_validated = false,
			_sources = nil,
			_planned = nil,
			_signatureCache = nil,
		}, prototype) :: any
	) :: QueryInternal
end

-- Copy-on-write base for every builder: a fresh query with this one's
-- requirement lists cloned shallowly. The inner entries (anyOf groups,
-- attribute/predicate records) are never mutated after creation, so sharing
-- them is safe. Queries are therefore immutable values: every builder returns
-- a NEW query and the receiver is never changed, so chains branch freely --
-- `qA:with(qB)` and `qA:without(qC)` are independent and `qA` stays `qA`.
const function derive(self: QueryInternal): QueryInternal
	const new = rawNew()
	new._positive = table.clone(self._positive)
	new._anyOf = table.clone(self._anyOf)
	new._negative = table.clone(self._negative)
	new._attributes = table.clone(self._attributes)
	new._properties = table.clone(self._properties)
	new._predicates = table.clone(self._predicates)
	return new
end

-- Packs a variadic matcher list into a MatchSpec. 0 matchers = existence check;
-- otherwise the value must satisfy ANY entry (value-equality, or a predicate
-- `(instance, value) -> boolean`). `table.pack` so explicit `nil` matchers
-- ("value == nil") survive; `select("#")` distinguishes omitted from nil.
const function makeMatchSpec(name: string, ...: Matcher): MatchSpec
	const count = select("#", ...)
	return {
		name = name,
		exists = count == 0,
		matchers = table.pack(...) :: { Matcher },
		count = count,
	}
end

--------------------------------------------------------------------------------
-- Static node constructors (composable Queryables)
--------------------------------------------------------------------------------

--[=[
	@within Query
	@function Attr
	@param name string
	@param ... any -- values and/or `(instance, value) -> boolean` predicates; ANY may match. Omit all for existence.
	@return Filter
	An attribute filter node, usable anywhere a Queryable is accepted
	(`query(...)`, `:with`, `:withAny`, `:without`, or nested in `Query.And/Or/Not`).
	Same matcher semantics as [Query:withAttribute].
]=]
function Query.Attr(name: string, ...: Matcher): Filter
	assert(type(name) == "string", "[Component] Query.Attr() expects an attribute name string")
	const spec = makeMatchSpec(name, ...)
	return (setmetatable({ _node = "filter", op = "attr", name = name, spec = spec }, FilterProto) :: any) :: Filter
end

--[=[
	@within Query
	@function Prop
	@param name string
	@param ... any -- values and/or `(instance, value) -> boolean` predicates; ANY may match. Omit all for existence; explicit `nil` means "== nil".
	@return Filter
	A property filter node. Same matcher semantics as [Query:withProperty].
]=]
function Query.Prop(name: string, ...: Matcher): Filter
	assert(type(name) == "string", "[Component] Query.Prop() expects a property name string")
	const spec = makeMatchSpec(name, ...)
	return (setmetatable({ _node = "filter", op = "prop", name = name, spec = spec }, FilterProto) :: any) :: Filter
end

--[=[
	@within Query
	@function Pred
	@param fn (instance: Instance) -> boolean
	@param recheckSignal RecheckSignal? -- fire to force re-evaluation
	@return Filter
	A predicate filter node. Same semantics (and staleness caveat) as [Query:where].
]=]
function Query.Pred(fn: (Instance) -> boolean, recheckSignal: RecheckSignal?): Filter
	assert(type(fn) == "function", "[Component] Query.Pred() expects a predicate function")
	return (
		setmetatable({ _node = "filter", op = "where", fn = fn, signal = recheckSignal }, FilterProto) :: any
	) :: Filter
end

const function makeCombinator(op: "not" | "or" | "and", method: string, ...: Queryable): Combinator
	const children = { ... }
	assert(#children > 0, `[Component] Query.{method}() expects at least one Queryable`)
	for _, child in children do
		assertQueryable(child, method)
	end
	return (setmetatable({ _node = "combinator", op = op, children = children }, ComboProto) :: any) :: Combinator
end

--[=[
	@within Query
	@function And
	@param ... Queryable
	@return Combinator
	Satisfied when ALL children are. Bounded (usable as a candidate source) when
	any child is bounded.
]=]
function Query.And(...: Queryable): Combinator
	return makeCombinator("and", "And", ...)
end

--[=[
	@within Query
	@function Or
	@param ... Queryable
	@return Combinator
	Satisfied when AT LEAST ONE child is. Bounded only when every child is
	bounded (an unbounded branch would make the candidate set unbounded).
]=]
function Query.Or(...: Queryable): Combinator
	return makeCombinator("or", "Or", ...)
end

--[=[
	@within Query
	@function Not
	@param ... Queryable
	@return Combinator
	Satisfied when NONE of the children are (variadic "none of", mirroring
	[Query:without]). Refinement-only: contributes no candidates.
]=]
function Query.Not(...: Queryable): Combinator
	return makeCombinator("not", "Not", ...)
end

--[=[
	@within Query
	@function Sub
	@param query Query
	@return Sub

	Composes `query` **by reference**: the parent keeps it as a live nested
	sub-query with its own reactive engine (shared with every other parent
	referencing an equivalent shape) instead of lowering its clauses into the
	parent's plan.

	A raw `Query` passed to `query(...)` / `:with` / `:withAny` / `:without`
	composes **by value** — its clauses are spliced (or wrapped as an `And` node
	in `withAny`/`without`) at build time, so `Query(q1):with(B)` is literally
	`q1:with(B)`. Use `Sub` when you specifically want the nested form:
	- the sub-query's clauses are expensive per candidate (heavy `Pred`s, many
	  property reads) and it is shared by many active parents — one shared
	  evaluation instead of per-parent probes;
	- you want the sub-query validated standalone (a `Sub` of an unbounded
	  query errors; a spliced one can be bounded by the parent's other sources);
	- you rely on the sub-query's own evaluation order for side-effectful
	  predicates.
]=]
function Query.Sub(query: Query): Sub
	assert(isQuery(query), "[Component] Query.Sub() expects a Query")
	return (setmetatable({ _node = "sub", query = query }, SubProto) :: any) :: Sub
end

-- Rebuilds a Filter node from an already-packed MatchSpec (the public
-- `Query.Attr`/`Query.Prop` pack fresh varargs; lowering reuses stored specs —
-- they are immutable after creation, so sharing is safe).
const function filterFromSpec(op: "attr" | "prop", spec: MatchSpec): Filter
	return (setmetatable({ _node = "filter", op = op, name = spec.name, spec = spec }, FilterProto) :: any) :: Filter
end

const function predToFilter(pred: PredicateRequirement): Filter
	return (
		setmetatable({ _node = "filter", op = "where", fn = pred.fn, signal = pred.signal }, FilterProto) :: any
	) :: Filter
end

-- Lowers a whole query to a single equivalent node for ATOMIC positions
-- (`withAny` members, `without` entries), where splicing would change meaning
-- (De Morgan): the node is satisfied exactly while the query matches. Positive
-- positions splice instead (see `addPositive`).
const function queryToNode(q: QueryInternal, method: string): Queryable
	const parts: { Queryable } = {}
	for _, req in q._positive do
		table.insert(parts, req)
	end
	for _, group in q._anyOf do
		table.insert(parts, makeCombinator("or", "Or", table.unpack(group)))
	end
	if #q._negative > 0 then
		table.insert(parts, makeCombinator("not", "Not", table.unpack(q._negative)))
	end
	for _, spec in q._attributes do
		table.insert(parts, filterFromSpec("attr", spec))
	end
	for _, spec in q._properties do
		table.insert(parts, filterFromSpec("prop", spec))
	end
	for _, pred in q._predicates do
		table.insert(parts, predToFilter(pred))
	end
	if #parts == 0 then
		error(`[Component] :{method}() cannot compose an empty query (it has no requirements)`, 3)
	end
	if #parts == 1 then
		return parts[1]
	end
	return makeCombinator("and", "And", table.unpack(parts))
end

--------------------------------------------------------------------------------
-- Build-time normalization
--
-- Every requirement is canonicalized as it enters a query, so ONE logical shape
-- has ONE internal form (and therefore one signature, one plan, one interned
-- engine) no matter how it was spelled:
--   with(rawQuery)      == splicing its clauses  (compose by value)
--   with(And(a, b))     == with(a, b)
--   with(Or(a, b))      == withAny(a, b)
--   with(Not(x))        == without(x)
--   with(Attr/Prop/...) == withAttribute / withProperty / where
--   withAny(x)          == with(x)              (a 1-member group is required)
-- `Query.Sub(q)` is the deliberate exception: it composes by REFERENCE and is
-- stored as-is. Normalization happens only here in the builders; stored queries
-- are always already canonical, so splices never recurse.
--------------------------------------------------------------------------------

local normalizeAnyMember: (req: Queryable, method: string) -> Queryable

-- Canonical entry of one requirement into REQUIRED (AND) position.
const function addPositive(new: QueryInternal, req: Queryable, method: string)
	if isQuery(req) then
		-- Compose by value: splice the query's (already canonical) clauses.
		const q = req :: QueryInternal
		for _, entry in q._positive do
			table.insert(new._positive, entry)
		end
		for _, group in q._anyOf do
			table.insert(new._anyOf, group)
		end
		for _, entry in q._negative do
			table.insert(new._negative, entry)
		end
		for _, spec in q._attributes do
			table.insert(new._attributes, spec)
		end
		for _, spec in q._properties do
			table.insert(new._properties, spec)
		end
		for _, pred in q._predicates do
			table.insert(new._predicates, pred)
		end
		return
	end
	if isCombinator(req) then
		const combo = req :: Combinator
		const op = combo.op
		if op == "and" then
			for _, child in combo.children do
				addPositive(new, child, method)
			end
			return
		elseif op == "or" then
			const group: { Queryable } = {}
			for _, child in combo.children do
				table.insert(group, normalizeAnyMember(child, method))
			end
			if #group == 1 then
				addPositive(new, group[1], method)
			else
				table.insert(new._anyOf, group)
			end
			return
		else -- not: required "none of" == excluded
			for _, child in combo.children do
				table.insert(new._negative, normalizeAnyMember(child, method))
			end
			return
		end
	end
	if isFilter(req) then
		const filter = req :: Filter
		const op = filter.op
		if op == "attr" then
			table.insert(new._attributes, filter.spec :: MatchSpec)
		elseif op == "prop" then
			table.insert(new._properties, filter.spec :: MatchSpec)
		else
			table.insert(new._predicates, { fn = filter.fn :: (Instance) -> boolean, signal = filter.signal })
		end
		return
	end
	-- Sub node / class / tag / class-like: a plain required requirement.
	table.insert(new._positive, req)
end

-- Canonical form of one requirement in an ATOMIC position (a `withAny` group
-- member or a `without` entry), where the requirement must stand as a single
-- testable unit: raw queries lower to an equivalent node (De Morgan forbids
-- splicing here); nested single-child wrappers collapse; everything else is
-- kept as-is.
function normalizeAnyMember(req: Queryable, method: string): Queryable
	if isQuery(req) then
		return queryToNode(req :: QueryInternal, method)
	end
	if isCombinator(req) then
		const combo = req :: Combinator
		if #combo.children == 1 and combo.op ~= "not" then
			return normalizeAnyMember(combo.children[1], method)
		end
	end
	return req
end

function Query.new(...: Queryable): Query
	const self = rawNew()
	for _, req in { ... } do
		assertQueryable(req, "with")
		addPositive(self, req, "with")
	end
	return self
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Returns a NEW query with the given required requirements added; the
	receiver is unchanged (builders never mutate, so chains branch freely).
	`query():with(X)` is equivalent to `query(X)`.
]=]
function prototype.with(self: QueryInternal, ...: Queryable): Query
	const new = derive(self)
	for _, req in { ... } do
		assertQueryable(req, "with")
		addPositive(new, req, "with")
	end
	return new
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Returns a NEW query with an "at least one of" group added: the instance
	must satisfy at least one of the given requirements. Multiple `:withAny`
	calls each add an independent group. The receiver is unchanged.
]=]
function prototype.withAny(self: QueryInternal, ...: Queryable): Query
	const raw = { ... }
	if #raw == 0 then
		return self
	end
	const new = derive(self)
	const group: { Queryable } = {}
	for _, req in raw do
		assertQueryable(req, "withAny")
		-- A nested Or is the same disjunction: flatten its members into this
		-- group so `withAny(Or(a, b), c)` == `withAny(a, b, c)`.
		const normalized = normalizeAnyMember(req, "withAny")
		if isCombinator(normalized) and (normalized :: Combinator).op == "or" then
			for _, child in (normalized :: Combinator).children do
				table.insert(group, normalizeAnyMember(child, "withAny"))
			end
		else
			table.insert(group, normalized)
		end
	end
	if #group == 1 then
		-- "At least one of {x}" is just "x": required position.
		addPositive(new, group[1], "withAny")
	else
		table.insert(new._anyOf, group)
	end
	return new
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Returns a NEW query with the given excluded requirements added: the
	instance must satisfy none of them. The receiver is unchanged.
]=]
function prototype.without(self: QueryInternal, ...: Queryable): Query
	const new = derive(self)
	for _, req in { ... } do
		assertQueryable(req, "without")
		table.insert(new._negative, normalizeAnyMember(req, "without"))
	end
	return new
end

--[=[
	@within Query
	@param name string
	@param ... any -- values to equal and/or `(instance, value) -> boolean` predicates; matches if ANY does. Omit all for existence.
	@return Query
	Returns a NEW query that additionally requires an attribute; the receiver
	is unchanged. With no matchers, the attribute must merely exist; otherwise
	the attribute's value must satisfy at least one matcher (equal a value, or a
	predicate returning true). Re-evaluated reactively on attribute change.
]=]
function prototype.withAttribute(self: QueryInternal, name: string, ...: Matcher): Query
	assert(type(name) == "string", "[Component] :withAttribute() expects an attribute name string")
	const new = derive(self)
	table.insert(new._attributes, makeMatchSpec(name, ...))
	return new
end

--[=[
	@within Query
	@param name string
	@param ... any -- values to equal and/or `(instance, value) -> boolean` predicates; matches if ANY does. Omit all for existence.
	@return Query
	Returns a NEW query that additionally requires an Instance property; the
	receiver is unchanged. Re-evaluated reactively when the property changes.

	Matcher forms:
	- **omitted** (`:withProperty("Anchored")`) — the property must merely *exist*
	  on the instance (a candidate whose class lacks it never matches);
	- **explicit `nil`** (`:withProperty("Parent", nil)`) — the property must exist
	  and equal `nil` (e.g. "unparented");
	- **functions** — must return true for `(instance, value)`;
	- **any other value** — the property must equal it;
	- **several matchers** — the value must satisfy at least one.

	Unlike attributes, a property may not exist on every Instance class a query
	spans; a class lacking the named property simply does not match.
]=]
function prototype.withProperty(self: QueryInternal, name: string, ...: Matcher): Query
	assert(type(name) == "string", "[Component] :withProperty() expects a property name string")
	const new = derive(self)
	table.insert(new._properties, makeMatchSpec(name, ...))
	return new
end

--[=[
	@within Query
	@param predicate (instance: Instance) -> boolean
	@param recheckSignal RecheckSignal? -- fire to force re-evaluation
	@return Query

	Returns a NEW query with an arbitrary predicate added; the receiver is
	unchanged. :::caution A predicate has no change signal of its
	own — it is only re-evaluated when another requirement changes, or when the
	optional `recheckSignal` fires. Without one, its result can go stale. :::
]=]
function prototype.where(self: QueryInternal, predicate: (Instance) -> boolean, recheckSignal: RecheckSignal?): Query
	assert(type(predicate) == "function", "[Component] :where() expects a predicate function")
	const new = derive(self)
	table.insert(new._predicates, { fn = predicate, signal = recheckSignal })
	return new
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

-- Flattened positive requirements (positional/:with + every :withAny member).
-- These bound the candidate set; a query with no enumerable one is rejected.
function prototype._positiveSources(self: QueryInternal): { Queryable }
	const cached = self._sources
	if cached then
		return cached
	end
	const sources = {}
	for _, req in self._positive do
		table.insert(sources, req)
	end
	for _, group in self._anyOf do
		for _, req in group do
			table.insert(sources, req)
		end
	end
	self._sources = sources
	return sources
end

-- Whether a requirement can ENUMERATE a finite candidate set: classes, tags,
-- and sub-queries can; filters and `Not` cannot (they only test); an `And` can
-- when any child can (that child's members are a superset of the And's); an
-- `Or` only when every child can (its members are the union of the children's).
const function isEnumerable(req: Queryable): boolean
	if type(req) == "string" or isQuery(req) or isSub(req) then
		return true
	end
	if isFilter(req) then
		return false
	end
	if isCombinator(req) then
		const combo = req :: Combinator
		const op = combo.op
		if op == "not" then
			return false
		elseif op == "and" then
			for _, child in combo.children do
				if isEnumerable(child) then
					return true
				end
			end
			return false
		else -- or
			for _, child in combo.children do
				if not isEnumerable(child) then
					return false
				end
			end
			return true
		end
	end
	return true -- component class / class-like
end

-- DFS over sub-query references; errors on an unbounded query. A query is
-- bounded iff a required requirement is enumerable, or (with no enumerable
-- required requirement) some `withAny` group is enumerable throughout — every
-- match satisfies each group, so a fully-enumerable group's union bounds the
-- candidate set. Cycles are impossible by construction: builders copy-on-write,
-- so a query can only ever reference queries that existed before it did.
function prototype._validate(self: QueryInternal)
	if self._validated then
		return
	end
	local bounded = false
	for _, req in self._positive do
		if isEnumerable(req) then
			bounded = true
			break
		end
	end
	if not bounded then
		for _, group in self._anyOf do
			local groupEnumerable = #group > 0
			for _, req in group do
				if not isEnumerable(req) then
					groupEnumerable = false
					break
				end
			end
			if groupEnumerable then
				bounded = true
				break
			end
		end
	end
	if not bounded then
		error(
			"[Component] Query has no enumerable positive requirement (component / tag / sub-query, "
				.. "or an And/Or of them); filters and Not() only refine — add a bounded source via "
				.. "query(...), :with(), or :withAny() so the candidate set is finite",
			0
		)
	end
	for _, req in self:_allReferences() do
		if isQuery(req) then
			(req :: QueryInternal):_validate()
		end
	end
	self._validated = true
end

-- Every requirement across all clauses (positive, anyOf, negative), flattened:
-- combinators are unwrapped recursively and `Sub` nodes unwrap to their inner
-- Query, so the list holds only leaf requirements (classes, tags, sub-queries,
-- filters). Consumers subscribe / validate / memoize from this without knowing
-- about nesting.
function prototype._allReferences(self: QueryInternal): { Queryable }
	const refs: { Queryable } = {}
	const function add(req: Queryable)
		if isCombinator(req) then
			for _, child in (req :: Combinator).children do
				add(child)
			end
		elseif isSub(req) then
			table.insert(refs, (req :: Sub).query)
		else
			table.insert(refs, req)
		end
	end
	for _, req in self._positive do
		add(req)
	end
	for _, group in self._anyOf do
		for _, req in group do
			add(req)
		end
	end
	for _, req in self._negative do
		add(req)
	end
	return refs
end

--------------------------------------------------------------------------------
-- Satisfaction / matching
--------------------------------------------------------------------------------

-- Probe cost by kind, measured per candidate: a class check is one direct table
-- lookup (~30ns), a sub-query check is a memo/engine hash lookup, a class-like
-- goes through `FromInstance` (~80ns), and a tag check is a `HasTag` C-call
-- (~150ns). Node kinds follow: an attr read is one `GetAttribute` C-call, a prop
-- read a pcall'd index, `where` a user pcall, and combinators recurse into an
-- unknown number of children — probed last. Every compiled list is sorted
-- cheapest-first so per-candidate evaluation short-circuits on the cheap probes;
-- requirement semantics are order-independent, so this is free. `buildIndex`
-- keeps the sort deterministic (`table.sort` is unstable).
const KIND_COST: { [string]: number } = {
	class = 1,
	query = 2,
	classlike = 3,
	tag = 4,
	attr = 5,
	prop = 6,
	where = 7,
	["not"] = 8,
	["or"] = 8,
	["and"] = 8,
}

-- A seed at or below this is narrow enough that hunting for a better one is
-- not worth fetching more tag arrays: remaining probes run at most this many
-- times each.
const TAG_SIZING_EARLY_EXIT = 32

-- `get()` sizes every required tag via `GetTagged` (to pick the narrowest seed
-- and order probes most-selective-first) only when the best class seed exceeds
-- this. Below it the candidate set is already small, and sizing a huge tag
-- would cost an array allocation proportional to its population for at most a
-- few hundred cheap probes of savings.
const TAG_SIZING_MIN_SEED = 200
const function sortBySelectivity(reqs: { PlanReq })
	table.sort(reqs, function(x: PlanReq, y: PlanReq): boolean
		const cx = KIND_COST[x.kind] :: number
		const cy = KIND_COST[y.kind] :: number
		if cx ~= cy then
			return cx < cy
		end
		return x.buildIndex < y.buildIndex
	end)
end

const function compileReq(req: Queryable, buildIndex: number): PlanReq
	if type(req) == "string" then
		return { kind = "tag" :: "tag", buildIndex = buildIndex, tag = req }
	end
	if isSub(req) then
		return { kind = "query" :: "query", buildIndex = buildIndex, query = (req :: Sub).query :: QueryInternal }
	end
	if isQuery(req) then
		-- Defensive: normalization never stores a raw Query, but compile it as a
		-- sub-query rather than misclassifying if one ever slips through.
		return { kind = "query" :: "query", buildIndex = buildIndex, query = req :: QueryInternal }
	end
	if isFilter(req) then
		const filter = req :: Filter
		if filter.op == "where" then
			return { kind = "where" :: "where", buildIndex = buildIndex, fn = filter.fn, signal = filter.signal }
		end
		return {
			kind = (if filter.op == "attr" then "attr" else "prop") :: "attr" | "prop",
			buildIndex = buildIndex,
			spec = filter.spec :: MatchSpec,
		}
	end
	if isCombinator(req) then
		const combo = req :: Combinator
		const children: { PlanReq } = {}
		for index, child in combo.children do
			table.insert(children, compileReq(child, index))
		end
		sortBySelectivity(children)
		return {
			kind = combo.op :: "not" | "or" | "and",
			buildIndex = buildIndex,
			children = children,
		}
	end
	const internal = (req :: any)[INTERNAL]
	if internal then
		-- Our own class: capture its live started sparse set. Both tables are
		-- mutated in place (never replaced) by the lifecycle, so the references
		-- stay valid for the class's whole life; `Destroy` clears them, which
		-- correctly reads as "no matches".
		return {
			kind = "class" :: "class",
			buildIndex = buildIndex,
			startedList = internal.startedList,
			startedMap = internal.startedInstances,
		}
	end
	return { kind = "classlike" :: "classlike", buildIndex = buildIndex, class = req :: ComponentClassLike }
end

-- Evaluates one MatchSpec. `present` is whether the attribute/property exists at
-- all on this instance (attribute: value ~= nil; property: the read didn't
-- throw); `label` names the calling surface for matcher-error warnings. THE
-- single implementation of matcher semantics — the fast-path clause lists and
-- the compiled attr/prop nodes both route here.
const function matchSpecSatisfied(
	instance: Instance,
	present: boolean,
	value: unknown,
	spec: MatchSpec,
	label: string
): boolean
	if spec.exists then
		return present
	end
	if not present then
		return false
	end
	const matchers = spec.matchers
	for i = 1, spec.count do
		const matcher = matchers[i]
		if type(matcher) == "function" then
			const success, result = pcall(matcher :: (Instance, unknown) -> unknown, instance, value)
			if success and result == true then
				return true
			end
			if not success then
				warn(`[Component] Query {label}('{spec.name}') matcher errored: {result}`)
			end
		elseif value == matcher then
			return true
		end
	end
	return false
end

const function attrSatisfies(instance: Instance, spec: MatchSpec): boolean
	const value = instance:GetAttribute(spec.name)
	return matchSpecSatisfied(instance, value ~= nil, value, spec, "Attr")
end

const function propSatisfies(instance: Instance, spec: MatchSpec): boolean
	-- A property missing on this Instance's class throws on read; the pcall
	-- failing IS the "property absent" signal (there is no reflection API for
	-- game code). `present` distinguishes absent from present-but-nil.
	const present, value = pcall(function()
		return (instance :: any)[spec.name]
	end)
	return matchSpecSatisfied(instance, present, if present then value else nil, spec, "Prop")
end

-- Compiled requirement check. `satisfiedFn` is only consulted for sub-query
-- requirements; all other kinds are direct (combinators recurse).
const function reqSatisfied(req: PlanReq, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const kind = req.kind
	if kind == "class" then
		return (req.startedMap :: { [Instance]: number })[instance] ~= nil
	elseif kind == "tag" then
		return CollectionService:HasTag(instance, req.tag :: string)
	elseif kind == "query" then
		return satisfiedFn(req.query :: QueryInternal, instance)
	elseif kind == "attr" then
		return attrSatisfies(instance, req.spec :: MatchSpec)
	elseif kind == "prop" then
		return propSatisfies(instance, req.spec :: MatchSpec)
	elseif kind == "where" then
		const success, result = pcall(req.fn :: (Instance) -> boolean, instance)
		if not success then
			warn(`[Component] Query.Pred() predicate errored: {result}`)
			return false
		end
		return result == true
	elseif kind == "not" then
		for _, child in req.children :: { PlanReq } do
			if reqSatisfied(child, instance, satisfiedFn) then
				return false
			end
		end
		return true
	elseif kind == "or" then
		for _, child in req.children :: { PlanReq } do
			if reqSatisfied(child, instance, satisfiedFn) then
				return true
			end
		end
		return false
	elseif kind == "and" then
		for _, child in req.children :: { PlanReq } do
			if not reqSatisfied(child, instance, satisfiedFn) then
				return false
			end
		end
		return true
	else
		const class = req.class :: ComponentClassLike
		const component = class:FromInstance(instance)
		return component ~= nil and Keys.inst(component).phase == "Started"
	end
end

-- Loose per-requirement check used to track the candidate UNIVERSE: value
-- filters (attr/prop/where) and negations are vacuously TRUE here, so an
-- instance stays tracked (positiveSet membership, attribute/property change
-- subscriptions) while it satisfies the SOURCE requirements alone — a filter
-- that is currently false must not tear down the very subscription that would
-- re-evaluate it when it flips true. The strict check decides actual matching.
const function reqInUniverse(req: PlanReq, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const kind = req.kind
	if kind == "attr" or kind == "prop" or kind == "where" or kind == "not" then
		return true
	elseif kind == "or" then
		for _, child in req.children :: { PlanReq } do
			if reqInUniverse(child, instance, satisfiedFn) then
				return true
			end
		end
		return false
	elseif kind == "and" then
		for _, child in req.children :: { PlanReq } do
			if not reqInUniverse(child, instance, satisfiedFn) then
				return false
			end
		end
		return true
	end
	return reqSatisfied(req, instance, satisfiedFn)
end

-- Placeholder SatisfiedFn for plans with no sub-query requirement: nothing can
-- ever call it (`reqSatisfied` only consults satisfiedFn for "query" kinds).
const function neverSub(_query: QueryInternal, _instance: Instance): boolean
	return false
end

function prototype._plan(self: QueryInternal): Plan
	const cached = self._planned
	if cached then
		return cached
	end
	const required: { PlanReq } = {}
	for index, req in self._positive do
		table.insert(required, compileReq(req, index))
	end
	sortBySelectivity(required)
	const anyOf: { { PlanReq } } = {}
	for _, group in self._anyOf do
		const compiled: { PlanReq } = {}
		for index, req in group do
			table.insert(compiled, compileReq(req, index))
		end
		sortBySelectivity(compiled)
		table.insert(anyOf, compiled)
	end
	const negative: { PlanReq } = {}
	for index, req in self._negative do
		table.insert(negative, compileReq(req, index))
	end
	sortBySelectivity(negative)
	const function anyQueryReq(reqs: { PlanReq }): boolean
		for _, req in reqs do
			if req.kind == "query" then
				return true
			end
			const children = req.children
			if children and anyQueryReq(children) then
				return true
			end
		end
		return false
	end
	local hasQueryRefs = anyQueryReq(required) or anyQueryReq(negative)
	if not hasQueryRefs then
		for _, group in anyOf do
			if anyQueryReq(group) then
				hasQueryRefs = true
				break
			end
		end
	end
	const plan: Plan = {
		required = required,
		anyOf = anyOf,
		negative = negative,
		hasNegative = #negative > 0,
		hasAttributes = #self._attributes > 0,
		hasProperties = #self._properties > 0,
		hasPredicates = #self._predicates > 0,
		hasQueryRefs = hasQueryRefs,
	}
	self._planned = plan
	return plan
end

function prototype._positiveCandidate(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const plan = self:_plan()
	for _, req in plan.required do
		if not reqSatisfied(req, instance, satisfiedFn) then
			return false
		end
	end
	for _, group in plan.anyOf do
		local anySatisfied = false
		for _, req in group do
			if reqSatisfied(req, instance, satisfiedFn) then
				anySatisfied = true
				break
			end
		end
		if not anySatisfied then
			return false
		end
	end
	return true
end

-- Universe (subscription-tracking) variant of `_positiveCandidate`: value
-- filters count as vacuously satisfied (see `reqInUniverse`).
function prototype._universeCandidate(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const plan = self:_plan()
	for _, req in plan.required do
		if not reqInUniverse(req, instance, satisfiedFn) then
			return false
		end
	end
	for _, group in plan.anyOf do
		local anySatisfied = false
		for _, req in group do
			if reqInUniverse(req, instance, satisfiedFn) then
				anySatisfied = true
				break
			end
		end
		if not anySatisfied then
			return false
		end
	end
	return true
end

function prototype._attributesMatch(self: QueryInternal, instance: Instance): boolean
	for _, spec in self._attributes do
		if not attrSatisfies(instance, spec) then
			return false
		end
	end
	return true
end

function prototype._propertiesMatch(self: QueryInternal, instance: Instance): boolean
	for _, spec in self._properties do
		if not propSatisfies(instance, spec) then
			return false
		end
	end
	return true
end

function prototype._predicatesPass(self: QueryInternal, instance: Instance): boolean
	for _, pred in self._predicates do
		const success, result = pcall(pred.fn, instance)
		if not success then
			warn(`[Component] Query :where() predicate errored: {result}`)
			return false
		end
		if result ~= true then
			return false
		end
	end
	return true
end

-- Everything a match requires EXCEPT the positive requirements. Split out so
-- callers that already know `instance` is a positive candidate (the reactive
-- engine, and `get()` over a single-source enumeration) do not pay to prove it
-- twice.
function prototype._matchesRest(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const plan = self:_plan()
	if plan.hasNegative then
		for _, req in plan.negative do
			if reqSatisfied(req, instance, satisfiedFn) then
				return false
			end
		end
	end
	if plan.hasAttributes and not self:_attributesMatch(instance) then
		return false
	end
	if plan.hasProperties and not self:_propertiesMatch(instance) then
		return false
	end
	if plan.hasPredicates and not self:_predicatesPass(instance) then
		return false
	end
	return true
end

function prototype._fullMatch(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	if not self:_positiveCandidate(instance, satisfiedFn) then
		return false
	end
	return self:_matchesRest(instance, satisfiedFn)
end

--------------------------------------------------------------------------------
-- Structural signatures + engine interning
--------------------------------------------------------------------------------

-- Stable ids for non-primitive signature atoms (classes, predicate/matcher
-- functions, recheck signals). Weak keys: a dead class must not leak here.
const signatureIds: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextSignatureId = 0
const function idOf(value: any): string
	const existing = signatureIds[value]
	if existing then
		return tostring(existing)
	end
	nextSignatureId += 1
	signatureIds[value] = nextSignatureId
	return tostring(nextSignatureId)
end

-- Primitive attribute matchers compare by value, so structurally identical
-- `withAttribute("Team", "Red")` clauses from different modules share; function
-- matchers (and predicates) can only share by identity.
const function matcherToken(matcher: unknown): string
	-- An explicit-nil matcher ("value == nil"). `idOf(nil)` would error
	-- (weak-key table keyed by the value), so short-circuit.
	if matcher == nil then
		return "nil"
	end
	const kind = type(matcher)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return kind .. ":" .. tostring(matcher)
	end
	return "f:" .. idOf(matcher)
end

-- Canonical token for one MatchSpec: `*` for existence, else the SORTED any-of
-- matcher tokens (matcher order never matters, so reordered lists share).
const function specToken(spec: MatchSpec): string
	if spec.exists then
		return "*"
	end
	const tokens = {}
	for i = 1, spec.count do
		table.insert(tokens, matcherToken(spec.matchers[i]))
	end
	table.sort(tokens)
	return table.concat(tokens, "/")
end

-- Sorted token lists are deduped so duplicated requirements never split a
-- signature: `query(A, A)` == `query(A)`, and clauses duplicated by splicing
-- two overlapping queries still intern.
const function dedupeSorted(tokens: { string }): { string }
	local write = 0
	local previous: string? = nil
	for _, token in tokens do
		if token ~= previous then
			write += 1
			tokens[write] = token
			previous = token
		end
	end
	for index = #tokens, write + 1, -1 do
		tokens[index] = nil
	end
	return tokens
end

--[[
	Canonical structural signature: requirement order never matters, so
	`query(A, B)` and `query(B, A)` produce the same key. Sub-queries recurse.
	Cached until the query mutates.
]]
function prototype._signature(self: QueryInternal): string
	const cached = self._signatureCache
	if cached then
		return cached
	end
	const function reqToken(req: Queryable): string
		if type(req) == "string" then
			return "t:" .. req
		elseif isSub(req) then
			return "q:(" .. ((req :: Sub).query :: QueryInternal):_signature() .. ")"
		elseif isQuery(req) then
			return "q:(" .. (req :: QueryInternal):_signature() .. ")"
		elseif isFilter(req) then
			const filter = req :: Filter
			if filter.op == "where" then
				return "w:" .. idOf(filter.fn) .. (if filter.signal ~= nil then ">" .. idOf(filter.signal) else "")
			end
			const spec = filter.spec :: MatchSpec
			return (if filter.op == "attr" then "a:" else "p:") .. spec.name .. "=" .. specToken(spec)
		elseif isCombinator(req) then
			-- Child order never matters, so sorted tokens make reordered
			-- combinators (and their whole queries) intern to the same engine.
			const combo = req :: Combinator
			const tokens = {}
			for _, child in combo.children do
				table.insert(tokens, reqToken(child))
			end
			table.sort(tokens)
			dedupeSorted(tokens)
			const op = combo.op
			const sym = if op == "not" then "!" elseif op == "or" then "|" else "&"
			return sym .. "(" .. table.concat(tokens, ",") .. ")"
		end
		return "c:" .. idOf(req)
	end
	const function sortedTokens(reqs: { Queryable }): string
		const tokens = {}
		for _, req in reqs do
			table.insert(tokens, reqToken(req))
		end
		table.sort(tokens)
		dedupeSorted(tokens)
		return table.concat(tokens, ",")
	end
	const groups = {}
	for _, group in self._anyOf do
		table.insert(groups, sortedTokens(group))
	end
	table.sort(groups)
	dedupeSorted(groups)
	const attrs = {}
	for _, attr in self._attributes do
		table.insert(attrs, attr.name .. "=" .. specToken(attr))
	end
	table.sort(attrs)
	dedupeSorted(attrs)
	const props = {}
	for _, prop in self._properties do
		table.insert(props, prop.name .. "=" .. specToken(prop))
	end
	table.sort(props)
	dedupeSorted(props)
	const preds = {}
	for _, pred in self._predicates do
		table.insert(preds, idOf(pred.fn) .. (if pred.signal ~= nil then ">" .. idOf(pred.signal) else ""))
	end
	table.sort(preds)
	dedupeSorted(preds)
	const signature = sortedTokens(self._positive)
		.. "|"
		.. table.concat(groups, ";")
		.. "|"
		.. sortedTokens(self._negative)
		.. "|"
		.. table.concat(attrs, ",")
		.. "|"
		.. table.concat(props, ",")
		.. "|"
		.. table.concat(preds, ",")
	self._signatureCache = signature
	return signature
end

-- Live engines interned by signature: equivalent queries observed anywhere in
-- the process share ONE engine (one set of subscriptions, one matched set, one
-- re-evaluation per event) instead of each maintaining their own.
const activeEngines: { [string]: Engine } = {}
-- Loudly reports a broken `observeUnyielding` contract WITHOUT unwinding the
-- caller. It is raised on a fresh thread (`task.spawn`) so it surfaces as a red
-- error with a traceback rather than a swallowed warn or an exception that would
-- unwind the engine mid-transition — unwinding there corrupts the shared match
-- set for every observer, i.e. causes the very cross-iteration damage the
-- message warns about. `yieldedThread` is the suspended coroutine for a yield;
-- otherwise `err` carries the caught error.
const function reportUnyieldingViolation(yieldedThread: thread?, err: any)
	local message: string
	if yieldedThread then
		-- Suspended at the yield point; its traceback shows exactly where. The
		-- coroutine is abandoned — a callback that broke the contract does not
		-- get to finish, and any matches after it in a batch do not dispatch.
		const where = debug.traceback(yieldedThread, "unyielding observer callback yielded")
		message =
			`[Component] Query:observeUnyielding() callback YIELDED — it must run to completion synchronously; yielding here abandons the callback and skips the rest of this dispatch, and may affect other observers reacting to the same change:\n{where}`
	else
		message =
			`[Component] Query:observeUnyielding() callback errored — it ran inline, so this throw may have affected other observers reacting to the same change: {tostring(
				err
			)}`
	end
	task.spawn(function()
		error(message, 0)
	end)
end

-- Runs one observer's match callback for `instance`. A yield-tolerant observer
-- (`observe`) spawns a thread, so a callback that yields simply parks harmlessly
-- and never blocks the dispatch. An unyielding observer (`observeUnyielding`)
-- runs it inline in a throwaway coroutine and resumes once: an error or a yield
-- is a broken contract, reported loudly (see `reportUnyieldingViolation`).
const function dispatchMatch(obs: Observer, instance: Instance, janitor: Janitor)
	if not obs.unyielding then
		task.spawn(obs.callback, instance, janitor)
		return
	end
	const thread = coroutine.create(obs.callback)
	const ok, err = coroutine.resume(thread, instance, janitor)
	if ok and coroutine.status(thread) == "dead" then
		return
	end
	reportUnyieldingViolation(if ok then thread else nil, err)
end

-- Fires one unyielding observer's callback across MANY instances (its already-
-- matched set at subscribe time) under a SINGLE coroutine, checked once. This is
-- the amortized form of `dispatchMatch`: the yield-detector is a property of the
-- thread, so wrapping the whole loop pays for one `coroutine.create` instead of
-- one per instance (the seed loop was the only place a lone callback ran N
-- times). Each call is still `pcall`-isolated so one erroring match neither
-- aborts the rest nor escapes; a YIELD, though, suspends the shared coroutine
-- and abandons every remaining match in the batch — acceptable because yielding
-- already broke the contract, and it is reported loudly.
const function dispatchSeedUnyielding(obs: Observer, instances: { Instance })
	const callback = obs.callback
	const janitors = obs.janitors
	const thread = coroutine.create(function()
		for _, instance in instances do
			const matchJanitor = Janitor.new()
			janitors[instance] = matchJanitor
			const ok, err = pcall(callback, instance, matchJanitor)
			if not ok then
				reportUnyieldingViolation(nil, err)
			end
		end
	end)
	coroutine.resume(thread)
	-- Errors are caught inside; only an (unexpected) escape or a yield leaves the
	-- coroutine alive.
	if coroutine.status(thread) ~= "dead" then
		reportUnyieldingViolation(thread, nil)
	end
end

--------------------------------------------------------------------------------
-- Reactive engine (ref-counted; shared across all structurally equal queries)
--------------------------------------------------------------------------------

function prototype._activate(self: QueryInternal): Engine
	self._refcount += 1
	const attached = self._engine
	if attached then
		attached.refcount += 1
		return attached
	end

	-- An equivalent query may already maintain this exact engine.
	const signature = self:_signature()
	const interned = activeEngines[signature]
	if interned then
		interned.refcount += 1
		interned.holders[self] = true
		self._engine = interned
		return interned
	end

	const janitor = Janitor.new()
	-- Cast through `unknown`: `Signal.new()` has no inference source for its
	-- `Function` generic, and Signal's invariant generics reject a direct cast.
	const changed = (Signal.new() :: unknown) :: ChangedSignal
	janitor:Add(changed, "Destroy")
	const engine: Engine = {
		matched = {},
		matchedList = {},
		changed = changed,
		observers = {},
		janitor = janitor,
		positiveSet = {},
		attrConns = {},
		propConns = {},
		subEngines = {},
		signature = signature,
		refcount = 1,
		holders = {},
	}
	engine.holders[self] = true
	activeEngines[signature] = engine
	self._engine = engine
	janitor:Add(function()
		for _, conn in engine.attrConns do
			conn:Disconnect()
		end
		table.clear(engine.attrConns)
		for _, conns in engine.propConns do
			for _, conn in conns do
				conn:Disconnect()
			end
		end
		table.clear(engine.propConns)
	end)

	const function subMatches(subQuery: QueryInternal, instance: Instance): boolean
		const subEngine = engine.subEngines[subQuery]
		return subEngine ~= nil and subEngine.matched[instance] ~= nil
	end

	-- One `AttributeChanged` connection per candidate, filtered by name, instead
	-- of a Janitor plus a `GetAttributeChangedSignal` connection per attribute:
	-- activation over a large candidate set was dominated by that allocation.
	-- Watched names come from the chain-method lists AND from every attr/prop
	-- filter node anywhere in the requirement tree (`_allReferences` flattens
	-- combinator nesting).
	local hasAttributes = #self._attributes > 0
	const watchedAttributes: { [string]: boolean } = {}
	for _, attr in self._attributes do
		watchedAttributes[attr.name] = true
	end

	-- Properties have no single "any property changed" signal, so each watched
	-- property gets its own `GetPropertyChangedSignal` connection per candidate.
	local hasProperties = #self._properties > 0
	const watchedProperties: { [string]: boolean } = {}
	for _, prop in self._properties do
		watchedProperties[prop.name] = true
	end

	const allReferences = self:_allReferences()
	for _, req in allReferences do
		if isFilter(req) then
			const filter = req :: Filter
			const op = filter.op
			if op == "attr" then
				hasAttributes = true
				watchedAttributes[filter.name :: string] = true
			elseif op == "prop" then
				hasProperties = true
				watchedProperties[filter.name :: string] = true
			end
		end
	end

	const function reevaluate(instance: Instance?)
		if not instance then
			return
		end
		-- Universe membership (source requirements only) gates tracking and the
		-- attribute/property subscriptions: a filter that is currently FALSE must
		-- not tear down the very subscription that would re-evaluate it when it
		-- flips true. Full positive candidacy (filters included) gates matching.
		const positive = self:_universeCandidate(instance, subMatches)
		if positive then
			engine.positiveSet[instance] = true
			if hasAttributes and not engine.attrConns[instance] then
				engine.attrConns[instance] = instance.AttributeChanged:Connect(function(attrName)
					if watchedAttributes[attrName] then
						reevaluate(instance)
					end
				end) :: any
			end
			if hasProperties and not engine.propConns[instance] then
				const conns: { ConnectionLike } = {}
				for name in watchedProperties do
					-- `GetPropertyChangedSignal` throws for a property this Instance's
					-- class lacks; such a candidate simply never gets a sub (and the
					-- pcall read in `_propertiesMatch` already reports it absent).
					const ok, signal = pcall(function()
						return instance:GetPropertyChangedSignal(name)
					end)
					if ok then
						table.insert(
							conns,
							signal:Connect(function()
								reevaluate(instance)
							end) :: any
						)
					end
				end
				engine.propConns[instance] = conns
			end
		else
			engine.positiveSet[instance] = nil
			const attrConn = engine.attrConns[instance]
			if attrConn then
				engine.attrConns[instance] = nil
				attrConn:Disconnect()
			end
			const propConns = engine.propConns[instance]
			if propConns then
				engine.propConns[instance] = nil
				for _, conn in propConns do
					conn:Disconnect()
				end
			end
		end

		const isMatch = positive
			and self:_positiveCandidate(instance, subMatches)
			and self:_matchesRest(instance, subMatches)
		const wasMatch = engine.matched[instance] ~= nil
		if isMatch == wasMatch then
			return
		end

		const matchedList = engine.matchedList
		if isMatch then
			const n = #matchedList + 1
			matchedList[n] = instance
			engine.matched[instance] = n
			for obs in engine.observers do
				const matchJanitor = Janitor.new()
				obs.janitors[instance] = matchJanitor
				dispatchMatch(obs, instance, matchJanitor)
			end
		else
			-- Swap-remove: move the tail into the vacated slot. When the
			-- instance IS the tail, the reassignments are harmless no-ops.
			const index = engine.matched[instance] :: number
			const lastIndex = #matchedList
			const last = matchedList[lastIndex]
			matchedList[index] = last
			engine.matched[last] = index
			matchedList[lastIndex] = nil
			engine.matched[instance] = nil
			for obs in engine.observers do
				const matchJanitor = obs.janitors[instance]
				if matchJanitor then
					obs.janitors[instance] = nil
					matchJanitor:Destroy()
				end
			end
		end
		engine.changed:Fire(instance, isMatch)
	end

	-- Subscribe to every referenced input so a change re-evaluates the instance.
	const connectedClasses: { [ComponentClassLike]: boolean } = {}
	const connectedTags: { [string]: boolean } = {}
	const function subscribeRef(req: Queryable)
		if isFilter(req) then
			-- Attr/prop names already fed the watched sets above; a `where` node's
			-- recheck signal is connected with the chain predicates below.
			return
		end
		if type(req) == "string" then
			if connectedTags[req] then
				return
			end
			connectedTags[req] = true
			janitor:Add(CollectionService:GetInstanceAddedSignal(req):Connect(reevaluate), "Disconnect")
			janitor:Add(CollectionService:GetInstanceRemovedSignal(req):Connect(reevaluate), "Disconnect")
		elseif isQuery(req) then
			const subQuery = req :: QueryInternal
			if engine.subEngines[subQuery] then
				return
			end
			const subEngine = subQuery:_activate()
			engine.subEngines[subQuery] = subEngine
			janitor:Add(function()
				subQuery:_deactivate()
			end)
			janitor:Add(
				subEngine.changed:Connect(function(instance, _isMatch)
					reevaluate(instance)
				end),
				"Disconnect"
			)
		else -- component class
			const class = req :: ComponentClassLike
			if connectedClasses[class] then
				return
			end
			connectedClasses[class] = true
			const started = class.Started :: ClassSignalView
			const stopped = class.Stopped :: ClassSignalView
			janitor:Add(
				started:Connect(function(component)
					reevaluate(component.Instance)
				end),
				"Disconnect"
			)
			janitor:Add(
				stopped:Connect(function(component)
					reevaluate(component.Instance)
				end),
				"Disconnect"
			)
		end
	end

	for _, req in allReferences do
		subscribeRef(req)
	end

	-- `where` recheck signals (chain predicates AND Pred nodes) force a full
	-- re-evaluation of tracked instances.
	-- Deduped by signal identity: the same recheck signal reachable through
	-- several clauses (e.g. one predicate spliced in from two source queries)
	-- must trigger ONE sweep, not one per reference.
	const connectedRechecks: { [any]: boolean } = {}
	const function connectRecheck(signal: unknown)
		if connectedRechecks[signal] then
			return
		end
		connectedRechecks[signal] = true
		const recheck = signal :: RecheckSignalView
		janitor:Add(
			recheck:Connect(function()
				for instance in engine.positiveSet do
					reevaluate(instance)
				end
			end),
			"Disconnect"
		)
	end
	for _, pred in self._predicates do
		if pred.signal ~= nil then
			connectRecheck(pred.signal)
		end
	end
	for _, req in allReferences do
		if isFilter(req) then
			const filter = req :: Filter
			if filter.op == "where" and filter.signal ~= nil then
				connectRecheck(filter.signal)
			end
		end
	end

	-- Seed from the current members of every positive source.
	for instance in self:_enumerate(true) do
		reevaluate(instance)
	end

	return engine
end

function prototype._deactivate(self: QueryInternal)
	const engine = self._engine
	if not engine then
		return
	end
	self._refcount = math.max(0, self._refcount - 1)
	engine.refcount -= 1
	-- Holders stay attached until the engine dies: an attached query keeps
	-- serving `get()` straight from the live match set for free.
	if engine.refcount <= 0 then
		activeEngines[engine.signature] = nil
		for holder in engine.holders do
			holder._engine = nil
			holder._refcount = 0
		end
		table.clear(engine.holders)
		engine.janitor:Destroy()
	end
end

-- Enumerate the candidate universe (union of positive sources). When `reactive`
-- is true, sub-query membership comes from live engines (already activated);
-- otherwise it is computed statically via each sub-query's GetMatches.
function prototype._enumerate(
	self: QueryInternal,
	reactive: boolean,
	subSets: { [QueryInternal]: { [Instance]: boolean } }?
): { [Instance]: boolean }
	const set: { [Instance]: boolean } = {}
	const function addFromRef(req: Queryable)
		if type(req) == "string" then
			for _, instance in CollectionService:GetTagged(req) do
				set[instance] = true
			end
		elseif isSub(req) or isQuery(req) then
			const subQuery = (if isSub(req) then (req :: Sub).query else req) :: QueryInternal
			if reactive then
				const engine = self._engine :: Engine
				const subEngine = engine.subEngines[subQuery]
				if subEngine then
					for _, instance in subEngine.matchedList do
						set[instance] = true
					end
				end
			else
				-- Reuse the caller's per-call memo when there is one, so a nested
				-- sub-query is evaluated once per `get()` rather than per candidate.
				const memo = if subSets then subSets[subQuery] else nil
				if memo then
					for instance in memo do
						set[instance] = true
					end
				else
					for _, instance in subQuery:get() do
						set[instance] = true
					end
				end
			end
		elseif isFilter(req) then
			-- Refinement-only: contributes no candidates.
			return
		elseif isCombinator(req) then
			const combo = req :: Combinator
			const op = combo.op
			if op == "not" then
				return -- exclusion: contributes no candidates
			elseif op == "and" then
				-- Any one enumerable child's members are a superset of the And's
				-- satisfiers, so ONE child bounds it. Prefer the narrowest child
				-- whose population is known O(1) (a class's started list length),
				-- mirroring top-level seed selection; otherwise first enumerable.
				local best: Queryable? = nil
				local bestSize = math.huge
				for _, child in combo.children do
					if isEnumerable(child) then
						local startedList: { Instance }? = nil
						if type(child) == "table" and not isCombinator(child) and not isSub(child) then
							const internal = (child :: any)[INTERNAL] :: any
							if internal ~= nil then
								startedList = internal.startedList
							end
						end
						if startedList ~= nil then
							const size = #startedList
							if size < bestSize then
								best, bestSize = child, size
							end
						elseif best == nil then
							best = child
						end
					end
				end
				if best ~= nil then
					addFromRef(best)
				end
				return
			else -- or: the union of all children (only valid fully enumerable)
				if isEnumerable(req) then
					for _, child in combo.children do
						addFromRef(child)
					end
				end
			end
		else -- component class
			-- One of ours: its started list already holds exactly the instances
			-- this source contributes, pre-filtered. Foreign class-likes fall back
			-- to `GetAll()` + a phase check per component.
			const class = req :: ComponentClassLike
			const internal = (class :: any)[Keys.Internal]
			if internal then
				for _, instance in internal.startedList do
					set[instance] = true
				end
			else
				for _, component in class:GetAll() do
					if Keys.inst(component).phase == "Started" then
						set[component.Instance] = true
					end
				end
			end
		end
	end
	for _, req in self:_positiveSources() do
		addFromRef(req)
	end
	return set
end

--------------------------------------------------------------------------------
-- Public terminals
--------------------------------------------------------------------------------

--[=[
	@within Query
	@param callback (instance: Instance, janitor: Janitor) -> ()
	@return QueryConnection

	Runs `callback` for every instance that currently matches, and for every
	instance that matches later, each with a fresh Janitor cleaned up when that
	instance stops matching. Fetch matched components with `Class:FromInstance`.
	Disconnecting the returned handle destroys all active match janitors and stops
	watching.
]=]
-- Shared body of `observe` / `observeUnyielding`: register an observer, fire it
-- for the current matches, and return a disconnect handle. `unyielding` selects
-- the dispatch strategy (see `dispatchMatch`); `method` names the caller for the
-- assertion message.
const function attachObserver(
	self: QueryInternal,
	callback: (Instance, Janitor) -> (),
	unyielding: boolean,
	method: string
): QueryConnection
	assert(type(callback) == "function", `[Component] Query:{method}() expects a callback function`)
	self:_validate()
	const engine = self:_activate()
	const obs: Observer = { callback = callback, janitors = {}, unyielding = unyielding }
	engine.observers[obs] = true

	-- Fire for instances already matched at subscribe time. Iterate a SNAPSHOT:
	-- under Immediate signal behavior a dispatched callback can synchronously
	-- retag/untag and mutate the live match set mid-loop. Unyielding observers
	-- run the whole snapshot under one coroutine (one yield-check for the batch).
	const snapshot = table.clone(engine.matchedList)
	if unyielding then
		dispatchSeedUnyielding(obs, snapshot)
	else
		for _, instance in snapshot do
			const matchJanitor = Janitor.new()
			obs.janitors[instance] = matchJanitor
			task.spawn(callback, instance, matchJanitor)
		end
	end

	const connProxy = {} :: QueryConnection
	connProxy.IsConnected = true
	function connProxy.Disconnect()
		if not connProxy.IsConnected then
			return
		end
		connProxy.IsConnected = false
		engine.observers[obs] = nil
		for _, matchJanitor in obs.janitors do
			matchJanitor:Destroy()
		end
		table.clear(obs.janitors)
		self:_deactivate()
	end
	connProxy.Destroy = connProxy.Disconnect
	return connProxy
end

function prototype.observe(self: QueryInternal, callback: (Instance, Janitor) -> ()): QueryConnection
	return attachObserver(self, callback, false, "observe")
end

--[=[
	@within Query
	@param callback (instance: Instance, janitor: Janitor) -> ()
	@return QueryConnection

	Like [Query:observe], but each callback runs INLINE on the thread driving the
	match change instead of on its own spawned thread — no per-match thread
	allocation, the fast dispatch path for hot bind/unbind work.

	:::danger The callback must run to completion synchronously. If it **yields**
	or **errors** it is reported loudly (a red error with a traceback) and
	abandoned mid-run; because it shares the dispatch thread, the violation can
	also disrupt the other observers and matches reacting to the same change. Use
	[Query:observe] for any callback that may yield. :::
]=]
function prototype.observeUnyielding(self: QueryInternal, callback: (Instance, Janitor) -> ()): QueryConnection
	return attachObserver(self, callback, true, "observeUnyielding")
end

--[=[
	@within Query
	@return QueryConnection

	Keeps this query's match set maintained for cheap repeated reads, WITHOUT
	running a per-match callback. While tracked, [Query:get] / [Query:iter] /
	[Query:count] / [Query:first] / [Query:contains] all answer from the live
	reactive engine (an O(matches) clone or O(1) lookup) instead of re-enumerating
	the candidate set each call — the read path for an ECS-style system that polls
	a join every frame:

	```lua
	local tracked = Component.query(Physics, Velocity):track()
	game:GetService("RunService").Heartbeat:Connect(function(dt)
		for instance in tracked:iter() do ... end
	end)
	-- when the system shuts down:
	tracked:Disconnect()
	```

	This is [Query:observe] minus the per-match Janitor and callback: it maintains
	the same engine (structurally-equal tracked and observed queries share it), so
	tracking is strictly cheaper than observing when you only need to read. The
	returned handle MUST be disconnected to release the engine — unlike a one-shot
	[Query:get], a tracked query holds live subscriptions until then.
]=]
function prototype.track(self: QueryInternal): QueryConnection
	self:_validate()
	self:_activate()

	const connProxy = {} :: QueryConnection
	connProxy.IsConnected = true
	function connProxy.Disconnect()
		if not connProxy.IsConnected then
			return
		end
		connProxy.IsConnected = false
		self:_deactivate()
	end
	connProxy.Destroy = connProxy.Disconnect
	return connProxy
end

-- The sole positive requirement when the query is the ECS hot shape -- exactly
-- one required SOURCE requirement (class / tag / sub-query / class-like; node
-- kinds are refinements, not dumpable sources) and no anyOf / negative /
-- attribute / property / predicate clause -- so a read can answer straight from
-- that one source. `nil` otherwise.
function prototype._singleSource(self: QueryInternal): PlanReq?
	const plan = self:_plan()
	if
		#plan.required == 1
		and #plan.anyOf == 0
		and not plan.hasNegative
		and not plan.hasAttributes
		and not plan.hasProperties
		and not plan.hasPredicates
	then
		const req = plan.required[1]
		const kind = req.kind
		if kind == "class" or kind == "tag" or kind == "query" or kind == "classlike" then
			return req
		end
	end
	return nil
end

-- Builds the per-call sub-query memoization cold reads use: returns
-- `(satisfiedFn, ensureSet, subSets)`. Each sub-query's match-set is computed
-- ONCE and then answered by lookup (re-running it per candidate is quadratic in
-- nested queries). When the plan references no sub-query, returns the no-op
-- `neverSub` and nils, so callers allocate nothing.
function prototype._staticSub(
	self: QueryInternal,
	plan: Plan
): (SatisfiedFn, ((QueryInternal) -> { [Instance]: boolean })?, {
	[QueryInternal]: { [Instance]: boolean },
}?)
	if not plan.hasQueryRefs then
		return neverSub, nil, nil
	end
	const sets: { [QueryInternal]: { [Instance]: boolean } } = {}
	local sub: SatisfiedFn
	local ensure: (QueryInternal) -> { [Instance]: boolean }
	function ensure(subQuery: QueryInternal): { [Instance]: boolean }
		const existing = sets[subQuery]
		if existing then
			return existing
		end
		-- Seed the entry before recursing so shared sub-queries are computed
		-- exactly once (recursion depth is finite: queries are immutable, so
		-- the reference graph is a DAG by construction).
		const set: { [Instance]: boolean } = {}
		sets[subQuery] = set
		-- Deepest first, so this sub-query's own enumeration finds its
		-- references already memoized.
		for _, req in subQuery:_allReferences() do
			if isQuery(req) then
				ensure(req :: QueryInternal)
			end
		end
		for candidate in subQuery:_enumerate(false, sets) do
			if subQuery:_fullMatch(candidate, sub) then
				set[candidate] = true
			end
		end
		return set
	end
	function sub(subQuery: QueryInternal, instance: Instance): boolean
		return ensure(subQuery)[instance] == true
	end
	for _, req in self:_allReferences() do
		if isQuery(req) then
			ensure(req :: QueryInternal)
		end
	end
	return sub, ensure, sets
end

-- General cold scan (no live engine): resolves the narrowest seed, orders probes
-- most-selective first, and invokes `onMatch(instance)` for every match.
-- `onMatch` may return truthy to STOP the scan early -- how `first()` touches
-- one candidate, not all. The live-engine path and the single-requirement ECS
-- shape are cheaper answers the public terminals handle themselves before
-- falling back here, so this deliberately does NOT special-case them.
function prototype._collect(self: QueryInternal, onMatch: (Instance) -> boolean?)
	const plan = self:_plan()
	const staticSub, ensureSet, subSets = self:_staticSub(plan)
	const required = plan.required
	if #required == 0 then
		-- anyOf-only query: the candidate set genuinely is a union, so build it.
		for instance in self:_enumerate(false, subSets) do
			if self:_fullMatch(instance, staticSub) then
				if onMatch(instance) then
					return
				end
			end
		end
		return
	end

	-- Required requirements intersect, so enumerate ONE of them (the narrowest
	-- we can size cheaply) and check the rest by direct lookup per candidate.
	-- Building the union of every positive source just to intersect it back
	-- down was the dominant cost of joins (measured 12x on a 2-class join).
	-- Preference: smallest class (its array length is O(1)), else first tag,
	-- else first sub-query (its match-set is already memoized), else first
	-- foreign class-like.
	local seed: PlanReq? = nil
	local seedSize = math.huge -- smallest KNOWN population so far
	local firstTag: PlanReq? = nil
	local firstQuery: PlanReq? = nil
	local firstClasslike: PlanReq? = nil
	for _, req in required do
		const kind = req.kind
		if kind == "class" then
			const size = #(req.startedList :: { Instance })
			if size < seedSize then
				seed, seedSize = req, size
			end
		elseif kind == "tag" then
			firstTag = firstTag or req
		elseif kind == "query" then
			firstQuery = firstQuery or req
		elseif kind == "classlike" then
			firstClasslike = firstClasslike or req
		end
	end

	-- Live tag sizing: population is the selectivity signal declaration order
	-- cannot give us. When the candidate set would otherwise be large (or there
	-- is no class seed at all), size every required tag; the narrowest source
	-- seeds regardless of where the user wrote it, and the fetched arrays are
	-- reused for seeding and for probe ordering below.
	local tagSizes: { [PlanReq]: number }? = nil
	local tagArrays: { [PlanReq]: { Instance } }? = nil
	if firstTag and (seed == nil or seedSize > TAG_SIZING_MIN_SEED) then
		const sizes: { [PlanReq]: number } = {}
		const arrays: { [PlanReq]: { Instance } } = {}
		tagSizes, tagArrays = sizes, arrays
		for _, req in required do
			if req.kind == "tag" then
				const instances = CollectionService:GetTagged(req.tag :: string)
				arrays[req] = instances
				const size = #instances
				sizes[req] = size
				if size < seedSize then
					seed, seedSize = req, size
					-- Early exit: the seed is already narrow, so remaining tags
					-- will be probed at most `seedSize` times each -- fetching
					-- their (possibly huge) arrays just to rank them would cost
					-- more than the probes they could save.
					if size <= TAG_SIZING_EARLY_EXIT then
						break
					end
				end
			end
		end
	end
	-- No direct source among the required reqs (they are all filter/combinator
	-- nodes; validation guarantees an enumerable one is nested somewhere): fall
	-- back to the union scan, same as the anyOf-only shape.
	const fallbackSeed = seed or firstTag or firstQuery or firstClasslike
	if not fallbackSeed then
		for instance in self:_enumerate(false, subSets) do
			if self:_fullMatch(instance, staticSub) then
				if onMatch(instance) then
					return
				end
			end
		end
		return
	end
	const chosenSeed: PlanReq = fallbackSeed :: PlanReq
	const seedKind = chosenSeed.kind
	-- Probes = every required requirement except the seed, most-selective-first
	-- when populations are known (smaller population rejects more candidates
	-- sooner, so each later probe runs against fewer survivors). Unknown counts
	-- keep the plan's cheap-kind-first order.
	const probes: { PlanReq } = {}
	for _, req in required do
		if req ~= chosenSeed then
			table.insert(probes, req)
		end
	end
	if tagSizes and #probes > 1 then
		const sizes = tagSizes :: { [PlanReq]: number }
		const function populationOf(req: PlanReq): number
			if req.kind == "class" then
				return #(req.startedList :: { Instance })
			end
			const sized = sizes[req]
			if sized then
				return sized
			end
			return math.huge
		end
		table.sort(probes, function(x: PlanReq, y: PlanReq): boolean
			const px, py = populationOf(x), populationOf(y)
			if px ~= py then
				return px < py
			end
			return x.buildIndex < y.buildIndex
		end)
	end

	-- A sized tag whose probe will run many times is cheaper as a hash set than
	-- as repeated `HasTag` C-calls: one insert (~45ns) buys back every probe
	-- (~150ns -> ~25ns). Convert when the expected probe count (the seed size)
	-- makes the build pay for itself; the fetched array is reused, so this only
	-- ever spends allocations already made for sizing.
	local probeSets: { [PlanReq]: { [Instance]: boolean } }? = nil
	if tagArrays and tagSizes then
		const arrays = tagArrays :: { [PlanReq]: { Instance } }
		const sizes = tagSizes :: { [PlanReq]: number }
		for _, req in probes do
			const instances = arrays[req]
			if instances and seedSize * 3 > (sizes[req] :: number) then
				const set: { [Instance]: boolean } = {}
				for _, instance in instances do
					set[instance] = true
				end
				const outSets = probeSets or {}
				probeSets = outSets
				outSets[req] = set
			end
		end
	end

	-- Checks everything except the seed requirement (the seed's own iteration
	-- already proves it). Rest-checks are inlined here so a candidate costs no
	-- extra method dispatch. Returns whatever `onMatch` returned (truthy = stop).
	const anyOf = plan.anyOf
	const function consider(instance: Instance): boolean?
		for _, req in probes do
			const set = if probeSets then (probeSets :: { [PlanReq]: { [Instance]: boolean } })[req] else nil
			if set then
				if not set[instance] then
					return nil
				end
			elseif not reqSatisfied(req, instance, staticSub) then
				return nil
			end
		end
		for _, group in anyOf do
			local anySatisfied = false
			for _, req in group do
				if reqSatisfied(req, instance, staticSub) then
					anySatisfied = true
					break
				end
			end
			if not anySatisfied then
				return nil
			end
		end
		if plan.hasNegative then
			for _, req in plan.negative do
				if reqSatisfied(req, instance, staticSub) then
					return nil
				end
			end
		end
		if plan.hasAttributes and not self:_attributesMatch(instance) then
			return nil
		end
		if plan.hasProperties and not self:_propertiesMatch(instance) then
			return nil
		end
		if plan.hasPredicates and not self:_predicatesPass(instance) then
			return nil
		end
		return onMatch(instance)
	end

	if seedKind == "class" then
		for _, instance in chosenSeed.startedList :: { Instance } do
			if consider(instance) then
				return
			end
		end
	elseif seedKind == "tag" then
		const seedInstances = if tagArrays then (tagArrays :: { [PlanReq]: { Instance } })[chosenSeed] else nil
		for _, instance in seedInstances or CollectionService:GetTagged(chosenSeed.tag :: string) do
			if consider(instance) then
				return
			end
		end
	elseif seedKind == "query" then
		const ensure = ensureSet :: (QueryInternal) -> { [Instance]: boolean }
		for instance in ensure(chosenSeed.query :: QueryInternal) do
			if consider(instance) then
				return
			end
		end
	else
		for _, component in (chosenSeed.class :: ComponentClassLike):GetAll() do
			if Keys.inst(component).phase == "Started" then
				if consider(component.Instance) then
					return
				end
			end
		end
	end
end

--[=[
	@within Query
	@return { Instance }
	Returns the instances that match right now. A one-shot read: it sets up no
	subscriptions.

	While the query is actively observed (any live [Query:observe] connection),
	the read is served straight from the reactive engine's maintained match set —
	an O(matches) copy, identical to what observers see — making per-frame
	`GetMatches` loops cheap enough for ECS-style iteration.
]=]
function prototype.get(self: QueryInternal): { Instance }
	self:_validate()

	-- Live-engine fast path: the engine already maintains exactly this set.
	-- An engine built by any structurally equal query serves just as well --
	-- borrow it read-only via the intern registry.
	const engine = self._engine or activeEngines[self:_signature()]
	if engine then
		return table.clone(engine.matchedList)
	end

	-- The ECS hot shape — one requirement, nothing else — is a straight dump of
	-- the seed source, before any per-candidate machinery is even allocated.
	const single = self:_singleSource()
	if single then
		const kind = single.kind
		if kind == "class" then
			return table.clone(single.startedList :: { Instance })
		elseif kind == "tag" then
			return CollectionService:GetTagged(single.tag :: string)
		elseif kind == "query" then
			const out: { Instance } = {}
			const _, ensure = self:_staticSub(self:_plan())
			for instance in (ensure :: (QueryInternal) -> { [Instance]: boolean })(single.query :: QueryInternal) do
				table.insert(out, instance)
			end
			return out
		else
			const out: { Instance } = {}
			for _, component in (single.class :: ComponentClassLike):GetAll() do
				if Keys.inst(component).phase == "Started" then
					table.insert(out, component.Instance)
				end
			end
			return out
		end
	end

	const out: { Instance } = {}
	self:_collect(function(instance)
		table.insert(out, instance)
		return nil
	end)
	return out
end
prototype.GetMatches = prototype.get

--[=[
	@within Query
	@param instance Instance
	@return boolean
	Whether `instance` matches this query right now. A membership test, not a
	scan: while the query is actively observed it is an O(1) lookup in the
	reactive engine's match set; cold, it evaluates this one instance against
	every clause (no candidate enumeration).
]=]
function prototype.contains(self: QueryInternal, instance: Instance): boolean
	assert(typeof(instance) == "Instance", "[Component] Query:contains() expects an Instance")
	self:_validate()
	const engine = self._engine or activeEngines[self:_signature()]
	if engine then
		return engine.matched[instance] ~= nil
	end
	const staticSub = self:_staticSub(self:_plan())
	return self:_fullMatch(instance, staticSub)
end

--[=[
	@within Query
	@return number
	How many instances match right now. While the query is actively observed
	this is an O(1) read of the engine's match count; cold it scans without
	building the match array [Query:get] would allocate.
]=]
function prototype.count(self: QueryInternal): number
	self:_validate()
	const engine = self._engine or activeEngines[self:_signature()]
	if engine then
		return #engine.matchedList
	end
	const single = self:_singleSource()
	if single and single.kind == "class" then
		return #(single.startedList :: { Instance })
	end
	local n = 0
	self:_collect(function()
		n += 1
		return nil
	end)
	return n
end

--[=[
	@within Query
	@return Instance?
	One instance that matches right now, or `nil` if none do. While the query is
	actively observed this is an O(1) read of the engine's first match; cold it
	stops at the first matching candidate instead of collecting them all.
]=]
function prototype.first(self: QueryInternal): Instance?
	self:_validate()
	const engine = self._engine or activeEngines[self:_signature()]
	if engine then
		return engine.matchedList[1]
	end
	const single = self:_singleSource()
	if single and single.kind == "class" then
		return (single.startedList :: { Instance })[1]
	end
	local found: Instance? = nil
	self:_collect(function(instance)
		found = instance
		return true
	end)
	return found
end

--[=[
	@within Query
	@return () -> Instance?
	Iterates the instances that match right now, without copying the match set:

	```lua
	for instance in query:iter() do ... end
	```

	While the query is actively observed, this walks the reactive engine's live
	match list directly (newest match first) — the zero-allocation per-frame read
	path; like engine-backed [Query:get] it reflects the reactive view. An
	instance that stops matching mid-iteration is handled (it is simply not
	visited); other match-set mutations made *during* the loop may re-visit an
	already-seen instance. Without a live observer it iterates a fresh
	[Query:get] snapshot.

	Trade-off (measured): the per-element iterator call costs more than
	[Query:get]'s single `table.clone`, so `get()` + a numeric `for` is faster in
	raw throughput; `iter()` is for hot per-frame loops where avoiding the cloned
	array's GC garbage matters more than wall time.
]=]
function prototype.iter(self: QueryInternal): () -> Instance?
	self:_validate()
	const engine = self._engine or activeEngines[self:_signature()]
	-- Backwards, so the engine's swap-remove (which moves an already-visited
	-- tail element into the vacated slot) never skips an unvisited instance.
	const list = if engine then engine.matchedList else self:get()
	local index = #list + 1
	return function(): Instance?
		index -= 1
		return list[index]
	end
end

-- Callable module: `Query(...)` == `Query.new(...)`. Query INSTANCES are
-- unaffected — their metatable is `prototype`; this metatable is the module's.
setmetatable(Query, {
	__call = function(_, ...: Queryable): Query
		return Query.new(...)
	end,
})

return Query
