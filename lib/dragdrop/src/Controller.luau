--[[
	DragDrop — controller (the singleton state machine).

	Owns the source/target registries, the drag state machine, the config store,
	the reactive state (active payload / hovered target) and the cross-cutting
	signals. Device backends (pointer, selection) are pure translators: they never
	touch state directly, only call the injected transition `api`. This keeps the
	state machine the single device-agnostic seam.

	State:  Idle → Pending (press captured; threshold/hold not yet resolved)
	              → Dragging (payload airborne; ghost + scroll locks live)
	              → Idle

	Every exit from Dragging runs the per-drag Janitor (restoring ScrollingFrame
	locks and tearing down the ghost + observers) BEFORE any user callback fires,
	and all user callbacks are pcall-guarded, so a throwing OnDrop can never leave
	a scrolling list permanently locked.

	Scriptable/controlled drags (Scriptable input mode, or a positioned
	BeginDrag) are owned by the caller: the automatic backends ignore them and the
	preferred-input / focus cancels do not apply.
]]

const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")
const GuiService = game:GetService("GuiService")
const ContextActionService = game:GetService("ContextActionService")

const Signal = require("../Signal")
const Janitor = require("../Janitor")

const Types = require("./Types")
const InputUtil = require("./InputUtil")
const GhostLayer = require("./GhostLayer")
const PointerBackend = require("./Backends/PointerBackend")
const SelectionBackend = require("./Backends/SelectionBackend")

type Payload = Types.Payload
type Device = Types.Device
type SourceEntry = Types.SourceEntry
type TargetEntry = Types.TargetEntry
type TargetDescriptor = Types.TargetDescriptor
type DragHandle = Types.DragHandle
type InputMode = Types.InputMode
type InputLike = Types.InputLike

-- Window after a drag ends during which a stray Activated should be swallowed
-- (see ConsumeActivation).
const ACTIVATION_CONSUME_WINDOW = 0.05

--------------------------------------------------------------------------------
--// Config store //--
--------------------------------------------------------------------------------

const DEFAULTS = {
	DragThresholdPx = 8,
	TouchSlopPx = 12,
	LongPressSeconds = 0.4,
	SnapSpeed = 30,
	GamepadLiftKeyCode = Enum.KeyCode.ButtonX,
	GamepadDropKeyCode = Enum.KeyCode.ButtonA,
	GamepadCancelKeyCode = Enum.KeyCode.ButtonB,
	KeyboardLiftKeyCode = Enum.KeyCode.Return,
}

-- Value kind expected per config key, for Configure() validation. Keys whose
-- default is nil (GhostContainer, KeyboardCancelKeyCode) still validate here.
const CONFIG_KINDS: { [string]: string } = {
	DragThresholdPx = "number",
	TouchSlopPx = "number",
	LongPressSeconds = "number",
	SnapSpeed = "number",
	GhostContainer = "LayerCollector",
	GamepadLiftKeyCode = "EnumItem",
	GamepadDropKeyCode = "EnumItem",
	GamepadCancelKeyCode = "EnumItem",
	KeyboardLiftKeyCode = "EnumItem",
	KeyboardCancelKeyCode = "EnumItem",
}

const Config: { [string]: any } = table.clone(DEFAULTS)

const function getConfig(key: string): any
	return Config[key]
end

--------------------------------------------------------------------------------
--// Reactive state (Fusion-free observables) + signals //--
--------------------------------------------------------------------------------

const function safeCall(fn: any, ...): ()
	if typeof(fn) == "function" then
		const ok, err = pcall(fn, ...)
		if not ok then
			warn("[DragDrop] callback error:", err)
		end
	end
end

type Observable<T> = {
	get: () -> T,
	set: (value: T) -> (),
	observe: (callback: (value: T) -> ()) -> () -> (),
}

const function createObservable<T>(initial: T): Observable<T>
	local value: T = initial
	const observers: { [number]: (value: T) -> () } = {}
	local nextId = 0

	return {
		get = function(): T
			return value
		end,
		set = function(newValue: T)
			if value == newValue then
				return
			end
			value = newValue
			for _, callback in observers do
				safeCall(callback, newValue)
			end
		end,
		observe = function(callback: (value: T) -> ()): () -> ()
			const id = nextId
			nextId += 1
			observers[id] = callback
			safeCall(callback, value) -- fire immediately with current value
			return function()
				observers[id] = nil
			end
		end,
	}
end

const activePayloadObs = createObservable(nil :: Payload?)
const hoveredTargetObs = createObservable(nil :: TargetDescriptor?)

const DragStarted = Signal.new()
const Dropped = Signal.new()
const DragEnded = Signal.new()

--------------------------------------------------------------------------------
--// Test seam //--
--------------------------------------------------------------------------------

-- The controller and its backends read their environment through this one table
-- so specs can drive the machine headlessly (no real rendering / device input).
-- `_setEnv` patches it in place and the same table is handed to the backends, so
-- there is only ever one live environment identity. See Types.Env for the shape.
const DefaultEnv: Types.Env = {
	-- Rendering + preferred-input + clock.
	MountGhost = GhostLayer.mount,
	ObserveInputClass = InputUtil.ObserveInputClass,
	CurrentInputClass = InputUtil.CurrentInputClass,
	GuiObjectsAt = InputUtil.GuiObjectsAt,
	Clock = os.clock,
	-- Pointer input.
	InputBegan = UserInputService.InputBegan :: any,
	InputChanged = UserInputService.InputChanged :: any,
	InputEnded = UserInputService.InputEnded :: any,
	RenderStepped = RunService.RenderStepped :: any,
	PointerLocation = InputUtil.PointerLocation,
	-- Selection input.
	SelectionChanged = GuiService:GetPropertyChangedSignal("SelectedObject") :: any,
	GetSelectedObject = function(): Instance?
		return GuiService.SelectedObject
	end,
	BindAction = function(name, handler, priority, ...)
		-- createTouchButton is always false: grab-mode drop/cancel never surface a
		-- mobile button (touch uses the pointer backend, not selection).
		ContextActionService:BindActionAtPriority(name, handler, false, priority, ...)
	end,
	UnbindAction = function(name: string)
		ContextActionService:UnbindAction(name)
	end,
	Delay = function(seconds: number, callback: () -> ()): () -> ()
		const thread = task.delay(seconds, callback)
		return function()
			task.cancel(thread)
		end
	end,
}
local Env: Types.Env = table.clone(DefaultEnv)

--------------------------------------------------------------------------------
--// Registries + backend lifecycle //--
--------------------------------------------------------------------------------

const sources: { [Instance]: SourceEntry } = {}
const targets: { [Instance]: TargetEntry } = {}

const backends: { Types.Backend } = {}
local backendsActive = false
local inputMode: InputMode = "Automatic"

const function hasRegistrations(): boolean
	return next(sources) ~= nil or next(targets) ~= nil
end

const function startBackends()
	if backendsActive then
		return
	end
	backendsActive = true
	for _, backend in backends do
		backend.Start()
	end
end

const function stopBackends()
	if not backendsActive then
		return
	end
	backendsActive = false
	for _, backend in backends do
		backend.Stop()
	end
end

const function reconcileBackends()
	if inputMode == "Automatic" and hasRegistrations() then
		startBackends()
	else
		stopBackends()
	end
end

--------------------------------------------------------------------------------
--// Compatibility gates //--
--------------------------------------------------------------------------------

-- Does the payload's `Tags` share at least one entry with the target's `Accepts`?
-- A target with no `Accepts` (nil or empty) takes anything. Tags travel with the
-- payload, so a source whose contents vary matches per lift.
const function tagsAccepted(targetEntry: TargetEntry, payload: Payload): boolean
	const accepts = targetEntry.Options.Accepts
	if accepts == nil or #accepts == 0 then
		return true
	end
	const tags = payload.Tags
	if tags == nil then
		return false
	end
	for _, tag in tags do
		if table.find(accepts, tag) then
			return true
		end
	end
	return false
end

-- Full drop gate: tag compatibility, then the target's optional CanDrop.
const function canDropInto(sourceEntry: SourceEntry?, targetEntry: TargetEntry?, payload: Payload): boolean
	if not sourceEntry or not targetEntry then
		return false
	end
	if not tagsAccepted(targetEntry, payload) then
		return false
	end
	const predicate = targetEntry.Options.CanDrop
	if predicate then
		const ok, result = pcall(predicate, payload)
		return ok and result == true
	end
	return true
end

-- Disable scrolling on the source's ancestor ScrollingFrames (up to the nearest
-- LayerCollector) for the duration of the drag, recording prior values so
-- cancels/errors still restore them.
const function lockAncestorScrolling(instance: Instance, janitor: any)
	local current = instance.Parent
	while current do
		if current:IsA("ScrollingFrame") then
			const frame = current :: ScrollingFrame
			if frame.ScrollingEnabled then
				frame.ScrollingEnabled = false
				janitor:Add(function()
					pcall(function()
						frame.ScrollingEnabled = true
					end)
				end, true)
			end
		end
		if current:IsA("LayerCollector") then
			break
		end
		current = current.Parent
	end
end

--------------------------------------------------------------------------------
--// State machine //--
--------------------------------------------------------------------------------

local state: any = { Kind = "Idle" }
local dragGeneration = 0
local lastDragEndClock = -math.huge
local pendingWatch: (() -> ())? = nil

const function clearPendingWatch()
	if pendingWatch then
		pendingWatch()
		pendingWatch = nil
	end
end

const function updateHover(rawEntry: TargetEntry?)
	if state.Kind ~= "Dragging" then
		return
	end
	local entry = rawEntry
	if entry and not canDropInto(state.Source, entry, state.Payload) then
		entry = nil
	end
	if state.HoveredTarget == entry then
		return
	end

	if state.HoveredTarget then
		safeCall(state.HoveredTarget.Options.OnHoverChanged, nil)
	end
	state.HoveredTarget = entry

	if entry then
		hoveredTargetObs.set { Instance = entry.Instance, Metadata = entry.Options.Metadata or {} }
		safeCall(entry.Options.OnHoverChanged, state.Payload)
		if state.GhostStyle == "Snap" then
			state.Ghost.SnapToRect(entry.Instance.AbsolutePosition, entry.Instance.AbsoluteSize)
		end
	else
		hoveredTargetObs.set(nil)
		if state.GhostStyle == "Snap" then
			state.Ghost.SnapToRect(state.Source.Instance.AbsolutePosition, state.Source.Instance.AbsoluteSize)
		end
	end
end

-- Shared exit path for both drop and cancel. Order is load-bearing: reset state,
-- restore/teardown via the janitor, then fire user callbacks.
const function endDrag(dragging: any, dropDescriptor: TargetDescriptor?)
	state = { Kind = "Idle" }
	lastDragEndClock = Env.Clock()
	clearPendingWatch()

	const hovered: TargetEntry? = dragging.HoveredTarget
	dragging.Janitor:Cleanup()

	activePayloadObs.set(nil)
	hoveredTargetObs.set(nil)

	if hovered then
		safeCall(hovered.Options.OnHoverChanged, nil)
	end
	if dropDescriptor and hovered then
		safeCall(hovered.Options.OnDrop, dragging.Payload, dropDescriptor)
		Dropped:Fire(dragging.Payload, dropDescriptor)
	end
	safeCall(dragging.Source.Options.OnDragEnd, dragging.Payload, dropDescriptor ~= nil)
	DragEnded:Fire(dragging.Payload, dropDescriptor)
end

const function drop(): boolean
	if state.Kind ~= "Dragging" then
		return false
	end
	const dragging = state
	local descriptor: TargetDescriptor? = nil
	if dragging.HoveredTarget and canDropInto(dragging.Source, dragging.HoveredTarget, dragging.Payload) then
		descriptor = {
			Instance = dragging.HoveredTarget.Instance,
			Metadata = dragging.HoveredTarget.Options.Metadata or {},
		}
	end
	endDrag(dragging, descriptor)
	return descriptor ~= nil
end

const function cancelDrag()
	if state.Kind ~= "Dragging" then
		return
	end
	endDrag(state, nil)
end

-- Enter Dragging from either a resolved Pending (backend lift) or directly
-- (BeginDrag). `params.Controlled` suppresses the automatic cancels.
type EnterParams = {
	Source: SourceEntry,
	Payload: Payload,
	Device: Device,
	InputClass: string,
	InputObject: InputLike?,
	GrabPoint: Vector2,
	Controlled: boolean,
	GhostStyle: "Follow" | "Snap",
}

const function enterDragging(params: EnterParams)
	const source = params.Source
	const payload = params.Payload
	const janitor = Janitor.new()

	lockAncestorScrolling(source.Instance, janitor)

	const ghost = Env.MountGhost {
		BuildGhost = source.Options.BuildGhost,
		Payload = payload,
		SourceInstance = source.Instance,
		GrabPoint = params.GrabPoint,
		Container = getConfig("GhostContainer"),
		SnapSpeed = getConfig("SnapSpeed"),
	}
	janitor:Add(ghost.Cleanup, true)

	-- The source vanishing mid-drag must cancel (and restore scroll locks).
	janitor:Add(source.Instance.Destroying:Connect(function()
		cancelDrag()
	end))

	if not params.Controlled then
		-- A real preferred-input class switch mid-drag cancels (revert). The
		-- observer only fires on an actual change to a different class, so any
		-- fire here is a genuine device switch.
		janitor:Add(
			Env.ObserveInputClass(function()
				cancelDrag()
			end),
			true
		)
		-- Losing window focus or opening the Roblox menu mid-drag would otherwise
		-- strand the ghost (InputEnded may never arrive).
		janitor:Add(UserInputService.WindowFocusReleased:Connect(function()
			cancelDrag()
		end))
		janitor:Add(GuiService.MenuOpened:Connect(function()
			cancelDrag()
		end))
	end

	-- A consumer-supplied ghost container dying mid-drag also strands the drag.
	const container = getConfig("GhostContainer")
	if container then
		janitor:Add((container :: Instance).Destroying:Connect(function()
			cancelDrag()
		end))
	end

	dragGeneration += 1
	state = {
		Kind = "Dragging",
		Source = source,
		Payload = payload,
		Device = params.Device,
		InputClass = params.InputClass,
		InputObject = params.InputObject,
		Ghost = ghost,
		GhostStyle = params.GhostStyle,
		HoveredTarget = nil :: TargetEntry?,
		Controlled = params.Controlled,
		Generation = dragGeneration,
		Janitor = janitor,
	}

	activePayloadObs.set(payload)
	safeCall(source.Options.OnLift, payload)
	DragStarted:Fire(payload, source.Instance)

	-- Initial ghost placement.
	if params.GhostStyle == "Follow" then
		ghost.FollowPointer(params.GrabPoint)
	else
		ghost.SnapToRect(source.Instance.AbsolutePosition, source.Instance.AbsoluteSize)
	end
end

const function press(entry: SourceEntry?, absPos: Vector2, inputObject: InputLike?, device: Device)
	if state.Kind ~= "Idle" or not entry then
		return
	end
	const ok, payload = pcall(entry.Options.GetPayload)
	if not ok then
		warn("[DragDrop] GetPayload error:", payload)
		return
	end
	if payload == nil then
		return -- source refused the lift (empty slot, disabled, ...)
	end
	clearPendingWatch()
	state = {
		Kind = "Pending",
		Source = entry,
		Payload = payload,
		StartPos = absPos,
		InputObject = inputObject,
		Device = device,
		InputClass = Env.CurrentInputClass(),
	}
	-- A device switch during the press aborts the pending lift (#5). Same-class
	-- inputs (mouse↔keyboard) do not fire this.
	pendingWatch = Env.ObserveInputClass(function()
		if state.Kind == "Pending" then
			clearPendingWatch()
			state = { Kind = "Idle" }
		end
	end)
end

const function lift()
	if state.Kind ~= "Pending" then
		return
	end
	const pending = state
	clearPendingWatch()
	const ghostStyle: "Follow" | "Snap" = if pending.Device == "Gamepad" or pending.Device == "Keyboard"
		then "Snap"
		else "Follow"
	enterDragging {
		Source = pending.Source,
		Payload = pending.Payload,
		Device = pending.Device,
		InputClass = pending.InputClass,
		InputObject = pending.InputObject,
		GrabPoint = pending.StartPos,
		Controlled = false,
		GhostStyle = ghostStyle,
	}
end

const function releaseAsClick()
	if state.Kind ~= "Pending" then
		return
	end
	const pending = state
	clearPendingWatch()
	state = { Kind = "Idle" }
	safeCall(pending.Source.Options.OnActivated)
end

const function abortPending()
	if state.Kind ~= "Pending" then
		return
	end
	clearPendingWatch()
	state = { Kind = "Idle" }
end

--------------------------------------------------------------------------------
--// Hit-testing (pointer control) //--
--------------------------------------------------------------------------------

const function hitTestTarget(absPos: Vector2): TargetEntry?
	for _, gui in Env.GuiObjectsAt(absPos) do
		const entry = InputUtil.ResolveRegistered(targets, gui)
		if entry then
			return entry
		end
	end
	return nil
end

--------------------------------------------------------------------------------
--// DragHandle //--
--------------------------------------------------------------------------------

const function createHandle(generation: number, payload: Payload): DragHandle
	const function isActive(): boolean
		return state.Kind == "Dragging" and state.Generation == generation
	end

	const handle = {}

	function handle.MoveTo(_self: DragHandle, position: Vector2)
		if not isActive() then
			return
		end
		state.Ghost.FollowPointer(position)
		updateHover(hitTestTarget(position))
	end

	function handle.SetHoveredTarget(_self: DragHandle, target: GuiObject?): boolean
		if not isActive() then
			return false
		end
		if target == nil then
			updateHover(nil)
			return true
		end
		const entry = InputUtil.ResolveRegistered(targets, target)
		if not entry or not canDropInto(state.Source, entry, state.Payload) then
			return false
		end
		updateHover(entry)
		return true
	end

	function handle.Drop(_self: DragHandle): boolean
		if not isActive() then
			return false
		end
		return drop()
	end

	function handle.Cancel(_self: DragHandle)
		if not isActive() then
			return
		end
		cancelDrag()
	end

	function handle.IsActive(_self: DragHandle): boolean
		return isActive()
	end

	function handle.GetPayload(_self: DragHandle): Payload
		return payload
	end

	return handle :: any
end

--------------------------------------------------------------------------------
--// Public controller surface //--
--------------------------------------------------------------------------------

const Controller = {}

Controller.DragStarted = DragStarted
Controller.Dropped = Dropped
Controller.DragEnded = DragEnded

function Controller.RegisterSource(instance: GuiObject, options: Types.SourceOptions): Types.Unregister
	const entry: SourceEntry = { Instance = instance, Options = options }
	sources[instance] = entry

	local destroyingConnection: RBXScriptConnection? = nil
	const function unregister()
		if sources[instance] == entry then
			sources[instance] = nil
		end
		if destroyingConnection then
			destroyingConnection:Disconnect()
			destroyingConnection = nil
		end
		if state.Kind ~= "Idle" and state.Source == entry then
			Controller.Cancel()
		end
		reconcileBackends()
	end

	destroyingConnection = instance.Destroying:Connect(unregister)
	reconcileBackends()
	return unregister
end

function Controller.RegisterTarget(instance: GuiObject, options: Types.TargetOptions): Types.Unregister
	const entry: TargetEntry = { Instance = instance, Options = options }
	targets[instance] = entry

	local destroyingConnection: RBXScriptConnection? = nil
	const function unregister()
		if targets[instance] == entry then
			targets[instance] = nil
		end
		if destroyingConnection then
			destroyingConnection:Disconnect()
			destroyingConnection = nil
		end
		if state.Kind == "Dragging" and state.HoveredTarget == entry then
			updateHover(nil)
		end
		reconcileBackends()
	end

	destroyingConnection = instance.Destroying:Connect(unregister)
	reconcileBackends()
	return unregister
end

function Controller.BeginDrag(instance: GuiObject, position: Vector2?): DragHandle?
	if state.Kind ~= "Idle" then
		return nil
	end
	const entry = InputUtil.ResolveRegistered(sources, instance)
	if not entry then
		return nil
	end
	const ok, payload = pcall(entry.Options.GetPayload)
	if not ok then
		warn("[DragDrop] GetPayload error:", payload)
		return nil
	end
	if payload == nil then
		return nil
	end

	const controlled = inputMode == "Scriptable" or position ~= nil
	local ghostStyle: "Follow" | "Snap"
	local grabPoint: Vector2
	local device: Device
	if position ~= nil then
		ghostStyle = "Follow"
		grabPoint = position
		device = "Mouse"
	else
		ghostStyle = "Snap"
		grabPoint = entry.Instance.AbsolutePosition + entry.Instance.AbsoluteSize / 2
		device = if Env.CurrentInputClass() == "Gamepad" then "Gamepad" else "Keyboard"
	end

	enterDragging {
		Source = entry,
		Payload = payload,
		Device = device,
		InputClass = Env.CurrentInputClass(),
		InputObject = nil,
		GrabPoint = grabPoint,
		Controlled = controlled,
		GhostStyle = ghostStyle,
	}
	if state.Kind ~= "Dragging" then
		return nil
	end
	return createHandle(state.Generation, payload)
end

function Controller.SetInputMode(mode: InputMode)
	if mode ~= "Automatic" and mode ~= "Scriptable" then
		error(`[DragDrop] Invalid input mode: {tostring(mode)}`, 2)
	end
	if mode == inputMode then
		return
	end
	Controller.Cancel() -- clean slate across a mode switch
	inputMode = mode
	reconcileBackends()
end

function Controller.GetInputMode(): InputMode
	return inputMode
end

function Controller.Drop(): boolean
	return drop()
end

function Controller.Cancel()
	if state.Kind == "Dragging" then
		cancelDrag()
	elseif state.Kind == "Pending" then
		abortPending()
	end
end

function Controller.IsDragging(): boolean
	return state.Kind == "Dragging"
end

function Controller.GetActivePayload(): Payload?
	return activePayloadObs.get()
end

function Controller.GetHoveredTarget(): TargetDescriptor?
	return hoveredTargetObs.get()
end

function Controller.ObserveActivePayload(callback: (Payload?) -> ()): Types.Unregister
	return activePayloadObs.observe(callback)
end

function Controller.ObserveHoveredTarget(callback: (TargetDescriptor?) -> ()): Types.Unregister
	return hoveredTargetObs.observe(callback)
end

function Controller.ConsumeActivation(): boolean
	return (Env.Clock() - lastDragEndClock) < ACTIVATION_CONSUME_WINDOW
end

function Controller.Configure(config: Types.Config)
	assert(typeof(config) == "table", "[DragDrop] Configure expects a table")
	for key, value in config :: { [string]: any } do
		const expectedKind = CONFIG_KINDS[key]
		if not expectedKind then
			error(`[DragDrop] Unknown config key: {tostring(key)}`, 2)
		end
		if expectedKind == "LayerCollector" then
			if typeof(value) ~= "Instance" or not (value :: Instance):IsA("LayerCollector") then
				error(`[DragDrop] Config.{key} must be a LayerCollector`, 2)
			end
		elseif typeof(value) ~= expectedKind then
			error(`[DragDrop] Config.{key} must be a {expectedKind}, got {typeof(value)}`, 2)
		end
		Config[key] = value
	end
end

-- Restore every config key to its default. This is the only way to CLEAR an
-- optional key (GhostContainer, KeyboardCancelKeyCode): Configure can't accept
-- nil for them because nil values vanish from Luau tables.
function Controller.ResetConfig()
	for key in Config do
		Config[key] = nil
	end
	for key, value in DEFAULTS do
		Config[key] = value
	end
end

--------------------------------------------------------------------------------
--// Test seam (underscore-private) //--
--------------------------------------------------------------------------------

-- Injected transition surface, shared with backends and exposed for specs.
const api: Types.TransitionSurface = {
	Press = press,
	Lift = lift,
	ReleaseAsClick = releaseAsClick,
	AbortPending = abortPending,
	UpdateHover = updateHover,
	Drop = drop,
	CancelDrag = cancelDrag,
	GetState = function()
		return state
	end,
	ResolveSource = function(instance: Instance?): SourceEntry?
		return InputUtil.ResolveRegistered(sources, instance)
	end,
	ResolveTarget = function(instance: Instance?): TargetEntry?
		return InputUtil.ResolveRegistered(targets, instance)
	end,
	HitTestTarget = hitTestTarget,
	BeginSelectionDrag = function(instance: GuiObject): DragHandle?
		return Controller.BeginDrag(instance, nil)
	end,
	IsDragging = Controller.IsDragging,
	GetConfig = getConfig,
	DragStarted = DragStarted :: any,
	DragEnded = DragEnded :: any,
}

Controller._api = api

function Controller._setEnv(patch: { [string]: any })
	for key, value in patch do
		(Env :: any)[key] = value
	end
end

function Controller._resetEnv()
	-- Refill in place rather than reassigning: the backends captured this exact
	-- table at construction, so the identity must stay stable.
	table.clear(Env :: any)
	for key, value in DefaultEnv :: any do
		(Env :: any)[key] = value
	end
end

--------------------------------------------------------------------------------
--// Backend wiring //--
--------------------------------------------------------------------------------

if RunService:IsClient() then
	table.insert(backends, PointerBackend(api, Env))
	table.insert(backends, SelectionBackend(api, Env))
end

return Controller
