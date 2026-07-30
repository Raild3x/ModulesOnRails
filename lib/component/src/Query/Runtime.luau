--!strict
-- Query runtime: structural signatures + engine interning, the ref-counted
-- reactive engine (`_activate` / `_deactivate`), candidate enumeration, the
-- subscription terminals (`observe` / `observeUnyielding` / `track`), and the
-- one-shot read terminals (`get` / `iter` / `contains` / `count` / `first`).
-- Owns the module-level intern registry and signature-id state. Attaches its
-- methods to the shared `Build.prototype`.
-- Authors: Logan Hunt [Raildex]

const CollectionService = game:GetService("CollectionService")

const Packages = script.Parent.Parent.Parent
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)

const Types = require(script.Parent.Types)
const Build = require(script.Parent.Build)
const Plan = require(script.Parent.Plan)
const Keys = require(script.Parent.Parent.Keys)

type Queryable = Types.Queryable
type QueryInternal = Types.QueryInternal
type Filter = Types.Filter
type Combinator = Types.Combinator
type Sub = Types.Sub
type MatchSpec = Types.MatchSpec
type PlanReq = Types.PlanReq
type Plan = Types.Plan
type Engine = Types.Engine
type Observer = Types.Observer
type ChangedSignal = Types.ChangedSignal
type SatisfiedFn = Types.SatisfiedFn
type QueryConnection = Types.QueryConnection
type ComponentClassLike = Types.ComponentClassLike
type ClassSignalView = Types.ClassSignalView
type RecheckSignalView = Types.RecheckSignalView
type ConnectionLike = Types.ConnectionLike
type Janitor = Types.Janitor

const prototype = Build.prototype :: any
const isQuery = Build.isQuery
const isFilter = Build.isFilter
const isCombinator = Build.isCombinator
const isSub = Build.isSub

const isEnumerable = Plan.isEnumerable
const reqSatisfied = Plan.reqSatisfied
const neverSub = Plan.neverSub

const INTERNAL = Keys.Internal

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

const Runtime = {}

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
			-- this source contributes, pre-filtered. (A non-class requirement never
			-- reaches here — the plan compiler rejects it up front.)
			const internal = (req :: any)[Keys.Internal]
			if internal then
				for _, instance in internal.startedList do
					set[instance] = true
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
		if kind == "class" or kind == "tag" or kind == "query" then
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
	const fallbackSeed = seed or firstTag or firstQuery
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
	else -- query
		const ensure = ensureSet :: (QueryInternal) -> { [Instance]: boolean }
		for instance in ensure(chosenSeed.query :: QueryInternal) do
			if consider(instance) then
				return
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
		else -- query
			const out: { Instance } = {}
			const _, ensure = self:_staticSub(self:_plan())
			for instance in (ensure :: (QueryInternal) -> { [Instance]: boolean })(single.query :: QueryInternal) do
				table.insert(out, instance)
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

return Runtime
