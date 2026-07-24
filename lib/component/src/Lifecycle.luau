--!strict
-- Component lifecycle engine: drives construction chains and teardown.
-- Authors: Stephen Leitnick, Logan Hunt [Raildex]
--[=[
	@class ComponentLifecycle
	@ignore

	The single place a component instance is born and dies. `Run` drives
	ShouldConstruct -> Constructing -> Construct -> Constructed -> Starting ->
	Start -> Started as one cancellable Promise chain; `Teardown` is the single,
	guaranteed removal path (Stopping -> Stop(reason) -> Stopped -> Janitor
	destroy) used by every removal route. `init.luau` owns *when* these run
	(tag/ancestry watching); this module owns *what* running them means.
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
	Runs `fn(...)` in its own thread and resolves when it (and any Promise it
	returns) finishes. Cancelling the returned Promise cancels the thread and any
	chained Promise. This is the unit the phase barrier composes over: a hook that
	yields does not block its siblings.

	`deferred` dispatches with `task.defer` instead of `task.spawn`, so the hook
	never runs inline on the thread that triggered it (start/stop phases).

	`fn` is `(...any)` on purpose: hooks arrive as typed methods and untyped
	extension entries alike, and only `any` parameters accept both.
]]
const function invokeAsPromise(deferred: boolean, fn: (...any) -> any, ...: any): PromiseLike
	const args = table.pack(...)
	const dispatch = if deferred then task.defer else task.spawn
	return (
		Promise.new(function(resolve, reject, onCancel)
			local thread: thread?
			local chained: PromiseLike?
			local cancelled = false
			onCancel(function()
				cancelled = true
				if thread and coroutine.status(thread) == "suspended" then
					pcall(task.cancel, thread)
				end
				if chained then
					chained:cancel()
				end
			end)
			thread = task.spawn(function()
				const ok, res = pcall(fn, table.unpack(args, 1, args.n))
				if cancelled then
					return
				end
				if not ok then
					reject(res)
				elseif Promise.is(res) then
					const promise = res :: PromiseLike
					chained = promise
					promise:andThen(function(...)
						resolve(...)
					end, function(...)
						reject(...)
					end)
				else
					resolve(res)
				end
			end)
		end) :: unknown
	) :: PromiseLike
end

const NO_EDGES: { any } = {}

export type PhaseOptions = {
	-- Flip the dependency edges: a dependency's hook runs only once the hooks of
	-- everything depending on it have finished (teardown).
	reverse: boolean?,
	-- Dispatch each hook with `task.defer` (start/stop phases).
	deferred: boolean?,
	-- Warn on a hook error instead of rejecting the phase (teardown must finish).
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

	Returns nil when no active extension implements the phase.
]]
const function runHooks(
	activeExtensions: { any },
	phaseName: string,
	component: InstanceAny,
	options: PhaseOptions
): PromiseLike?
	const reverse = options.reverse == true
	const deferred = options.deferred == true

	-- extension -> the extensions whose hooks must settle before its own starts.
	const waitsOn: { [any]: { any } } = {}
	const function addEdge(after: any, before: any)
		const list = waitsOn[after]
		if list then
			table.insert(list, before)
		else
			waitsOn[after] = { before }
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

	const settled: { [any]: PromiseLike } = {}
	const nodes: { PromiseLike } = {}
	local hasHook = false
	for _, extension in order do
		const gates: { PromiseLike } = {}
		for _, other in waitsOn[extension] or NO_EDGES do
			const promise = settled[other]
			if promise then
				table.insert(gates, promise)
			end
		end
		const gate: PromiseLike? = if #gates == 0
			then nil
			elseif #gates == 1 then gates[1]
			else promiseAll(gates)

		const hook = extension[phaseName]
		local node: PromiseLike? = gate
		if type(hook) == "function" then
			hasHook = true
			const invoke = function(): PromiseLike
				const promise = invokeAsPromise(deferred, hook, component)
				if options.warnErrors then
					return promise:catch(function(err)
						warn(string.format("[Component] Error in '%s' hook: %s", phaseName, tostring(err)))
					end)
				end
				return promise
			end
			node = if gate then gate:andThen(invoke) else invoke()
		end
		if node then
			settled[extension] = node
			table.insert(nodes, node)
		end
	end

	if not hasHook then
		return nil
	end
	return if #nodes == 1 then nodes[1] else promiseAll(nodes)
end

-- Construction may yield the chain; start/stop hooks are deferred so they never
-- run inline on the thread that triggered them, and teardown must always finish.
const CONSTRUCT_PHASE: PhaseOptions = {}
const START_PHASE: PhaseOptions = { deferred = true }
const STOP_PHASE: PhaseOptions = { reverse = true, deferred = true, warnErrors = true }

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

const function callWithoutYielding(fn: (...any) -> any, ...: any): (boolean, ...any)
	const args = table.pack(...)
	local thread = coroutine.create(function()
		return fn(table.unpack(args, 1, args.n))
	end)
	const ok, res = coroutine.resume(thread)
	if not ok then
		return false, res
	end
	if coroutine.status(thread) ~= "dead" then
		error("callWithoutYielding: function yielded", 2)
	end
	return true, res
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

	untrack(class, component.Instance)
	disconnectUpdates(component)

	const function warnError(err: any)
		warn(string.format("[Component] Error during teardown of '%s': %s", tostring(class.Tag), tostring(err)))
	end

	const function invokeSafe(fn: unknown, ...: any): PromiseLike?
		if type(fn) ~= "function" then
			return nil
		end
		return invokeAsPromise(true, fn :: (...any) -> any, ...):catch(warnError)
	end

	-- The class-level signals may already be destroyed (class:Destroy tears its
	-- janitor down without waiting on the deferred stop sequence).
	const function fireSafe(signal: any, ...: any)
		pcall(function(...)
			signal:Fire(...)
		end, ...)
	end

	((Promise.resolve() :: unknown) :: PromiseLike)
		:andThen(function()
			return runHooks(ic.activeExtensions, "Stopping", component, STOP_PHASE)
		end)
		:andThen(function()
			return invokeSafe(component.Stop, component, reason)
		end)
		:andThen(function()
			return runHooks(ic.activeExtensions, "Stopped", component, STOP_PHASE)
		end)
		:andThen(function()
			const coreJanitor = ic.janitor
			if coreJanitor then
				ic.janitor = nil
				-- Janitor cleanup runs synchronously; isolate it from this thread.
				return invokeSafe(function()
					coreJanitor:Destroy()
				end)
			end
			return nil
		end)
		:andThen(function()
			ic.phase = "Stopped"
			if reachedStart then
				fireSafe(class.Stopped, component)
			else
				fireSafe(Keys.class(class).failed, component.Instance, reason)
			end
		end)
		:catch(warnError)
end

--[[
	run - drives ShouldConstruct -> Constructing -> Construct -> Constructed ->
	Starting -> Start -> Started for one component, as a single cancellable
	Promise chain. Registers the component at the Constructed phase. Any
	non-successful settle routes to `teardown`.
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
		activeExtensions = Extensions.Resolve(component, cci.extensions, false),
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

	-- Wraps a function in a barrier that checks the component's validity before
	-- and after running it. If the component is no longer valid, the chain is
	-- cancelled and the reason is recorded in the internal state for teardown.
	const function barrier<Args...>(check: ((Args...) -> ...any)?, ...: Args...): () -> ...any
		const args = {...}
		const argCount = select("#", ...)
		return function()
			const reason = validityReason()
			if reason then
				ic.stopReason = reason
				error(CANCELLED, 0)
			end
			if check then
				-- Cast the callee, NOT the unpack: `f(table.unpack(t) :: any)` is a
				-- type assertion on a multi-value expression, which truncates it to
				-- one value -- every barrier arg after the first was silently dropped.
				return (check :: any)(table.unpack(args, 1, argCount))
			end
			return nil
		end
	end

	-- Runs all hooks of a given phase in dependency order (see `runHooks`),
	-- returning a Promise that resolves when all finish. If any hook rejects, the
	-- chain is cancelled and the reason is recorded for teardown.
	const function runPhase(phaseName: string, options: PhaseOptions): PromiseLike?
		return runHooks(ic.activeExtensions, phaseName, component, options)
	end

	-- Register the in-flight record before running the chain so an external
	-- teardown can always find and cancel it.
	const record: Types.PendingRecord = { component = component, promise = nil, id = constructId }
	cci.pending[instance] = record

	const chain = ((Promise.resolve() :: unknown) :: PromiseLike)
		:andThen(barrier(runPhase, "Constructing", CONSTRUCT_PHASE))
		:andThen(barrier(function()
			if type(component.Construct) == "function" then
				return invokeAsPromise(false, component.Construct, component)
			end
			return nil
		end))
		:andThen(barrier(runPhase, "Constructed", CONSTRUCT_PHASE))
		:andThen(barrier(function()
			-- Track the component now that it is fully constructed. The pending
			-- record is kept until the chain settles so a mid-start teardown can
			-- still cancel it.
			ic.phase = "Constructed"
			cci.instToComponents[instance] = component
			table.insert(cci.components, component)
			Registry.Register(instance, class, component)
		end))
		:andThen(barrier(function()
			ic.phase = "Starting"
			return runPhase("Starting", START_PHASE)
		end))
		:andThen(barrier(function()
			if type(component.Start) == "function" then
				return invokeAsPromise(true, component.Start, component)
			end
			return nil
		end))
		:andThen(barrier(runPhase, "Started", START_PHASE))
		:andThen(barrier(function()
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
		end))

	record.promise = chain

	const settled = chain:finally(function(status)
		-- Clear the in-flight record if it is still ours.
		if cci.pending[instance] == record then
			cci.pending[instance] = nil
		end
		if status == Promise.Status.Resolved then
			return
		end
		const reason = ic.stopReason or "ConstructionCancelled"
		teardown(class, component, reason)
	end)

	-- Handle the rejection that `finally` re-raises so it is never "unhandled".
	settled:catch(function(err)
		if err ~= CANCELLED and typeof(err) == "string" then
			warn(
				string.format(
					"[Component] Error constructing '%s' on '%s':\n%s",
					tostring(class.Tag),
					instance:GetFullName(),
					tostring(err)
				)
			)
		end
	end)
end

return {
	Run = run,
	Teardown = teardown,
	Untrack = untrack,
}
