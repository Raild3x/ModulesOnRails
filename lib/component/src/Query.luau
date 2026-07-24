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
	the raw CollectionService tag), or **another Query** (satisfied while the
	instance matches it). An instance *matches* while:

	- every positional / `:with` requirement is satisfied,
	- every `:anyOf(...)` group has at least one satisfied,
	- no `:without` requirement is satisfied,
	- every `:withAttribute` matches,
	- every `:withProperty` matches, and
	- every `:where` predicate returns true.

	A query must have at least one positive requirement (component / tag /
	sub-query in the positional args, `:with`, or `:anyOf`) so its candidate set
	is bounded; a query built only from `:without` / `:withAttribute` /
	`:withProperty` / `:where` errors when observed or read.

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

export type Queryable = ComponentClassLike | string | Query

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
	anyOf: (self: Query, ...Queryable) -> Query,
	without: (self: Query, ...Queryable) -> Query,
	withAttribute: (self: Query, name: string, matcher: unknown?) -> Query,
	withProperty: (self: Query, name: string, matcher: unknown?) -> Query,
	where: (self: Query, predicate: (Instance) -> boolean, recheckSignal: unknown?) -> Query,
	observe: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
	observeUnyielding: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
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

-- One `:withAttribute` requirement. `matcher` is the EXISTS sentinel, a
-- `(value) -> boolean` predicate, or a value the attribute must equal.
type AttributeRequirement = {
	name: string,
	matcher: unknown,
}

-- One `:withProperty` requirement. `matcher` is the EXISTS sentinel (property
-- merely present on the Instance), a `(value) -> boolean` predicate, or a value
-- the property must equal (an explicit `nil` matcher is stored as `nil` and means
-- "property present AND equal to nil"; the omitted form is the EXISTS sentinel).
type PropertyRequirement = {
	name: string,
	matcher: unknown,
}

-- One `:where` requirement; `signal` is duck-cast to `RecheckSignalView` when
-- the engine activates.
type PredicateRequirement = {
	fn: (Instance) -> boolean,
	signal: unknown?,
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
	kind: "tag" | "class" | "classlike" | "query",
	buildIndex: number, -- declaration position; tiebreak for the stable sort
	tag: string?,
	startedList: { Instance }?, -- class: live dense started-instance array
	startedMap: { [Instance]: number }?, -- class: live instance -> list index
	class: ComponentClassLike?, -- foreign class-like: FromInstance fallback
	query: QueryInternal?,
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
	_attributes: { AttributeRequirement },
	_properties: { PropertyRequirement },
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

const EXISTS = newproxy(false) -- sentinel: attribute must merely exist
const INTERNAL = Keys.Internal -- hoisted for the plan compiler's class probe

const Query = {}
Query.__index = Query

const function isQuery(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == Query
end

const function isComponentClass(value: unknown): boolean
	if type(value) ~= "table" or isQuery(value) then
		return false
	end
	return type((value :: { read Tag: unknown }).Tag) == "string"
end

const function assertQueryable(value: Queryable, method: string)
	if type(value) == "string" or isQuery(value) or isComponentClass(value) then
		return
	end
	error(`[Component] :{method}() expects a component class, tag string, or Query`, 3)
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
		}, Query) :: any
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

function Query.new(...: Queryable): Query
	const self = rawNew()
	for _, req in { ... } do
		assertQueryable(req, "with")
		table.insert(self._positive, req)
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
function Query.with(self: QueryInternal, ...: Queryable): Query
	const new = derive(self)
	for _, req in { ... } do
		assertQueryable(req, "with")
		table.insert(new._positive, req)
	end
	return new
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Returns a NEW query with an "at least one of" group added: the instance
	must satisfy at least one of the given requirements. Multiple `:anyOf`
	calls each add an independent group. The receiver is unchanged.
]=]
function Query.anyOf(self: QueryInternal, ...: Queryable): Query
	const group = { ... }
	for _, req in group do
		assertQueryable(req, "anyOf")
	end
	if #group == 0 then
		return self
	end
	const new = derive(self)
	table.insert(new._anyOf, group)
	return new
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Returns a NEW query with the given excluded requirements added: the
	instance must satisfy none of them. The receiver is unchanged.
]=]
function Query.without(self: QueryInternal, ...: Queryable): Query
	const new = derive(self)
	for _, req in { ... } do
		assertQueryable(req, "without")
		table.insert(new._negative, req)
	end
	return new
end

--[=[
	@within Query
	@param name string
	@param matcher any -- a value to equal, a `(value) -> boolean` predicate, or omitted for existence
	@return Query
	Returns a NEW query that additionally requires an attribute; the receiver
	is unchanged. With no matcher, the attribute must merely exist; with a
	function, the function must return true for the attribute's value; otherwise the
	value must equal `matcher`. Re-evaluated reactively on attribute change.
]=]
function Query.withAttribute(self: QueryInternal, name: string, matcher: unknown?): Query
	assert(type(name) == "string", "[Component] :withAttribute() expects an attribute name string")
	const new = derive(self)
	table.insert(new._attributes, {
		name = name,
		matcher = if matcher == nil then EXISTS else matcher,
	})
	return new
end

--[=[
	@within Query
	@param name string
	@param matcher any -- a value to equal, a `(value) -> boolean` predicate, or omitted to require the property merely exists
	@return Query
	Returns a NEW query that additionally requires an Instance property; the
	receiver is unchanged. Re-evaluated reactively when the property changes.

	The matcher is REQUIRED but may be an explicit `nil`:
	- **omitted** (`:withProperty("Anchored")`) — the property must merely *exist*
	  on the instance (a candidate whose class lacks it never matches);
	- **explicit `nil`** (`:withProperty("Parent", nil)`) — the property must exist
	  and equal `nil` (e.g. "unparented");
	- **a function** — it must return true for the property's value;
	- **any other value** — the property must equal `matcher`.

	Unlike attributes, a property may not exist on every Instance class a query
	spans; a class lacking the named property simply does not match.
]=]
function Query.withProperty(self: QueryInternal, name: string, ...: unknown): Query
	assert(type(name) == "string", "[Component] :withProperty() expects a property name string")
	const new = derive(self)
	-- Omitted matcher (void) = existence check via the EXISTS sentinel; an EXPLICIT
	-- `nil` is a real matcher meaning "property == nil". `select("#")` (arg count)
	-- distinguishes the two, which `matcher == nil` cannot.
	const matcher = if select("#", ...) == 0 then EXISTS else (...)
	table.insert(new._properties, { name = name, matcher = matcher })
	return new
end

--[=[
	@within Query
	@param predicate (instance: Instance) -> boolean
	@param recheckSignal Signal? -- fire to force re-evaluation
	@return Query

	Returns a NEW query with an arbitrary predicate added; the receiver is
	unchanged. :::caution A predicate has no change signal of its
	own — it is only re-evaluated when another requirement changes, or when the
	optional `recheckSignal` fires. Without one, its result can go stale. :::
]=]
function Query.where(self: QueryInternal, predicate: (Instance) -> boolean, recheckSignal: unknown?): Query
	assert(type(predicate) == "function", "[Component] :where() expects a predicate function")
	const new = derive(self)
	table.insert(new._predicates, { fn = predicate, signal = recheckSignal })
	return new
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

-- Flattened positive requirements (positional/:with + every :anyOf member).
-- These bound the candidate set; a query with none is unbounded and rejected.
function Query._positiveSources(self: QueryInternal): { Queryable }
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

-- DFS over sub-query references; errors on an empty query. Cycles are
-- impossible by construction: builders copy-on-write, so a query can only ever
-- reference queries that existed before it did.
function Query._validate(self: QueryInternal)
	if self._validated then
		return
	end
	const sources = self:_positiveSources()
	if #sources == 0 then
		error(
			"[Component] Query has no positive requirement (component / tag / sub-query); "
				.. "add one via query(...), :with(), or :anyOf() so its candidate set is bounded",
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

-- Every requirement across all clauses (positive, anyOf, negative).
function Query._allReferences(self: QueryInternal): { Queryable }
	const refs = {}
	for _, req in self._positive do
		table.insert(refs, req)
	end
	for _, group in self._anyOf do
		for _, req in group do
			table.insert(refs, req)
		end
	end
	for _, req in self._negative do
		table.insert(refs, req)
	end
	return refs
end

--------------------------------------------------------------------------------
-- Satisfaction / matching
--------------------------------------------------------------------------------

const function compileReq(req: Queryable, buildIndex: number): PlanReq
	if type(req) == "string" then
		return { kind = "tag" :: "tag", buildIndex = buildIndex, tag = req }
	end
	if isQuery(req) then
		return { kind = "query" :: "query", buildIndex = buildIndex, query = req :: QueryInternal }
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

-- Probe cost by kind, measured per candidate: a class check is one direct table
-- lookup (~30ns), a sub-query check is a memo/engine hash lookup, a class-like
-- goes through `FromInstance` (~80ns), and a tag check is a `HasTag` C-call
-- (~150ns). Every compiled list is sorted cheapest-first so per-candidate
-- evaluation short-circuits on the cheap probes; requirement semantics are
-- order-independent, so this is free. `buildIndex` keeps the sort deterministic
-- (`table.sort` is unstable).
const KIND_COST: { [string]: number } = { class = 1, query = 2, classlike = 3, tag = 4 }

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

-- Compiled requirement check. `satisfiedFn` is only consulted for sub-query
-- requirements; tag/class checks are direct.
const function reqSatisfied(req: PlanReq, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	const kind = req.kind
	if kind == "class" then
		return (req.startedMap :: { [Instance]: number })[instance] ~= nil
	elseif kind == "tag" then
		return CollectionService:HasTag(instance, req.tag :: string)
	elseif kind == "query" then
		return satisfiedFn(req.query :: QueryInternal, instance)
	else
		const class = req.class :: ComponentClassLike
		const component = class:FromInstance(instance)
		return component ~= nil and Keys.inst(component).phase == "Started"
	end
end

-- Placeholder SatisfiedFn for plans with no sub-query requirement: nothing can
-- ever call it (`reqSatisfied` only consults satisfiedFn for "query" kinds).
const function neverSub(_query: QueryInternal, _instance: Instance): boolean
	return false
end

function Query._plan(self: QueryInternal): Plan
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

function Query._positiveCandidate(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
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

function Query._attributesMatch(self: QueryInternal, instance: Instance): boolean
	for _, attr in self._attributes do
		const value = instance:GetAttribute(attr.name)
		const matcher = attr.matcher
		local ok: boolean
		if matcher == EXISTS then
			ok = value ~= nil
		elseif type(matcher) == "function" then
			const success, result = pcall(matcher :: (unknown) -> unknown, value)
			ok = success and result == true
			if not success then
				warn(`[Component] Query :withAttribute('{attr.name}') matcher errored: {result}`)
			end
		else
			ok = value == matcher
		end
		if not ok then
			return false
		end
	end
	return true
end

function Query._propertiesMatch(self: QueryInternal, instance: Instance): boolean
	for _, prop in self._properties do
		-- A property missing on this Instance's class throws on read; the pcall
		-- failing IS the "property absent" signal (there is no reflection API for
		-- game code). `exists` distinguishes absent from present-but-nil.
		const exists, value = pcall(function()
			return (instance :: any)[prop.name]
		end)
		const matcher = prop.matcher
		local ok: boolean
		if matcher == EXISTS then
			ok = exists
		elseif not exists then
			ok = false
		elseif type(matcher) == "function" then
			const success, result = pcall(matcher :: (unknown) -> unknown, value)
			ok = success and result == true
			if not success then
				warn(`[Component] Query :withProperty('{prop.name}') matcher errored: {result}`)
			end
		else
			ok = value == matcher
		end
		if not ok then
			return false
		end
	end
	return true
end

function Query._predicatesPass(self: QueryInternal, instance: Instance): boolean
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
function Query._matchesRest(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
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

function Query._fullMatch(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
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
	if matcher == EXISTS then
		return "*"
	end
	-- Only reachable from `:withProperty(name, nil)` — an explicit-nil matcher.
	-- `idOf(nil)` would error (weak-key table keyed by the value), so short-circuit.
	if matcher == nil then
		return "nil"
	end
	const kind = type(matcher)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return kind .. ":" .. tostring(matcher)
	end
	return "f:" .. idOf(matcher)
end

--[[
	Canonical structural signature: requirement order never matters, so
	`query(A, B)` and `query(B, A)` produce the same key. Sub-queries recurse.
	Cached until the query mutates.
]]
function Query._signature(self: QueryInternal): string
	const cached = self._signatureCache
	if cached then
		return cached
	end
	const function reqToken(req: Queryable): string
		if type(req) == "string" then
			return "t:" .. req
		elseif isQuery(req) then
			return "q:(" .. (req :: QueryInternal):_signature() .. ")"
		end
		return "c:" .. idOf(req)
	end
	const function sortedTokens(reqs: { Queryable }): string
		const tokens = {}
		for _, req in reqs do
			table.insert(tokens, reqToken(req))
		end
		table.sort(tokens)
		return table.concat(tokens, ",")
	end
	const groups = {}
	for _, group in self._anyOf do
		table.insert(groups, sortedTokens(group))
	end
	table.sort(groups)
	const attrs = {}
	for _, attr in self._attributes do
		table.insert(attrs, attr.name .. "=" .. matcherToken(attr.matcher))
	end
	table.sort(attrs)
	const props = {}
	for _, prop in self._properties do
		table.insert(props, prop.name .. "=" .. matcherToken(prop.matcher))
	end
	table.sort(props)
	const preds = {}
	for _, pred in self._predicates do
		table.insert(preds, idOf(pred.fn) .. (if pred.signal ~= nil then ">" .. idOf(pred.signal) else ""))
	end
	table.sort(preds)
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

function Query._activate(self: QueryInternal): Engine
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
	const hasAttributes = #self._attributes > 0
	const watchedAttributes: { [string]: boolean } = {}
	for _, attr in self._attributes do
		watchedAttributes[attr.name] = true
	end

	-- Properties have no single "any property changed" signal, so each watched
	-- property gets its own `GetPropertyChangedSignal` connection per candidate.
	const hasProperties = #self._properties > 0
	const watchedProperties: { [string]: boolean } = {}
	for _, prop in self._properties do
		watchedProperties[prop.name] = true
	end

	const function reevaluate(instance: Instance?)
		if not instance then
			return
		end
		const positive = self:_positiveCandidate(instance, subMatches)
		-- Track the candidate universe and (only while bounded) attribute/property subs.
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

		const isMatch = positive and self:_matchesRest(instance, subMatches)
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

	for _, req in self:_allReferences() do
		subscribeRef(req)
	end

	-- `where` recheck signals force a full re-evaluation of bounded instances.
	for _, pred in self._predicates do
		if pred.signal ~= nil then
			const recheck = pred.signal :: RecheckSignalView
			janitor:Add(
				recheck:Connect(function()
					for instance in engine.positiveSet do
						reevaluate(instance)
					end
				end),
				"Disconnect"
			)
		end
	end

	-- Seed from the current members of every positive source.
	for instance in self:_enumerate(true) do
		reevaluate(instance)
	end

	return engine
end

function Query._deactivate(self: QueryInternal)
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
function Query._enumerate(
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
		elseif isQuery(req) then
			const subQuery = req :: QueryInternal
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

function Query.observe(self: QueryInternal, callback: (Instance, Janitor) -> ()): QueryConnection
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
function Query.observeUnyielding(self: QueryInternal, callback: (Instance, Janitor) -> ()): QueryConnection
	return attachObserver(self, callback, true, "observeUnyielding")
end

-- The sole positive requirement when the query is the ECS hot shape -- exactly
-- one required requirement and no anyOf / negative / attribute / predicate
-- clause -- so a read can answer straight from that one source. `nil` otherwise.
function Query._singleSource(self: QueryInternal): PlanReq?
	const plan = self:_plan()
	if
		#plan.required == 1
		and #plan.anyOf == 0
		and not plan.hasNegative
		and not plan.hasAttributes
		and not plan.hasPredicates
	then
		return plan.required[1]
	end
	return nil
end

-- Builds the per-call sub-query memoization cold reads use: returns
-- `(satisfiedFn, ensureSet, subSets)`. Each sub-query's match-set is computed
-- ONCE and then answered by lookup (re-running it per candidate is quadratic in
-- nested queries). When the plan references no sub-query, returns the no-op
-- `neverSub` and nils, so callers allocate nothing.
function Query._staticSub(
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
function Query._collect(self: QueryInternal, onMatch: (Instance) -> boolean?)
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
	const chosenSeed: PlanReq = (seed or firstTag or firstQuery or firstClasslike) :: PlanReq
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
function Query.get(self: QueryInternal): { Instance }
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
Query.GetMatches = Query.get

--[=[
	@within Query
	@param instance Instance
	@return boolean
	Whether `instance` matches this query right now. A membership test, not a
	scan: while the query is actively observed it is an O(1) lookup in the
	reactive engine's match set; cold, it evaluates this one instance against
	every clause (no candidate enumeration).
]=]
function Query.contains(self: QueryInternal, instance: Instance): boolean
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
function Query.count(self: QueryInternal): number
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
function Query.first(self: QueryInternal): Instance?
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
function Query.iter(self: QueryInternal): () -> Instance?
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

return Query
