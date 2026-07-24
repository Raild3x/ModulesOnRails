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
	withProperty: (self: Query, name: string, matcher: unknown) -> Query,
	where: (self: Query, predicate: (Instance) -> boolean, recheckSignal: unknown?) -> Query,
	observe: (self: Query, callback: (Instance, Janitor) -> ()) -> QueryConnection,
	get: (self: Query) -> { Instance },
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

-- Reactive state backing an activated query (ref-counted, shared when a query
-- is used more than once).
type Engine = {
	matched: { [Instance]: boolean },
	changed: ChangedSignal,
	observers: { [Observer]: boolean },
	janitor: Janitor,
	positiveSet: { [Instance]: boolean }, -- [Instance]: true while positively bounded (candidate universe)
	attrJanitors: { [Instance]: Janitor }, -- attribute subscriptions
	subEngines: { [QueryInternal]: Engine },
}

type QueryInternal = Query & {
	_positive: { Queryable },
	_anyOf: { { Queryable } }, -- array of groups
	_negative: { Queryable },
	_attributes: { AttributeRequirement },
	_predicates: { PredicateRequirement },
	_engine: Engine?,
	_refcount: number,

	_positiveSources: (self: QueryInternal) -> { Queryable },
	_validate: (self: QueryInternal, seen: { [QueryInternal]: boolean }?) -> (),
	_allReferences: (self: QueryInternal) -> { Queryable },
	_positiveCandidate: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_attributesMatch: (self: QueryInternal, instance: Instance) -> boolean,
	_predicatesPass: (self: QueryInternal, instance: Instance) -> boolean,
	_fullMatch: (self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn) -> boolean,
	_activate: (self: QueryInternal) -> Engine,
	_deactivate: (self: QueryInternal) -> (),
	_enumerate: (self: QueryInternal, reactive: boolean) -> { [Instance]: boolean },
}

local EXISTS = newproxy(false) -- sentinel: attribute must merely exist

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
function Query.new(...: Queryable): Query
	-- Cast through `any`: without it the solver stamps `@metatable` onto the
	-- table and rejects the internal type (same as TableManager's constructor).
	local self = (
		setmetatable({
			_positive = {},
			_anyOf = {},
			_negative = {},
			_attributes = {},
			_predicates = {},
			_engine = nil,
			_refcount = 0,
		}, Query) :: any
	) :: QueryInternal
	self:with(...)
	return self
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Adds required requirements. `query():with(X)` is equivalent to `query(X)`.
]=]
function Query.with(self: QueryInternal, ...: Queryable): Query
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
	Adds an "at least one of" group: the instance must satisfy at least one of the
	given requirements. Multiple `:anyOf` calls each add an independent group.
]=]
function Query.anyOf(self: QueryInternal, ...: Queryable): Query
	local group = { ... }
	for _, req in group do
		assertQueryable(req, "anyOf")
	end
	if #group > 0 then
		table.insert(self._anyOf, group)
	end
	return self
end

--[=[
	@within Query
	@param ... Queryable
	@return Query
	Adds excluded requirements: the instance must satisfy none of them.
]=]
function Query.without(self: QueryInternal, ...: Queryable): Query
	for _, req in { ... } do
		assertQueryable(req, "without")
		table.insert(self._negative, req)
	end
	return self
end

--[=[
	@within Query
	@param name string
	@param matcher any -- a value to equal, a `(value) -> boolean` predicate, or omitted for existence
	@return Query
	Requires an attribute. With no matcher, the attribute must merely exist; with a
	function, the function must return true for the attribute's value; otherwise the
	value must equal `matcher`. Re-evaluated reactively on attribute change.
]=]
function Query.withAttribute(self: QueryInternal, name: string, matcher: unknown?): Query
	assert(type(name) == "string", "[Component] :withAttribute() expects an attribute name string")
	table.insert(self._attributes, {
		name = name,
		matcher = if matcher == nil then EXISTS else matcher,
	})
	return self
end

--[=[
	@within Query
	@param predicate (instance: Instance) -> boolean
	@param recheckSignal Signal? -- fire to force re-evaluation
	@return Query

	Adds an arbitrary predicate. :::caution A predicate has no change signal of its
	own — it is only re-evaluated when another requirement changes, or when the
	optional `recheckSignal` fires. Without one, its result can go stale. :::
]=]
function Query.where(self: QueryInternal, predicate: (Instance) -> boolean, recheckSignal: unknown?): Query
	assert(type(predicate) == "function", "[Component] :where() expects a predicate function")
	table.insert(self._predicates, { fn = predicate, signal = recheckSignal })
	return self
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

-- Flattened positive requirements (positional/:with + every :anyOf member).
-- These bound the candidate set; a query with none is unbounded and rejected.
function Query._positiveSources(self: QueryInternal): { Queryable }
	local sources = {}
	for _, req in self._positive do
		table.insert(sources, req)
	end
	for _, group in self._anyOf do
		for _, req in group do
			table.insert(sources, req)
		end
	end
	return sources
end

-- DFS over sub-query references; errors on an empty query or a dependency cycle.
function Query._validate(self: QueryInternal, seen: { [QueryInternal]: boolean }?)
	local seenSet = seen or {}
	if seenSet[self] then
		error("[Component] Query dependency cycle detected", 0)
	end
	local sources = self:_positiveSources()
	if #sources == 0 then
		error(
			"[Component] Query has no positive requirement (component / tag / sub-query); "
				.. "add one via query(...), :with(), or :anyOf() so its candidate set is bounded",
			0
		)
	end
	seenSet[self] = true
	for _, req in self:_allReferences() do
		if isQuery(req) then
			local subQuery = req :: QueryInternal
			subQuery:_validate(seenSet)
		end
	end
	seenSet[self] = nil
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

local function isSatisfied(satisfiedFn: SatisfiedFn, req: Queryable, instance: Instance): boolean
	if type(req) == "string" then
		return CollectionService:HasTag(instance, req)
	elseif isQuery(req) then
		return satisfiedFn(req :: QueryInternal, instance)
	else
		local class = req :: ComponentClassLike
		local component = class:FromInstance(instance)
		return component ~= nil and Keys.inst(component).phase == "Started"
	end
end

function Query._positiveCandidate(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	for _, req in self._positive do
		if not isSatisfied(satisfiedFn, req, instance) then
			return false
		end
	end
	for _, group in self._anyOf do
		local anySatisfied = false
		for _, req in group do
			if isSatisfied(satisfiedFn, req, instance) then
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

function Query._fullMatch(self: QueryInternal, instance: Instance, satisfiedFn: SatisfiedFn): boolean
	if not self:_positiveCandidate(instance, satisfiedFn) then
		return false
	end
	for _, req in self._negative do
		if isSatisfied(satisfiedFn, req, instance) then
			return false
		end
	end
	return self:_attributesMatch(instance) and self:_predicatesPass(instance)
end

--------------------------------------------------------------------------------
-- Reactive engine (ref-counted, shared when a query is used more than once)
--------------------------------------------------------------------------------

function Query._activate(self: QueryInternal): Engine
	self._refcount += 1
	if self._engine then
		return self._engine
	end

	local janitor = Janitor.new()
	-- Cast through `unknown`: `Signal.new()` has no inference source for its
	-- `Function` generic, and Signal's invariant generics reject a direct cast.
	local changed = (Signal.new() :: unknown) :: ChangedSignal
	janitor:Add(changed, "Destroy")
	local engine: Engine = {
		matched = {},
		changed = changed,
		observers = {},
		janitor = janitor,
		positiveSet = {},
		attrJanitors = {},
		subEngines = {},
	}
	self._engine = engine
	janitor:Add(function()
		for _, attrJanitor in engine.attrJanitors do
			attrJanitor:Destroy()
		end
		table.clear(engine.attrJanitors)
	end)

	local function subMatches(subQuery: QueryInternal, instance: Instance): boolean
		local subEngine = engine.subEngines[subQuery]
		return subEngine ~= nil and subEngine.matched[instance] == true
	end

	local hasAttributes = #self._attributes > 0

	local function reevaluate(instance: Instance?)
		if not instance then
			return
		end
		local positive = self:_positiveCandidate(instance, subMatches)

		-- Track the candidate universe and (only while bounded) attribute subs.
		if positive then
			engine.positiveSet[instance] = true
			if hasAttributes and not engine.attrJanitors[instance] then
				local attrJanitor = Janitor.new()
				for _, attr in self._attributes do
					attrJanitor:Add(
						instance:GetAttributeChangedSignal(attr.name):Connect(function()
							reevaluate(instance)
						end),
						"Disconnect"
					)
				end
				engine.attrJanitors[instance] = attrJanitor
			end
		else
			engine.positiveSet[instance] = nil
			local attrJanitor = engine.attrJanitors[instance]
			if attrJanitor then
				engine.attrJanitors[instance] = nil
				attrJanitor:Destroy()
			end
		end

		local isMatch = positive and self:_fullMatch(instance, subMatches)
		local wasMatch = engine.matched[instance] == true
		if isMatch == wasMatch then
			return
		end

		if isMatch then
			engine.matched[instance] = true
			for obs in engine.observers do
				local matchJanitor = Janitor.new()
				obs.janitors[instance] = matchJanitor
				task.spawn(obs.callback, instance, matchJanitor)
			end
		else
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
	self._refcount -= 1
	if self._refcount <= 0 then
		self._refcount = 0
		if self._engine then
			self._engine.janitor:Destroy()
			self._engine = nil
		end
	end
end

-- Enumerate the candidate universe (union of positive sources). When `reactive`
-- is true, sub-query membership comes from live engines (already activated);
-- otherwise it is computed statically via each sub-query's GetMatches.
function Query._enumerate(self: QueryInternal, reactive: boolean): { [Instance]: boolean }
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
					for instance in subEngine.matched do
						set[instance] = true
					end
				end
			else
				for _, instance in subQuery:get() do
					set[instance] = true
				end
			end
		else -- component class
			local class = req :: ComponentClassLike
			for _, component in class:GetAll() do
				if Keys.inst(component).phase == "Started" then
					set[component.Instance] = true
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

	-- Fire for instances already matched at subscribe time.
	for instance in engine.matched do
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
]=]
function Query.get(self: QueryInternal): { Instance }
	self:_validate()
	local function staticSub(subQuery: QueryInternal, instance: Instance): boolean
		return subQuery:_fullMatch(instance, staticSub)
	end
	local out: { Instance } = {}
	for instance in self:_enumerate(false) do
		if self:_fullMatch(instance, staticSub) then
			table.insert(out, instance)
		end
	end
	return out
end
Query.GetMatches = Query.get

return Query
