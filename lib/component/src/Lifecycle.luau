--!strict
-- Component lifecycle engine: drives construction chains and teardown.
-- Authors: Stephen Leitnick, Logan Hunt [Raildex]
--[=[
	@class ComponentLifecycle
	@ignore

	The single place a component instance is born and dies. `Run` drives
	ShouldConstruct -> Constructing -> Construct -> Constructed -> Starting ->
	Start -> Started as one cancellable sequence; `Teardown` is the single,
	guaranteed removal path (Stopping -> Stop(reason) -> Stopped -> Janitor
	destroy) used by every removal route. `init.luau` owns *when* these run
	(tag/ancestry watching); this module owns *what* running them means.

	Both are driven as straight-line code on a single thread rather than a chain
	of Promises: `Run` is already called from a deferred thread, so each step runs
	inline and only *parks* (on a Promise) when a hook genuinely yields or returns
	one. Nothing about the observable contract changes — construct phases still
	hold up the chain, start/stop phases still run off the triggering thread (one
	deferral boundary before Starting; teardown defers as a whole), stop hooks
	still gate in reverse dependency order, and independent yielding hooks still
	run concurrently — but a component that never yields now allocates no Promises
	at all. See `invokeSmart` and `runHooks`.
]=]

local RunService = game:GetService("RunService")

local Packages = script.Parent.Parent
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)

local Keys = require(script.Parent.Keys)
local Registry = require(script.Parent.Registry)
local Extensions = require(script.Parent.Extensions)
local Types = require(script.Parent.Types)

type ClassAny = Types.ComponentClass_Internal
type InstanceAny = Types.ComponentInstance_Internal
type PromiseLike = Types.PromiseLike
type StopReason = Types.StopReason

const IS_SERVER = RunService:IsServer()

-- Sentinel error used to unwind the lifecycle chain on cancellation (as opposed
-- to a genuine construction error).
const CANCELLED = newproxy(false)

-- Typed view of the vendored Promise API where its inferred signatures reject
-- our structural PromiseLike; values bridge through `unknown` once, here.
const promiseAll = (Promise.all :: unknown) :: (promises: { PromiseLike }) -> PromiseLike

local renderId = 0
const function NextRenderName(): string
	renderId += 1
	return "ComponentRender" .. tostring(renderId)
end

--[[
	Runs `fn(...)` and reports how it finished, allocating a Promise only when it
	actually needs one. This is the unit every phase composes over.

	Returns `(pending, ok, result)`:
	- `(nil, true, value)`  — finished synchronously; nothing to wait on.
	- `(nil, false, err)`   — errored synchronously.
	- `(promise, ...)`      — still running (it yielded) or it returned a Promise:
	                          the caller waits on `promise`.

	The overwhelmingly common case (a hook that neither yields nor returns a
	Promise) therefore costs one `coroutine.create/resume` and no allocation
	beyond it -- the previous unconditional `Promise.new` + `task.spawn` per hook
	was ~12us each and dominated construction with more than a couple extensions.

	When the hook DOES suspend, the already-running thread is adopted by a Promise
	with the same cancellation semantics as before: cancelling kills a suspended
	thread and cancels a chained Promise.

	`fn` is `(...any)` on purpose: hooks arrive as typed methods and untyped
	extension entries alike, and only `any` parameters accept both.
]]
const function invokeSmart(fn: (...any) -> any, ...: any): (PromiseLike?, boolean, any)
	local settled = false
	local syncOk: boolean = true
	local syncRes: any = nil
	-- Set only if the hook yields: the continuation that hands its eventual
	-- outcome to the Promise built below. No polling -- the hook's own thread
	-- calls it when it finishes.
	local finish: ((boolean, any) -> ())? = nil

	-- `resume` returns as soon as the body yields, so `settled` distinguishes
	-- "ran to completion" from "parked mid-hook".
	const thread = coroutine.create(function(...)
		const ok, res = pcall(fn, ...)
		settled = true
		syncOk, syncRes = ok, res
		const continuation = finish
		if continuation then
			continuation(ok, res)
		end
	end)
	const resumeOk, resumeErr = coroutine.resume(thread, ...)
	if not resumeOk then
		-- pcall inside the body catches hook errors; reaching here means the
		-- thread itself failed (e.g. cancelled out from under us).
		return nil, false, resumeErr
	end

	if settled then
		if not syncOk then
			return nil, false, syncRes
		end
		if not Promise.is(syncRes) then
			return nil, true, syncRes
		end
		-- Returned a Promise: the caller waits on it directly, no wrapper needed.
		return syncRes :: PromiseLike, true, nil
	end

	-- The hook yielded. Adopt the live thread into a Promise so the caller can
	-- wait on it and cancellation can still reach the thread. `Promise.new` runs
	-- its executor synchronously, so `finish` is in place before the suspended
	-- hook can possibly resume.
	const promise = (
		Promise.new(function(resolve, reject, onCancel)
			local chained: PromiseLike?
			local cancelled = false
			onCancel(function()
				cancelled = true
				if coroutine.status(thread) == "suspended" then
					pcall(task.cancel, thread)
				end
				if chained then
					chained:cancel()
				end
			end)
			finish = function(ok: boolean, res: any)
				if cancelled then
					return
				end
				if not ok then
					reject(res)
				elseif Promise.is(res) then
					const inner = res :: PromiseLike
					chained = inner
					inner:andThen(function(...)
						resolve(...)
					end, function(...)
						reject(...)
					end)
				else
					resolve(res)
				end
			end
		end) :: unknown
	) :: PromiseLike
	return promise, true, nil
end

--[[
	Waits for `promise` to settle on the calling (driver) thread.
	Returns nil on success, or the error value on rejection/cancellation.
]]
const function awaitSettled(promise: PromiseLike): any?
	const awaitable = (promise :: unknown) :: { awaitStatus: (self: unknown) -> (string, ...any) }
	const status, result = awaitable:awaitStatus()
	if status == Promise.Status.Resolved then
		return nil
	end
	if status == Promise.Status.Cancelled then
		return CANCELLED
	end
	return if result == nil then CANCELLED else result
end

export type PhaseOptions = {
	-- Flip the dependency edges: a dependency's hook runs only once the hooks of
	-- everything depending on it have finished (teardown).
	reverse: boolean?,
	-- Warn on a hook error instead of failing the phase (teardown must finish).
	warnErrors: boolean?,
}

--[[
	Runs every active extension's `phaseName` hook, gated on dependency order: an
	extension's hook does not start until the hooks it must follow have finished,
	including anything they yielded on. Independent extensions still run
	concurrently, so a hook only ever waits on a real dependency edge.

	`activeExtensions` is already topologically sorted (dependencies first), so a
	single pass over it — reversed for teardown — always finds each gate promise
	already built. An extension with no hook this phase still forwards its gate,
	so a dependent keeps waiting on its transitive dependencies.

	The pass is *sync-first*: hooks run inline in topological order, and a hook
	that completes without yielding needs no Promise and no gate at all (running
	it inline already satisfied every ordering constraint). Only a hook that
	actually suspends produces a Promise, and only extensions depending on a
	still-pending hook build a gate around theirs. A phase where nothing yields
	therefore allocates nothing.

	Returns `(pending, err)`:
	- `(nil, nil)`     — the whole phase completed synchronously.
	- `(promise, nil)` — wait on `promise` for the hooks that are still running.
	- `(nil, err)`     — a hook errored synchronously (never when `warnErrors`).
]]
const function runHooks(
	activeExtensions: { any },
	phaseName: string,
	component: InstanceAny,
	options: PhaseOptions
): (PromiseLike?, any?)
	const reverse = options.reverse == true
	const warnErrors = options.warnErrors == true

	-- extension -> the extensions whose hooks must settle before its own starts.
	-- Only built when some extension actually declares dependencies.
	local waitsOn: { [any]: { any } }? = nil
	const function addEdge(after: any, before: any)
		const map = waitsOn or {}
		waitsOn = map
		const list = map[after]
		if list then
			table.insert(list, before)
		else
			map[after] = { before }
		end
	end
	for _, extension in activeExtensions do
		if type(extension.Extensions) ~= "table" then
			continue
		end
		for _, dep in extension.Extensions do
			if reverse then
				addEdge(dep, extension)
			else
				addEdge(extension, dep)
			end
		end
	end

	local order = activeExtensions
	if reverse then
		order = table.clone(activeExtensions)
		const n = #order
		for i = 1, n // 2 do
			order[i], order[n + 1 - i] = order[n + 1 - i], order[i]
		end
	end

	const function warnHookError(err: any)
		warn(string.format("[Component] Error in '%s' hook: %s", phaseName, tostring(err)))
	end

	-- Only extensions whose hook is STILL RUNNING land here; a hook that finished
	-- inline imposes no wait on its dependents.
	local pendingOf: { [any]: PromiseLike }? = nil
	local nodes: { PromiseLike }? = nil

	for _, extension in order do
		const hook = extension[phaseName]
		if type(hook) ~= "function" then
			continue
		end

		-- Gate only on dependencies that have not already finished.
		local gates: { PromiseLike }? = nil
		const pendingMap = pendingOf
		const edges = if waitsOn then waitsOn[extension] else nil
		if pendingMap and edges then
			for _, other in edges do
				const promise = pendingMap[other]
				if promise then
					const list = gates or {}
					gates = list
					table.insert(list, promise)
				end
			end
		end

		local node: PromiseLike? = nil
		if gates then
			-- A dependency is still in flight: defer this hook behind it.
			const gate: PromiseLike = if #gates == 1 then gates[1] else promiseAll(gates)
			node = gate:andThen(function()
				const pending, ok, err = invokeSmart(hook, component)
				if pending then
					return pending
				end
				if not ok then
					if warnErrors then
						warnHookError(err)
						return nil
					end
					error(err, 0)
				end
				return nil
			end)
			if warnErrors then
				node = (node :: PromiseLike):catch(warnHookError)
			end
		else
			const pending, ok, err = invokeSmart(hook, component)
			if pending then
				node = if warnErrors then pending:catch(warnHookError) else pending
			elseif not ok then
				if warnErrors then
					warnHookError(err)
				else
					return nil, err
				end
			end
		end

		if node then
			const pendingMapOut = pendingOf or {}
			pendingOf = pendingMapOut
			pendingMapOut[extension] = node
			const nodeList = nodes or {}
			nodes = nodeList
			table.insert(nodeList, node)
		end
	end

	if not nodes then
		return nil, nil
	end
	return (if #nodes == 1 then nodes[1] else promiseAll(nodes)), nil
end

-- The drivers below already run off the thread that triggered them, so hooks no
-- longer need per-hook deferral; teardown must always finish, so its hook errors
-- warn instead of failing the phase.
const CONSTRUCT_PHASE: PhaseOptions = {}
const START_PHASE: PhaseOptions = {}
const STOP_PHASE: PhaseOptions = { reverse = true, warnErrors = true }

--[[
	Deep copy for `config.Fields`, so a table default is never shared between
	component instances.
]]
const function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	const copy = {}
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item)
	end
	return copy
end

--[[
	Applies the class's configured `Fields` (deep-copied) and `InitFields` (called
	once, result copied shallowly) onto a fresh component table. Called before
	`Instance` is assigned, so neither can clobber it.
]]
const function applyFields(component: any, ci: Keys.ClassInternal)
	if ci.fields then
		for key, value in ci.fields do
			component[key] = deepCopy(value)
		end
	end
	if ci.initFields then
		for key, value in ci.initFields() do
			component[key] = value
		end
	end
end

-- Disconnects a started component's update-loop connections. Done at the start
-- of teardown so Stop() is never ticked mid-cleanup.
const function disconnectUpdates(component: InstanceAny)
	const cleanups = component._updateCleanup
	if cleanups then
		component._updateCleanup = nil
		for _, cleanup in cleanups do
			cleanup()
		end
	end
end

--[[
	Removes a component from every tracking table (per-class + global registry).
	Idempotent; safe to call whether or not the component was ever tracked.
]]
const function untrack(class: ClassAny, instance: Instance)
	const ci = Keys.class(class)
	const component = ci.instToComponents[instance]
	if component then
		ci.instToComponents[instance] = nil
		const components = ci.components
		const index = table.find(components, component)
		if index then
			const n = #components
			components[index] = components[n]
			components[n] = nil
		end
		Registry.Unregister(instance, class)
	end
end

--[[
	teardown - the single, guaranteed removal path.

	Untracking is synchronous (so a same-frame re-tag sees a free slot); the stop
	sequence itself is deferred, so teardown never blocks its caller. It runs
	Stopping -> Stop(reason) -> Stopped -> Janitor destroy, with each phase's hooks
	gated in *reverse* dependency order: a dependency's hook only runs once the
	hooks of everything depending on it have finished. Idempotent. Hook errors are
	warned, never aborting the Janitor destroy. Fires the `Stopped` class signal
	only if the component had begun starting; otherwise fires the internal
	`Failed` signal (used by GetOrCreateFromInstance).
]]
const function teardown(class: ClassAny, component: InstanceAny, reason: StopReason)
	const ic = Keys.inst(component)
	const phase = ic.phase
	if phase == "Stopping" or phase == "Stopped" or phase == "None" then
		return
	end
	const reachedStart = phase == "Starting" or phase == "Started" or ic.started == true
	ic.stopReason = reason
	ic.phase = "Stopping"
	ic.started = false

	-- Claim a slot before deferring: `class:Destroy()` checks this to know it
	-- must not tear down the signals this sequence still has to fire on.
	const cci = Keys.class(class)
	cci.teardownsInFlight += 1

	untrack(class, component.Instance)
	disconnectUpdates(component)

	const function warnError(err: any)
		warn(string.format("[Component] Error during teardown of '%s': %s", tostring(class.Tag), tostring(err)))
	end

	-- Runs `fn` to completion on the stop thread, warning (never re-raising) on
	-- error: teardown must always reach the Janitor destroy.
	const function invokeSafe(fn: unknown, ...: any)
		if type(fn) ~= "function" then
			return
		end
		const pending, ok, err = invokeSmart(fn :: (...any) -> any, ...)
		if pending then
			const failure = awaitSettled(pending)
			if failure ~= nil and failure ~= CANCELLED then
				warnError(failure)
			end
		elseif not ok then
			warnError(err)
		end
	end

	-- The class-level signals may already be destroyed (class:Destroy tears its
	-- janitor down without waiting on the deferred stop sequence).
	const function fireSafe(signal: any, ...: any)
		pcall(function(...)
			signal:Fire(...)
		end, ...)
	end

	-- Deferred so teardown never blocks its caller, then straight-line: the stop
	-- sequence only parks when a hook actually yields.
	task.defer(function()
		const function runStopPhase(phaseName: string)
			const pending = runHooks(ic.activeExtensions, phaseName, component, STOP_PHASE)
			if pending then
				const failure = awaitSettled(pending)
				if failure ~= nil and failure ~= CANCELLED then
					warnError(failure)
				end
			end
		end

		runStopPhase("Stopping")
		invokeSafe(component.Stop, component, reason)
		runStopPhase("Stopped")

		const coreJanitor = ic.janitor
		if coreJanitor then
			ic.janitor = nil
			-- Janitor cleanup runs synchronously; isolate it so a failing task
			-- cannot abort the rest of the sequence.
			invokeSafe(function()
				coreJanitor:Destroy()
			end)
		end

		ic.phase = "Stopped"
		if reachedStart then
			fireSafe(class.Stopped, component)
		else
			fireSafe(cci.failed, component.Instance, reason)
		end

		-- Last one out destroys the class Janitor `Destroy` deferred to us.
		cci.teardownsInFlight -= 1
		if cci.teardownsInFlight <= 0 and cci.destroyJanitorWhenIdle then
			cci.destroyJanitorWhenIdle = false
			cci.janitor:Destroy()
		end
	end)
end

--[[
	run - drives ShouldConstruct -> Constructing -> Construct -> Constructed ->
	Starting -> Start -> Started for one component, as a single cancellable
	sequence on the calling (already deferred) thread. Registers the component at
	the Constructed phase. Any abort — a failed validity check, an explicit
	`record.cancel`, or a hook error — routes to `teardown`.
]]
const function run(class: ClassAny, instance: Instance, constructId: number)
	const cci = Keys.class(class)
	-- Built dynamically (symbol slot, dynamic writes) under `any`, then viewed
	-- as InstanceAny. The `:: any` on the RHS keeps the solver from stamping
	-- `@metatable` onto the local and defeating the annotation.
	const componentAny: any = setmetatable({}, class) :: any
	applyFields(componentAny, cci)
	componentAny.Instance = instance
	const component = componentAny :: InstanceAny
	const ic: Keys.ComponentInternal = {
		phase = "None",
		started = false,
		stopReason = nil,
		-- Shared, never mutated (`runHooks` clones before reversing); only worth
		-- re-resolving when `ShouldExtend` can make it differ per instance.
		activeExtensions = if cci.extensionsVaryPerInstance
			then Extensions.Resolve(component, cci.extensions, false)
			else cci.classActiveExtensions,
		janitor = nil,
	}
	componentAny[Keys.Internal] = ic

	-- ShouldConstruct veto: no state created, nothing to clean up.
	if not Extensions.ShouldConstruct(ic.activeExtensions, component) then
		cci.pending[instance] = nil
		cci.failed:Fire(instance, "ShouldConstruct veto")
		return
	end

	-- From here on, teardown is guaranteed.
	ic.janitor = Janitor.new()
	ic.phase = "Constructing"

	const function validityReason(): StopReason?
		if cci.lockConstruct[instance] ~= constructId then
			return "Superseded"
		end
		if not class:_isInAncestorList(instance) then
			return if instance:IsDescendantOf(game) then "LeftAncestry" else "InstanceDestroyed"
		end
		return nil
	end

	-- Register the in-flight record before running the chain so an external
	-- teardown can always find and cancel it.
	const record: Types.PendingRecord = { component = component, cancel = nil, id = constructId }
	cci.pending[instance] = record

	-- The promise the driver is currently parked on, if any. `cancel` wakes it so
	-- the next validity check sees the cancellation and routes to teardown.
	local parkedOn: PromiseLike? = nil
	record.cancel = function(stopReason: StopReason)
		ic.stopReason = stopReason
		const promise = parkedOn
		if promise then
			parkedOn = nil
			promise:cancel()
		end
	end

	-- `run` is already called from a `task.defer`red thread (see
	-- `_tryConstruct`), so the whole sequence is straight-line code here: it only
	-- parks when a hook actually yields, instead of hopping through a Promise per
	-- step. Returns a StopReason/error to abort with, or nil on success.
	const function drive(): any?
		--[[ Validity check that records WHY, so teardown reports the real reason.
			 An explicit cancel (`record.cancel`) has already stashed its reason and
			 wins; the effective reason is always returned so the caller can tell an
			 expected stop apart from a genuine error. ]]
		const function checkValidity(): any?
			const reason = validityReason()
			if not reason then
				return nil
			end
			if ic.stopReason == nil then
				ic.stopReason = reason
			end
			return ic.stopReason
		end

		--[[ Waits on `pending` (if any) and then re-checks validity. Returns a
			 truthy abort value, or nil to continue. ]]
		const function settle(pending: PromiseLike?): any?
			if pending then
				parkedOn = pending
				const failure = awaitSettled(pending)
				parkedOn = nil
				if failure ~= nil then
					return failure
				end
			end
			return checkValidity()
		end

		const function runPhase(phaseName: string, options: PhaseOptions): any?
			const pending, err = runHooks(ic.activeExtensions, phaseName, component, options)
			if err ~= nil then
				return err
			end
			return settle(pending)
		end

		const function invokeMethod(fn: unknown): any?
			if type(fn) ~= "function" then
				return checkValidity()
			end
			const pending, ok, err = invokeSmart(fn :: (...any) -> any, component)
			if not ok then
				return if err == nil then CANCELLED else err
			end
			return settle(pending)
		end

		local abort: any? = checkValidity()
		if abort then
			return abort
		end

		-- Construct phases run inline and hold up the construction chain.
		abort = runPhase("Constructing", CONSTRUCT_PHASE)
		if abort then
			return abort
		end
		abort = invokeMethod(component.Construct)
		if abort then
			return abort
		end
		abort = runPhase("Constructed", CONSTRUCT_PHASE)
		if abort then
			return abort
		end

		-- Track the component now that it is fully constructed. The pending
		-- record is kept until the sequence settles so a mid-start teardown can
		-- still cancel it.
		ic.phase = "Constructed"
		cci.instToComponents[instance] = component
		table.insert(cci.components, component)
		Registry.Register(instance, class, component)

		-- The one deferral boundary: start phases never run on the thread that
		-- drove construction.
		const thread = coroutine.running()
		task.defer(thread)
		coroutine.yield()

		abort = checkValidity()
		if abort then
			return abort
		end

		ic.phase = "Starting"
		abort = runPhase("Starting", START_PHASE)
		if abort then
			return abort
		end
		abort = invokeMethod(component.Start)
		if abort then
			return abort
		end
		abort = runPhase("Started", START_PHASE)
		if abort then
			return abort
		end

		-- Connect update loops, mark started, fire Started.
		const updateCleanup: { () -> () } = {}
		component._updateCleanup = updateCleanup
		if type(component.HeartbeatUpdate) == "function" then
			const update = component.HeartbeatUpdate :: (self: InstanceAny, dt: number) -> ()
			const conn = RunService.Heartbeat:Connect(function(dt)
				update(component, dt)
			end)
			table.insert(updateCleanup, function()
				conn:Disconnect()
			end)
		end
		if type(component.SteppedUpdate) == "function" then
			const update = component.SteppedUpdate :: (self: InstanceAny, dt: number) -> ()
			const conn = RunService.Stepped:Connect(function(_, dt)
				update(component, dt)
			end)
			table.insert(updateCleanup, function()
				conn:Disconnect()
			end)
		end
		if type(component.RenderSteppedUpdate) == "function" and not IS_SERVER then
			const update = component.RenderSteppedUpdate :: (self: InstanceAny, dt: number) -> ()
			if component.RenderPriority then
				const name = NextRenderName()
				RunService:BindToRenderStep(name, component.RenderPriority, function(dt)
					update(component, dt)
				end)
				table.insert(updateCleanup, function()
					RunService:UnbindFromRenderStep(name)
				end)
			else
				const conn = RunService.RenderStepped:Connect(function(dt)
					update(component, dt)
				end)
				table.insert(updateCleanup, function()
					conn:Disconnect()
				end)
			end
		end
		ic.phase = "Started"
		ic.started = true
		class.Started:Fire(component)
		return nil
	end

	const ok, abort = pcall(drive)

	-- Clear the in-flight record if it is still ours.
	if cci.pending[instance] == record then
		cci.pending[instance] = nil
	end

	if ok and abort == nil then
		return
	end

	-- An expected stop (cancellation, or a validity check that recorded its
	-- StopReason) routes straight to teardown; anything else is a genuine
	-- construction error worth surfacing. Both table errors (Promise wraps hook
	-- errors in a `Promise.Error`) and plain strings are reported -- a
	-- string-only filter previously swallowed every wrapped error, which is how a
	-- total-failure bug once went silent.
	const failure: any = abort
	const isExpectedStop = ic.stopReason ~= nil and failure == ic.stopReason
	if failure ~= CANCELLED and not isExpectedStop then
		warn(
			string.format(
				"[Component] Error constructing '%s' on '%s':\n%s",
				tostring(class.Tag),
				instance:GetFullName(),
				tostring(failure)
			)
		)
	end
	teardown(class, component, ic.stopReason or "ConstructionCancelled")
end

return {
	Run = run,
	Teardown = teardown,
	Untrack = untrack,
}
