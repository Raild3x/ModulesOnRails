--!strict
-- World-level component query engine.
-- Authors: Logan Hunt [Raildex]
--[=[
	@class Query
	@ignore

	A reusable, reactive query over tagged instances. Built with
	`Component.query(...)` and refined with chain methods, then either observed
	(`:observe`) or read once (`:GetMatches`).

	A *requirement* is a **component class** (satisfied while that component is
	*started* on the instance), a **tag string** (satisfied while the instance has
	the raw CollectionService tag), or **another Query** (satisfied while the
	instance matches it). An instance *matches* while:

	- every positional / `:with` requirement is satisfied,
	- every `:anyOf(...)` group has at least one satisfied,
	- no `:without` requirement is satisfied,
	- every `:withAttribute` matches, and
	- every `:where` predicate returns true.

	A query must have at least one positive requirement (component / tag /
	sub-query in the positional args, `:with`, or `:anyOf`) so its candidate set
	is bounded; a query built only from `:without` / `:withAttribute` / `:where`
	errors when observed or read.

	See the Component `CONTEXT.md` for the glossary and the `README` for examples.
]=]

local CollectionService = game:GetService("CollectionService")

local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Janitor = require(Packages.Janitor)

local Keys = require(script.Parent.Keys)

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
	where: (self: Query, predicate: (Instance) -> boolean, recheckSignal: unknown?) -> Query,
	observe: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
	get: (self: Query) -> { Instance },
	iter: (self: Query) -> () -> Instance?,
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

-- One `:where` requirement; `signal` is duck-cast to `RecheckSignalView` when
-- the engine activates.
type PredicateRequirement = {
	fn: (Instance) -> boolean,
	signal: unknown?,
}

type Observer = {
	callback: (Instance, Janitor) -> (),
	janitors: { [Instance]: Janitor },
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
}

local EXISTS = newproxy(false) -- sentinel: attribute must merely exist
local INTERNAL = Keys.Internal -- hoisted for the plan compiler's class probe

local Query = {}
Query.__index = Query

local function isQuery(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == Query
end

local function isComponentClass(value: unknown): boolean
	if type(value) ~= "table" or isQuery(value) then
		return false
	end
	return type((value :: { read Tag: unknown }).Tag) == "string"
end

local function assertQueryable(value: Queryable, method: string)
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
local function rawNew(): QueryInternal
	-- Cast through `any`: without it the solver stamps `@metatable` onto the
	-- table and rejects the internal type (same as TableManager's constructor).
	return (
		setmetatable({
			_positive = {},
			_anyOf = {},
			_negative = {},
			_attributes = {},
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
local function derive(self: QueryInternal): QueryInternal
	local new = rawNew()
	new._positive = table.clone(self._positive)
	new._anyOf = table.clone(self._anyOf)
	new._negative = table.clone(self._negative)
	new._attributes = table.clone(self._attributes)
	new._predicates = table.clone(self._predicates)
	return new
end

function Query.new(...: Queryable): Query
	local self = rawNew()
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
	local new = derive(self)
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
	local group = { ... }
	for _, req in group do
		assertQueryable(req, "anyOf")
	end
	if #group == 0 then
		return self
	end
	local new = derive(self)
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
	local new = derive(self)
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
	local new = derive(self)
	table.insert(new._attributes, {
		name = name,
		matcher = if matcher == nil then EXISTS else matcher,
	})
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
	local new = derive(self)
	table.insert(new._predicates, { fn = predicate, signal = recheckSignal })
	return new
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

-- Flattened positive requirements (positional/:with + every :anyOf member).
-- These bound the candidate set; a query with none is unbounded and rejected.
function Query._positiveSources(self: QueryInternal): { Queryable }
	local cached = self._sources
	if cached then
		return cached
	end
	local sources = {}
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
	local sources = self:_positiveSources()
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
	local refs = {}
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

local function compileReq(req: Queryable, buildIndex: number): PlanReq
	if type(req) == "string" then
		return { kind = "tag" :: "tag", buildIndex = buildIndex, tag = req }
	end
	if isQuery(req) then
		return { kind = "query" :: "query", buildIndex = buildIndex, query = req :: QueryInternal }
	end
	local internal = (req :: any)[INTERNAL]
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
local KIND_COST: { [string]: number } = { class = 1, query = 2, classlike = 3, tag = 4 }

-- A seed at or below this is narrow enough that hunting for a better one is
-- not worth fetching more tag arrays: remaining probes run at most this many
-- times each.
local TAG_SIZING_EARLY_EXIT = 32

-- `get()` sizes every required tag via `GetTagged` (to pick the narrowest seed
-- and order probes most-selective-first) only when the best class seed exceeds
-- this. Below it the candidate set is already small, and sizing a huge tag
-- would cost an array allocation proportional to its population for at most a
-- few hundred cheap probes of savings.
local TAG_SIZING_MIN_SEED = 200
local function sortBySelectivity(reqs: { PlanReq })
	table.sort(reqs, function(x: PlanReq, y: PlanReq): boolean
		local cx = KIND_COST[x.kind] :: number
		local cy = KIND_COST[y.kind] :: number
		if cx ~= cy then
			return cx < cy
		end
		return x.buildIndex < y.buildIndex
	end)
end

-- Compiled requirement check. `satisfiedFn` is only consulted for sub-query
-- requirements; tag/class checks are direct.
local function reqSatisfied(req: PlanReq, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	local kind = req.kind
	if kind == "class" then
		return (req.startedMap :: { [Instance]: number })[instance] ~= nil
	elseif kind == "tag" then
		return CollectionService:HasTag(instance, req.tag :: string)
	elseif kind == "query" then
		return satisfiedFn(req.query :: QueryInternal, instance)
	else
		local class = req.class :: ComponentClassLike
		local component = class:FromInstance(instance)
		return component ~= nil and Keys.inst(component).phase == "Started"
	end
end

-- Placeholder SatisfiedFn for plans with no sub-query requirement: nothing can
-- ever call it (`reqSatisfied` only consults satisfiedFn for "query" kinds).
local function neverSub(_query: QueryInternal, _instance: Instance): boolean
	return false
end

function Query._plan(self: QueryInternal): Plan
	local cached = self._planned
	if cached then
		return cached
	end
	local required: { PlanReq } = {}
	for index, req in self._positive do
		table.insert(required, compileReq(req, index))
	end
	sortBySelectivity(required)
	local anyOf: { { PlanReq } } = {}
	for _, group in self._anyOf do
		local compiled: { PlanReq } = {}
		for index, req in group do
			table.insert(compiled, compileReq(req, index))
		end
		sortBySelectivity(compiled)
		table.insert(anyOf, compiled)
	end
	local negative: { PlanReq } = {}
	for index, req in self._negative do
		table.insert(negative, compileReq(req, index))
	end
	sortBySelectivity(negative)
	local function anyQueryReq(reqs: { PlanReq }): boolean
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
	local plan: Plan = {
		required = required,
		anyOf = anyOf,
		negative = negative,
		hasNegative = #negative > 0,
		hasAttributes = #self._attributes > 0,
		hasPredicates = #self._predicates > 0,
		hasQueryRefs = hasQueryRefs,
	}
	self._planned = plan
	return plan
end

function Query._positiveCandidate(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	local plan = self:_plan()
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
		local value = instance:GetAttribute(attr.name)
		local matcher = attr.matcher
		local ok: boolean
		if matcher == EXISTS then
			ok = value ~= nil
		elseif type(matcher) == "function" then
			local success, result = pcall(matcher :: (unknown) -> unknown, value)
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

function Query._predicatesPass(self: QueryInternal, instance: Instance): boolean
	for _, pred in self._predicates do
		local success, result = pcall(pred.fn, instance)
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
	local plan = self:_plan()
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
local signatureIds: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextSignatureId = 0
local function idOf(value: any): string
	local existing = signatureIds[value]
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
local function matcherToken(matcher: unknown): string
	if matcher == EXISTS then
		return "*"
	end
	local kind = type(matcher)
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
	local cached = self._signatureCache
	if cached then
		return cached
	end
	local function reqToken(req: Queryable): string
		if type(req) == "string" then
			return "t:" .. req
		elseif isQuery(req) then
			return "q:(" .. (req :: QueryInternal):_signature() .. ")"
		end
		return "c:" .. idOf(req)
	end
	local function sortedTokens(reqs: { Queryable }): string
		local tokens = {}
		for _, req in reqs do
			table.insert(tokens, reqToken(req))
		end
		table.sort(tokens)
		return table.concat(tokens, ",")
	end
	local groups = {}
	for _, group in self._anyOf do
		table.insert(groups, sortedTokens(group))
	end
	table.sort(groups)
	local attrs = {}
	for _, attr in self._attributes do
		table.insert(attrs, attr.name .. "=" .. matcherToken(attr.matcher))
	end
	table.sort(attrs)
	local preds = {}
	for _, pred in self._predicates do
		table.insert(preds, idOf(pred.fn) .. (if pred.signal ~= nil then ">" .. idOf(pred.signal) else ""))
	end
	table.sort(preds)
	local signature = sortedTokens(self._positive)
		.. "|"
		.. table.concat(groups, ";")
		.. "|"
		.. sortedTokens(self._negative)
		.. "|"
		.. table.concat(attrs, ",")
		.. "|"
		.. table.concat(preds, ",")
	self._signatureCache = signature
	return signature
end

-- Live engines interned by signature: equivalent queries observed anywhere in
-- the process share ONE engine (one set of subscriptions, one matched set, one
-- re-evaluation per event) instead of each maintaining their own.
local activeEngines: { [string]: Engine } = {}

--------------------------------------------------------------------------------
-- Reactive engine (ref-counted; shared across all structurally equal queries)
--------------------------------------------------------------------------------

function Query._activate(self: QueryInternal): Engine
	self._refcount += 1
	local attached = self._engine
	if attached then
		attached.refcount += 1
		return attached
	end

	-- An equivalent query may already maintain this exact engine.
	local signature = self:_signature()
	local interned = activeEngines[signature]
	if interned then
		interned.refcount += 1
		interned.holders[self] = true
		self._engine = interned
		return interned
	end

	local janitor = Janitor.new()
	-- Cast through `unknown`: `Signal.new()` has no inference source for its
	-- `Function` generic, and Signal's invariant generics reject a direct cast.
	local changed = (Signal.new() :: unknown) :: ChangedSignal
	janitor:Add(changed, "Destroy")
	local engine: Engine = {
		matched = {},
		matchedList = {},
		changed = changed,
		observers = {},
		janitor = janitor,
		positiveSet = {},
		attrConns = {},
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
	end)

	local function subMatches(subQuery: QueryInternal, instance: Instance): boolean
		local subEngine = engine.subEngines[subQuery]
		return subEngine ~= nil and subEngine.matched[instance] ~= nil
	end

	-- One `AttributeChanged` connection per candidate, filtered by name, instead
	-- of a Janitor plus a `GetAttributeChangedSignal` connection per attribute:
	-- activation over a large candidate set was dominated by that allocation.
	local hasAttributes = #self._attributes > 0
	local watchedAttributes: { [string]: boolean } = {}
	for _, attr in self._attributes do
		watchedAttributes[attr.name] = true
	end

	local function reevaluate(instance: Instance?)
		if not instance then
			return
		end
		local positive = self:_positiveCandidate(instance, subMatches)

		-- Track the candidate universe and (only while bounded) attribute subs.
		if positive then
			engine.positiveSet[instance] = true
			if hasAttributes and not engine.attrConns[instance] then
				engine.attrConns[instance] = instance.AttributeChanged:Connect(function(attrName)
					if watchedAttributes[attrName] then
						reevaluate(instance)
					end
				end) :: any
			end
		else
			engine.positiveSet[instance] = nil
			local attrConn = engine.attrConns[instance]
			if attrConn then
				engine.attrConns[instance] = nil
				attrConn:Disconnect()
			end
		end

		local isMatch = positive and self:_matchesRest(instance, subMatches)
		local wasMatch = engine.matched[instance] ~= nil
		if isMatch == wasMatch then
			return
		end

		local matchedList = engine.matchedList
		if isMatch then
			local n = #matchedList + 1
			matchedList[n] = instance
			engine.matched[instance] = n
			for obs in engine.observers do
				local matchJanitor = Janitor.new()
				obs.janitors[instance] = matchJanitor
				task.spawn(obs.callback, instance, matchJanitor)
			end
		else
			-- Swap-remove: move the tail into the vacated slot. When the
			-- instance IS the tail, the reassignments are harmless no-ops.
			local index = engine.matched[instance] :: number
			local lastIndex = #matchedList
			local last = matchedList[lastIndex]
			matchedList[index] = last
			engine.matched[last] = index
			matchedList[lastIndex] = nil
			engine.matched[instance] = nil
			for obs in engine.observers do
				local matchJanitor = obs.janitors[instance]
				if matchJanitor then
					obs.janitors[instance] = nil
					matchJanitor:Destroy()
				end
			end
		end
		engine.changed:Fire(instance, isMatch)
	end

	-- Subscribe to every referenced input so a change re-evaluates the instance.
	local connectedClasses: { [ComponentClassLike]: boolean } = {}
	local connectedTags: { [string]: boolean } = {}
	local function subscribeRef(req: Queryable)
		if type(req) == "string" then
			if connectedTags[req] then
				return
			end
			connectedTags[req] = true
			janitor:Add(CollectionService:GetInstanceAddedSignal(req):Connect(reevaluate), "Disconnect")
			janitor:Add(CollectionService:GetInstanceRemovedSignal(req):Connect(reevaluate), "Disconnect")
		elseif isQuery(req) then
			local subQuery = req :: QueryInternal
			if engine.subEngines[subQuery] then
				return
			end
			local subEngine = subQuery:_activate()
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
			local class = req :: ComponentClassLike
			if connectedClasses[class] then
				return
			end
			connectedClasses[class] = true
			local started = class.Started :: ClassSignalView
			local stopped = class.Stopped :: ClassSignalView
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
			local recheck = pred.signal :: RecheckSignalView
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
	local engine = self._engine
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
	local set: { [Instance]: boolean } = {}
	local function addFromRef(req: Queryable)
		if type(req) == "string" then
			for _, instance in CollectionService:GetTagged(req) do
				set[instance] = true
			end
		elseif isQuery(req) then
			local subQuery = req :: QueryInternal
			if reactive then
				local engine = self._engine :: Engine
				local subEngine = engine.subEngines[subQuery]
				if subEngine then
					for _, instance in subEngine.matchedList do
						set[instance] = true
					end
				end
			else
				-- Reuse the caller's per-call memo when there is one, so a nested
				-- sub-query is evaluated once per `get()` rather than per candidate.
				local memo = if subSets then subSets[subQuery] else nil
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
			local class = req :: ComponentClassLike
			local internal = (class :: any)[Keys.Internal]
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
function Query.observe(self: QueryInternal, callback: (Instance, Janitor) -> ()): QueryConnection
	assert(type(callback) == "function", "[Component] Query:observe() expects a callback function")
	self:_validate()
	local engine = self:_activate()

	local obs: Observer = { callback = callback, janitors = {} }
	engine.observers[obs] = true

	-- Fire for instances already matched at subscribe time. Iterate a SNAPSHOT:
	-- under Immediate signal behavior a spawned callback can synchronously
	-- retag/untag and mutate the live match set mid-loop.
	for _, instance in table.clone(engine.matchedList) do
		local matchJanitor = Janitor.new()
		obs.janitors[instance] = matchJanitor
		task.spawn(callback, instance, matchJanitor)
	end

	local connProxy = {} :: QueryConnection
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
	local engine = self._engine or activeEngines[self:_signature()]
	if engine then
		return table.clone(engine.matchedList)
	end

	local plan = self:_plan()

	-- Each sub-query's match-set is computed ONCE per call and then answered by
	-- lookup. Previously every candidate re-ran the whole sub-query (and
	-- `_enumerate` ran it again on top), which is quadratic in nested queries.
	-- The machinery (memo table + two closures) is only built when some clause
	-- actually references a sub-query; `staticSub` is never consulted otherwise.
	local subSets: { [QueryInternal]: { [Instance]: boolean } }? = nil
	local ensureSet: ((QueryInternal) -> { [Instance]: boolean })? = nil
	local staticSub: SatisfiedFn = neverSub
	if plan.hasQueryRefs then
		local sets: { [QueryInternal]: { [Instance]: boolean } } = {}
		subSets = sets
		local sub: SatisfiedFn
		local ensure: (QueryInternal) -> { [Instance]: boolean }
		function ensure(subQuery: QueryInternal): { [Instance]: boolean }
			local existing = sets[subQuery]
			if existing then
				return existing
			end
			-- Seed the entry before recursing so shared sub-queries are computed
			-- exactly once (recursion depth is finite: queries are immutable, so
			-- the reference graph is a DAG by construction).
			local set: { [Instance]: boolean } = {}
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
		ensureSet = ensure
		staticSub = sub

		for _, req in self:_allReferences() do
			if isQuery(req) then
				ensure(req :: QueryInternal)
			end
		end
	end
	local required = plan.required
	local out: { Instance } = {}

	if #required == 0 then
		-- anyOf-only query: the candidate set genuinely is a union, so build it.
		for instance in self:_enumerate(false, subSets) do
			if self:_fullMatch(instance, staticSub) then
				table.insert(out, instance)
			end
		end
		return out
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
		local kind = req.kind
		if kind == "class" then
			local size = #(req.startedList :: { Instance })
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
		local sizes: { [PlanReq]: number } = {}
		local arrays: { [PlanReq]: { Instance } } = {}
		tagSizes, tagArrays = sizes, arrays
		for _, req in required do
			if req.kind == "tag" then
				local instances = CollectionService:GetTagged(req.tag :: string)
				arrays[req] = instances
				local size = #instances
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
	local chosenSeed: PlanReq = (seed or firstTag or firstQuery or firstClasslike) :: PlanReq
	local seedKind = chosenSeed.kind

	-- The ECS hot shape — one requirement, nothing else — is a straight dump of
	-- the seed source, before any per-candidate machinery is even allocated.
	if
		#required == 1
		and #plan.anyOf == 0
		and not plan.hasNegative
		and not plan.hasAttributes
		and not plan.hasPredicates
	then
		if seedKind == "class" then
			return table.clone(chosenSeed.startedList :: { Instance })
		elseif seedKind == "tag" then
			-- Both sources are arrays freshly allocated for this call, so they
			-- are safe to hand out directly.
			local sized = if tagArrays then (tagArrays :: { [PlanReq]: { Instance } })[chosenSeed] else nil
			return sized or CollectionService:GetTagged(chosenSeed.tag :: string)
		elseif seedKind == "query" then
			local ensure = ensureSet :: (QueryInternal) -> { [Instance]: boolean }
			for instance in ensure(chosenSeed.query :: QueryInternal) do
				table.insert(out, instance)
			end
			return out
		else
			for _, component in (chosenSeed.class :: ComponentClassLike):GetAll() do
				if Keys.inst(component).phase == "Started" then
					table.insert(out, component.Instance)
				end
			end
			return out
		end
	end

	-- Probes = every required requirement except the seed, most-selective-first
	-- when populations are known (smaller population rejects more candidates
	-- sooner, so each later probe runs against fewer survivors). Unknown counts
	-- keep the plan's cheap-kind-first order.
	local probes: { PlanReq } = {}
	for _, req in required do
		if req ~= chosenSeed then
			table.insert(probes, req)
		end
	end
	if tagSizes and #probes > 1 then
		local sizes = tagSizes :: { [PlanReq]: number }
		local function populationOf(req: PlanReq): number
			if req.kind == "class" then
				return #(req.startedList :: { Instance })
			end
			local sized = sizes[req]
			if sized then
				return sized
			end
			return math.huge
		end
		table.sort(probes, function(x: PlanReq, y: PlanReq): boolean
			local px, py = populationOf(x), populationOf(y)
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
		local arrays = tagArrays :: { [PlanReq]: { Instance } }
		local sizes = tagSizes :: { [PlanReq]: number }
		for _, req in probes do
			local instances = arrays[req]
			if instances and seedSize * 3 > (sizes[req] :: number) then
				local set: { [Instance]: boolean } = {}
				for _, instance in instances do
					set[instance] = true
				end
				local outSets = probeSets or {}
				probeSets = outSets
				outSets[req] = set
			end
		end
	end

	-- Checks everything except the seed requirement (the seed's own iteration
	-- already proves it) and collects matches. Rest-checks are inlined here so a
	-- candidate costs no extra method dispatch.
	local anyOf = plan.anyOf
	local function consider(instance: Instance)
		for _, req in probes do
			local set = if probeSets then (probeSets :: { [PlanReq]: { [Instance]: boolean } })[req] else nil
			if set then
				if not set[instance] then
					return
				end
			elseif not reqSatisfied(req, instance, staticSub) then
				return
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
				return
			end
		end
		if plan.hasNegative then
			for _, req in plan.negative do
				if reqSatisfied(req, instance, staticSub) then
					return
				end
			end
		end
		if plan.hasAttributes and not self:_attributesMatch(instance) then
			return
		end
		if plan.hasPredicates and not self:_predicatesPass(instance) then
			return
		end
		table.insert(out, instance)
	end

	if seedKind == "class" then
		for _, instance in chosenSeed.startedList :: { Instance } do
			consider(instance)
		end
	elseif seedKind == "tag" then
		local seedInstances = if tagArrays then (tagArrays :: { [PlanReq]: { Instance } })[chosenSeed] else nil
		for _, instance in seedInstances or CollectionService:GetTagged(chosenSeed.tag :: string) do
			consider(instance)
		end
	elseif seedKind == "query" then
		local ensure = ensureSet :: (QueryInternal) -> { [Instance]: boolean }
		for instance in ensure(chosenSeed.query :: QueryInternal) do
			consider(instance)
		end
	else
		for _, component in (chosenSeed.class :: ComponentClassLike):GetAll() do
			if Keys.inst(component).phase == "Started" then
				consider(component.Instance)
			end
		end
	end
	return out
end
Query.GetMatches = Query.get

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
	local engine = self._engine or activeEngines[self:_signature()]
	-- Backwards, so the engine's swap-remove (which moves an already-visited
	-- tail element into the vacated slot) never skips an unvisited instance.
	local list = if engine then engine.matchedList else self:get()
	local index = #list + 1
	return function(): Instance?
		index -= 1
		return list[index]
	end
end

return Query
