--!strict
-- Type surface for the Query engine (see the `@class Query` doc in `init.luau`).
-- A leaf: declares every public and internal Query type in one place so the
-- Build / Plan / Runtime submodules share a single definition of each (identity
-- can never diverge). Public types are re-exported from `init.luau`.
-- Authors: Logan Hunt [Raildex]

const Packages = script.Parent.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)

export type Janitor = Janitor.Janitor

-- Minimal structural view of a component class and its instances (see
-- `ComponentClass` / `TypedClass` in `init.luau`); declared here so real
-- classes are subtypes without a cyclic require of `init.luau`. Props are
-- `read` (covariant) and the class API is self-generic, matching the real
-- types, so both class variants satisfy this view.
export type ComponentLike = { read Instance: Instance }
export type ComponentClassLike = {
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
export type ConnectionLike = { Disconnect: (self: ConnectionLike) -> () }

-- Connect-only view a class's Started/Stopped signal is cast to.
export type ClassSignalView = {
	Connect: (self: ClassSignalView, fn: (ComponentLike) -> ()) -> ConnectionLike,
}

-- Connect-only view a `:where` recheck signal is duck-cast to; accepts any
-- signal-like value (better-signal, RBXScriptSignal, ...) with `:Connect`.
export type RecheckSignalView = {
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
export type SatisfiedFn = (QueryInternal, Instance) -> boolean

-- Unified attribute/property clause used by BOTH the fast-path lists
-- (`_attributes` / `_properties`) and compiled attr/prop nodes. `exists`
-- short-circuits to an existence check (0-matcher form); otherwise match =
-- value satisfies ANY matcher (any-of). The list may legitimately hold `nil`
-- matchers ("value == nil"), so `count` (table.pack's `n`) sizes it, never `#`.
export type MatchSpec = {
	name: string,
	exists: boolean,
	matchers: { Matcher },
	count: number,
}

-- One `:where` requirement; `signal` is duck-cast to `RecheckSignalView` when
-- the engine activates.
export type PredicateRequirement = {
	fn: (Instance) -> boolean,
	signal: RecheckSignal?,
}

export type Observer = {
	callback: (Instance, Janitor) -> (),
	janitors: { [Instance]: Janitor },
	-- `observeUnyielding` observers run their callback inline (no per-match
	-- thread) and must neither yield nor error; a violation is reported loudly.
	unyielding: boolean,
}

export type ChangedSignal = Signal.Signal<(Instance, boolean) -> (), Instance, boolean>

-- One requirement, compiled: its kind resolved once and, for component classes,
-- the class's live started sparse set captured directly (see
-- `Keys.ClassInternal`). Checking a class requirement per candidate is then a
-- SINGLE table lookup — membership in `startedMap` IS "started" — and
-- `startedList` gives `get()` an O(1)-sized, already-filtered seed source.
export type PlanReq = {
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
export type Plan = {
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
export type Engine = {
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

export type QueryInternal = Query & {
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

return {}
