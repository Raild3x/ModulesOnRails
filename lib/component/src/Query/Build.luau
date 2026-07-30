--!strict
-- Query construction: the instance `prototype`, node prototypes, type guards,
-- the static node constructors (Attr/Prop/Pred/And/Or/Not/Sub), build-time
-- normalization, and the copy-on-write builder methods. Owns the one prototype
-- table every Query instance is stamped with; Plan and Runtime attach their
-- methods to `Build.prototype` at require time.
-- Authors: Logan Hunt [Raildex]

const Types = require(script.Parent.Types)

type Queryable = Types.Queryable
type QueryInternal = Types.QueryInternal
type Query = Types.Query
type Filter = Types.Filter
type Combinator = Types.Combinator
type Sub = Types.Sub
type Matcher = Types.Matcher
type MatchSpec = Types.MatchSpec
type PredicateRequirement = Types.PredicateRequirement

const Build = {}

-- Instance methods live on `prototype` (mirrors `Component.prototype`), keeping
-- the static namespace free — `and`/`or`/`not` are reserved words, so combinators
-- must be statics, and statics must not collide with method names.
const prototype = {}
prototype.__index = prototype
Build.prototype = prototype

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
Build.isQuery = isQuery

const function isFilter(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == FilterProto
end
Build.isFilter = isFilter

const function isCombinator(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == ComboProto
end
Build.isCombinator = isCombinator

const function isSub(value: unknown): boolean
	return type(value) == "table" and getmetatable(value) == SubProto
end
Build.isSub = isSub

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
function Build.Attr(name: string, ...: Matcher): Filter
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
function Build.Prop(name: string, ...: Matcher): Filter
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
function Build.Pred(fn: (Instance) -> boolean, recheckSignal: Types.RecheckSignal?): Filter
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
function Build.And(...: Queryable): Combinator
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
function Build.Or(...: Queryable): Combinator
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
function Build.Not(...: Queryable): Combinator
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
function Build.Sub(query: Query): Sub
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

function Build.new(...: Queryable): Query
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
function prototype.where(
	self: QueryInternal,
	predicate: (Instance) -> boolean,
	recheckSignal: Types.RecheckSignal?
): Query
	assert(type(predicate) == "function", "[Component] :where() expects a predicate function")
	const new = derive(self)
	table.insert(new._predicates, { fn = predicate, signal = recheckSignal })
	return new
end

return Build
