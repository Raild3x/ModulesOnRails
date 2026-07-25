--!strict
-- Query validation, plan compilation, and the per-instance matching engine.
-- Attaches its methods (`_validate`, `_plan`, `_fullMatch`, ...) to the shared
-- `Build.prototype`. ADR-0002: the plan compiler reads a component class's live
-- started sparse set (`Keys.Internal` → `startedList` / `startedInstances`)
-- directly; that coupling to the lifecycle's field layout stays put.
-- Authors: Logan Hunt [Raildex]

const CollectionService = game:GetService("CollectionService")

const Types = require(script.Parent.Types)
const Build = require(script.Parent.Build)
const Keys = require(script.Parent.Parent.Keys)

type Queryable = Types.Queryable
type QueryInternal = Types.QueryInternal
type Filter = Types.Filter
type Combinator = Types.Combinator
type Sub = Types.Sub
type MatchSpec = Types.MatchSpec
type PlanReq = Types.PlanReq
type Plan = Types.Plan
type SatisfiedFn = Types.SatisfiedFn
type ComponentClassLike = Types.ComponentClassLike

const prototype = Build.prototype :: any
const isQuery = Build.isQuery
const isFilter = Build.isFilter
const isCombinator = Build.isCombinator
const isSub = Build.isSub

const INTERNAL = Keys.Internal -- hoisted for the plan compiler's class probe

const Plan = {}

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
Plan.isEnumerable = isEnumerable

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
Plan.reqSatisfied = reqSatisfied

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
Plan.neverSub = neverSub

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

return Plan
