--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class FireScheduler

	The single owner of fire-mode resolution and delivery timing for both
	notification surfaces -- the per-change Signals and the path listeners. It
	resolves each surface's configured `FireMode` once (including `"bindable"`,
	which asks the environment whether it defers events natively) and owns both
	coalesce windows and the free-runner thread pool used for immediate listener
	dispatch.

	Depth: callers hand it a fire target plus args and never see a mode string.
	`Emitter` calls `FireSignal`; `ListenerRegistry` calls `RunListener`;
	`TableManager.Observe` / `ForMap` call `RunInitial`. The eventType->callback-
	args unpacking stays in `ListenerRegistry` (listener-payload knowledge) and is
	injected here via `BindListenerInvoker`, so this module never requires
	`ListenerRegistry` back.

	One scheduler is created per `TableManager` and shared by that manager's
	`Emitter` and `ListenerRegistry`. A standalone `ListenerRegistry` (specs,
	`ForMap`) default-creates its own.
]=]

const IsDeferred = require("./IsDeferred")

-- The configured timing policy for one surface. See `TMTypes.SignalFireMode` /
-- `ListenerRegistry.FireMode`.
export type FireMode = "immediate" | "deferred" | "bindable" | "coalesced"

-- A mode with `"bindable"` already resolved away. This is all the internal
-- dispatch ever branches on.
type ResolvedMode = "immediate" | "deferred" | "coalesced"

-- Runs one listener callback with its eventData, unpacking by eventType. Owned
-- by `ListenerRegistry` (payload knowledge) and injected via
-- `BindListenerInvoker`; the scheduler calls it at the resolved time.
type ListenerInvoker = (callback: (...any) -> (), eventType: any, eventData: any, debugMode: boolean) -> ()

-- Per-signal coalesce window: signal -> the packed args of the pending fire.
type SignalCoalesceState = { [any]: { Args: { n: number, [number]: any } } }

-- A listener as seen by the coalesce window. The full shape lives in
-- `ListenerRegistry`; the scheduler only touches these fields plus `Callback` /
-- `Connection`.
type CoalescingListener = {
	Callback: (...any) -> (),
	Connection: { Connected: boolean },
	_coalescePending: boolean?,
	_coalesceEventData: any?,
}

export type FireScheduler = {
	FireSignal: (self: FireScheduler, signal: any, preserveArgIndex: number?, ...any) -> (),
	RunListener: (self: FireScheduler, listener: any, eventType: any, eventData: any, debugMode: boolean) -> (),
	RunInitial: (self: FireScheduler, fn: () -> (), forceDefer: boolean?) -> (),
	BindListenerInvoker: (self: FireScheduler, invoker: ListenerInvoker) -> (),
	_signalMode: ResolvedMode,
	_listenerMode: ResolvedMode,
	_signalCoalesce: SignalCoalesceState,
	_freeRunnerThread: thread?,
	_invokeListener: ListenerInvoker?,
}

export type FireSchedulerConfig = {
	SignalFireMode: (FireMode | string)?,
	ListenerFireMode: (FireMode | string)?,
}

const FireScheduler = {}
const FireScheduler_MT = { __index = FireScheduler }

-- ---------------------------------------------------------------------------
-- Mode resolution
-- ---------------------------------------------------------------------------

-- Signal side: lenient. Preserves the historical behavior where an unrecognized
-- SignalFireMode silently falls through to immediate `:Fire` (only
-- `SetDefaults` type-checks the value). `"bindable"` mirrors the engine's actual
-- Enum.SignalBehavior via the environment probe, matching better-signal's
-- statically-bound `FireBindable`.
const function resolveSignalMode(mode: (FireMode | string)?): ResolvedMode
	const lowered = if mode == nil then "bindable" else (tostring(mode)):lower()
	if lowered == "deferred" then
		return "deferred"
	elseif lowered == "coalesced" then
		return "coalesced"
	elseif lowered == "bindable" then
		return if IsDeferred() then "deferred" else "immediate"
	end
	-- "immediate" and any unrecognized value: immediate.
	return "immediate"
end

-- Listener side: strict. Errors on a non-string or unrecognized value, matching
-- the previous `ListenerRegistry.resolveFireMode` contract.
const function resolveListenerMode(mode: (FireMode | string)?): ResolvedMode
	const raw = if mode == nil then "bindable" else mode
	assert(type(raw) == "string", `FireScheduler: ListenerFireMode must be a string, got {typeof(raw)}`)
	const lowered = (raw :: string):lower()
	if lowered == "bindable" then
		return if IsDeferred() then "deferred" else "immediate"
	elseif lowered == "immediate" or lowered == "deferred" or lowered == "coalesced" then
		return lowered :: ResolvedMode
	end
	error(
		`FireScheduler: Invalid ListenerFireMode "{lowered}". Must be "immediate", "deferred", "bindable", or "coalesced".`
	)
end

function FireScheduler.new(config: FireSchedulerConfig?): FireScheduler
	const resolvedConfig: FireSchedulerConfig = config or {}
	const self: FireScheduler = setmetatable({}, FireScheduler_MT) :: any
	self._signalMode = resolveSignalMode(resolvedConfig.SignalFireMode)
	self._listenerMode = resolveListenerMode(resolvedConfig.ListenerFireMode)
	self._signalCoalesce = {}
	self._freeRunnerThread = nil
	self._invokeListener = nil
	return self
end

-- Injects the listener-callback invoker. Called once by the `ListenerRegistry`
-- that owns (or shares) this scheduler.
function FireScheduler.BindListenerInvoker(self: FireScheduler, invoker: ListenerInvoker)
	self._invokeListener = invoker
end

-- ---------------------------------------------------------------------------
-- Signal dispatch
-- ---------------------------------------------------------------------------

-- "coalesced" SignalFireMode: collapses repeated fires of the SAME signal within
-- a tick into a single `:Fire` carrying the latest args. `preserveArgIndex` (the
-- old-value arg position, supplied by the caller since it is payload knowledge)
-- is kept from the FIRST fire in the window rather than overwritten; nil means
-- every position is latest-wins. Implemented here rather than as a `Signal`
-- method because the runtime `Signal` is the external `howmanysmall/better-
-- signal` package, not the first-party fork -- a new method would be missing on
-- the installed dependency.
const function fireSignalCoalesced(self: FireScheduler, signal: any, preserveArgIndex: number?, ...: any)
	const state = self._signalCoalesce
	const entry = state[signal]
	if entry then
		const preservedOldValue = if preserveArgIndex then entry.Args[preserveArgIndex] else nil
		entry.Args = table.pack(...)
		if preserveArgIndex then
			entry.Args[preserveArgIndex] = preservedOldValue
		end
		return
	end

	const newEntry = { Args = table.pack(...) }
	state[signal] = newEntry
	task.defer(function()
		state[signal] = nil
		signal:Fire(table.unpack(newEntry.Args, 1, newEntry.Args.n))
	end)
end

-- Dispatches a fire on one of the manager's public per-change Signals according
-- to the resolved SignalFireMode. `preserveArgIndex` is used only in the
-- coalesced window; immediate/deferred keep the allocation-free varargs path.
function FireScheduler.FireSignal(self: FireScheduler, signal: any, preserveArgIndex: number?, ...: any)
	const mode = self._signalMode
	if mode == "deferred" then
		signal:FireDeferred(...)
	elseif mode == "coalesced" then
		fireSignalCoalesced(self, signal, preserveArgIndex, ...)
	else
		signal:Fire(...)
	end
end

-- ---------------------------------------------------------------------------
-- Listener dispatch
-- ---------------------------------------------------------------------------

-- Runs a coalesced listener once via `task.defer`, regardless of how many times
-- it was "fired" before this ran. Re-checks Connected at flush time (unlike the
-- deferred path) since a coalesced flush can be scheduled well after the
-- listener disconnects.
const function flushCoalescedListener(self: FireScheduler, listener: CoalescingListener, eventType: any, debugMode: boolean)
	listener._coalescePending = false
	const eventData = listener._coalesceEventData
	listener._coalesceEventData = nil
	if listener.Connection.Connected then
		const invoke = self._invokeListener :: ListenerInvoker
		invoke(listener.Callback, eventType, eventData, debugMode)
	end
end

-- Immediate dispatch runs the callback on a reused idle thread so a listener
-- that yields or errors never blocks the write, and each scheduler reuses one
-- thread across its fires.
const function acquireRunnerThreadAndCall(self: FireScheduler, callback: (...any) -> (), eventType: any, eventData: any, debugMode: boolean)
	const invoke = self._invokeListener :: ListenerInvoker
	const acquiredRunnerThread = self._freeRunnerThread
	self._freeRunnerThread = nil
	invoke(callback, eventType, eventData, debugMode)
	-- Callback finished. This runner thread can be reused.
	self._freeRunnerThread = acquiredRunnerThread
end

-- Primed with `self` on the first resume so it parks at `coroutine.yield()`
-- before receiving any per-fire payload. Taking the payload as loop parameters
-- instead would pin it (callback + eventData, including its
-- Metadata.Snapshot.RootTable reference) on the thread's stack for the thread's
-- lifetime; `self` is long-lived so pinning it is harmless.
const function runListenerCallbackInFreeThread(self: FireScheduler)
	while true do
		acquireRunnerThreadAndCall(self, coroutine.yield())
	end
end

-- Returns this scheduler's reusable idle runner thread, lazily creating and
-- priming it (parked at its first `coroutine.yield()`) on first use.
const function ensureRunnerThread(self: FireScheduler): thread
	const existing = self._freeRunnerThread
	if existing then
		return existing
	end
	const created = coroutine.create(runListenerCallbackInFreeThread)
	self._freeRunnerThread = created
	coroutine.resume(created, self)
	return created
end

-- Runs one listener callback according to the resolved ListenerFireMode.
function FireScheduler.RunListener(self: FireScheduler, listener: any, eventType: any, eventData: any, debugMode: boolean)
	const mode = self._listenerMode
	if mode == "deferred" then
		task.defer(self._invokeListener :: ListenerInvoker, listener.Callback, eventType, eventData, debugMode)
	elseif mode == "coalesced" then
		if listener._coalescePending then
			listener._coalesceEventData = eventData
		else
			listener._coalescePending = true
			listener._coalesceEventData = eventData
			task.defer(flushCoalescedListener, self, listener, eventType, debugMode)
		end
	else
		task.spawn(ensureRunnerThread(self), listener.Callback, eventType, eventData, debugMode)
	end
end

-- ---------------------------------------------------------------------------
-- Initial-fire scheduling (Observe / For*)
-- ---------------------------------------------------------------------------

-- Runs an initial-fire thunk with the listener surface's timing: immediate mode
-- spawns now, deferred/coalesced defer. `forceDefer` (a For*'s `Defer` option)
-- defers regardless of mode.
function FireScheduler.RunInitial(self: FireScheduler, fn: () -> (), forceDefer: boolean?)
	if forceDefer or self._listenerMode ~= "immediate" then
		task.defer(fn)
	else
		task.spawn(fn)
	end
end

return FireScheduler
