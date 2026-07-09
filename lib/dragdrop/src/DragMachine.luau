--[[
	DragDrop — the device-agnostic drag state machine.

	State:  Idle → Pending (press captured; threshold/hold not yet resolved)
	              → Dragging (payload airborne; ghost + scroll locks live)
	              → Idle

	Owns the DragState and every transition over it, pointer hit-testing, the
	per-drag Janitor (ghost + scroll locks + mid-drag cancel observers), the
	DragHandle factory, and the TransitionSurface (`DragMachine.Api`) that the
	device backends — and specs — drive it through. Backends are pure
	translators: they never touch state directly, only call the Api.

	Every exit from Dragging runs the per-drag Janitor (restoring ScrollingFrame
	locks and tearing down the ghost + observers) BEFORE any user callback fires,
	and all user callbacks are pcall-guarded, so a throwing OnDrop can never leave
	a scrolling list permanently locked.

	Scriptable/controlled drags (Scriptable input mode, or a positioned
	BeginDrag) are owned by the caller: the automatic backends ignore them and the
	preferred-input / focus cancels do not apply.
]]

const UserInputService = game:GetService("UserInputService")
const GuiService = game:GetService("GuiService")

const Janitor = require("../Janitor")

const Types = require("./Types")
const Config = require("./Config")
const Registry = require("./Registry")
const Matching = require("./Matching")
const Reactive = require("./Reactive")
const EnvModule = require("./Env")

type Payload = Types.Payload
type Device = Types.Device
type SourceEntry = Types.SourceEntry
type TargetEntry = Types.TargetEntry
type TargetDescriptor = Types.TargetDescriptor
type DragHandle = Types.DragHandle
type InputLike = Types.InputLike
type DragState = Types.DragState
type DraggingState = Types.DraggingState
type EnterParams = Types.EnterParams
type GhostStyle = Types.GhostStyle

const getConfig = Config.Get
const safeCall = Reactive.SafeCall
const canDropInto = Matching.CanDropInto

const activePayloadObs = Reactive.ActivePayload
const hoveredTargetObs = Reactive.HoveredTarget

const DragStarted = Reactive.DragStarted
const Dropped = Reactive.Dropped
const DragEnded = Reactive.DragEnded

-- The live Env seam; patched in place by the test harness (see Env.luau).
const Env = EnvModule.Env

-- Window after a drag ends during which a stray Activated should be swallowed
-- (see ConsumeActivation).
const ACTIVATION_CONSUME_WINDOW = 0.05

const DragMachine = {}

--------------------------------------------------------------------------------
--// State //--
--------------------------------------------------------------------------------

local state: DragState = { Kind = "Idle" }
local dragGeneration = 0
local lastDragEndClock = -math.huge
local pendingWatch: (() -> ())? = nil
-- Last pointer position the backend reported this drag, for the re-hover throttle
-- (#7). Owned here because the ghost is: reset per drag in enterDragging.
local lastReportPos: Vector2? = nil

-- Device → ghost placement style. Pointer devices follow the cursor; selection
-- devices snap between slots. The single place this mapping is decided.
const function ghostStyleForDevice(device: Device): GhostStyle
	return if device == "Gamepad" or device == "Keyboard" then "Snap" else "Follow"
end

const function clearPendingWatch()
	if pendingWatch then
		pendingWatch()
		pendingWatch = nil
	end
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
--// Transitions //--
--------------------------------------------------------------------------------

const function updateHover(rawEntry: TargetEntry?)
	-- Narrowed snapshot; same table identity as `state`, so mutating it is live.
	const dragging = state
	if dragging.Kind ~= "Dragging" then
		return
	end
	local entry = rawEntry
	if entry and not canDropInto(dragging.Source, entry, dragging.Payload) then
		entry = nil
	end
	if dragging.HoveredTarget == entry then
		return
	end

	if dragging.HoveredTarget then
		safeCall(dragging.HoveredTarget.Options.OnHoverChanged, nil)
	end
	dragging.HoveredTarget = entry

	if entry then
		hoveredTargetObs.set { Instance = entry.Instance, Metadata = entry.Options.Metadata or {} }
		safeCall(entry.Options.OnHoverChanged, dragging.Payload)
		if dragging.GhostStyle == "Snap" then
			dragging.Ghost.SnapToRect(entry.Instance.AbsolutePosition, entry.Instance.AbsoluteSize)
		end
	else
		hoveredTargetObs.set(nil)
		if dragging.GhostStyle == "Snap" then
			dragging.Ghost.SnapToRect(dragging.Source.Instance.AbsolutePosition, dragging.Source.Instance.AbsoluteSize)
		end
	end
end

-- Shared exit path for both drop and cancel. Order is load-bearing: reset state,
-- restore/teardown via the janitor, then fire user callbacks.
const function endDrag(dragging: DraggingState, dropDescriptor: TargetDescriptor?)
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
	const dragging = state
	if dragging.Kind ~= "Dragging" then
		return false
	end
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
	const dragging = state
	if dragging.Kind ~= "Dragging" then
		return
	end
	endDrag(dragging, nil)
end

-- Enter Dragging from either a resolved Pending (backend lift) or directly
-- (Begin). `params.Controlled` suppresses the automatic cancels.
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
	lastReportPos = nil -- a fresh drag re-hit-tests on its first reported frame
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
	-- Guard on a snapshot, not `state` itself: refining the upvalue here would
	-- leak an Idle refinement into the observer closure below.
	const st = state
	if st.Kind ~= "Idle" or not entry then
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
	const pending = state
	if pending.Kind ~= "Pending" then
		return
	end
	clearPendingWatch()
	enterDragging {
		Source = pending.Source,
		Payload = pending.Payload,
		Device = pending.Device,
		InputClass = pending.InputClass,
		InputObject = pending.InputObject,
		GrabPoint = pending.StartPos,
		Controlled = false,
		GhostStyle = ghostStyleForDevice(pending.Device),
	}
end

const function releaseAsClick()
	const pending = state
	if pending.Kind ~= "Pending" then
		return
	end
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
		const entry = Registry.ResolveTarget(gui)
		if entry then
			return entry
		end
	end
	return nil
end

-- The pointer backend reports the live pointer here (every render frame while a
-- Follow drag is airborne, and once more at release). The machine is the sole
-- owner of the ghost, so it — not the backend — drives Follow placement and the
-- re-hover from the reported position. Snap drags never reach here (selection
-- devices place the ghost through updateHover), and controlled drags are ignored
-- by the backend, so the Follow guard is all that's needed.
const function reportPointer(absPos: Vector2, forceHover: boolean?)
	const dragging = state
	if dragging.Kind ~= "Dragging" or dragging.GhostStyle ~= "Follow" then
		return
	end
	dragging.Ghost.FollowPointer(absPos)
	-- Only re-hit-test when the pointer actually moved (#7) — except at the release
	-- commit (forceHover), which must resolve the drop target fresh regardless.
	if forceHover or lastReportPos == nil or (absPos - lastReportPos).Magnitude > 0 then
		lastReportPos = absPos
		updateHover(hitTestTarget(absPos))
	end
end

--------------------------------------------------------------------------------
--// DragHandle //--
--------------------------------------------------------------------------------

const function createHandle(generation: number, payload: Payload): DragHandle
	-- The live drag this handle controls, narrowed; nil once it has ended.
	const function activeState(): DraggingState?
		const dragging = state
		if dragging.Kind == "Dragging" and dragging.Generation == generation then
			return dragging
		end
		return nil
	end

	const handle = {}

	function handle.MoveTo(_self: DragHandle, position: Vector2)
		const dragging = activeState()
		if not dragging then
			return
		end
		dragging.Ghost.FollowPointer(position)
		updateHover(hitTestTarget(position))
	end

	function handle.SetHoveredTarget(_self: DragHandle, target: GuiObject?): boolean
		const dragging = activeState()
		if not dragging then
			return false
		end
		if target == nil then
			updateHover(nil)
			return true
		end
		const entry = Registry.ResolveTarget(target)
		if not entry or not canDropInto(dragging.Source, entry, dragging.Payload) then
			return false
		end
		updateHover(entry)
		return true
	end

	function handle.Drop(_self: DragHandle): boolean
		if not activeState() then
			return false
		end
		return drop()
	end

	function handle.Cancel(_self: DragHandle)
		if not activeState() then
			return
		end
		cancelDrag()
	end

	function handle.IsActive(_self: DragHandle): boolean
		return activeState() ~= nil
	end

	function handle.GetPayload(_self: DragHandle): Payload
		return payload
	end

	return handle :: any
end

--------------------------------------------------------------------------------
--// Machine surface (consumed by the assembler) //--
--------------------------------------------------------------------------------

-- Enter Dragging directly from a resolved source entry (the programmatic
-- BeginDrag path; the caller decides grab point, device, and ownership).
-- Returns the controlling handle, or nil if the machine is busy or the source
-- refuses the lift.
function DragMachine.Begin(entry: SourceEntry, grabPoint: Vector2, device: Device, controlled: boolean): DragHandle?
	const st = state
	if st.Kind ~= "Idle" then
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

	enterDragging {
		Source = entry,
		Payload = payload,
		Device = device,
		InputClass = Env.CurrentInputClass(),
		InputObject = nil,
		GrabPoint = grabPoint,
		Controlled = controlled,
		GhostStyle = ghostStyleForDevice(device),
	}
	const after = state
	if after.Kind ~= "Dragging" then
		return nil
	end
	return createHandle(after.Generation, payload)
end

DragMachine.Drop = drop

-- Revert the active drag, or abort a pending press. No-op when idle.
function DragMachine.Cancel()
	if state.Kind == "Dragging" then
		cancelDrag()
	elseif state.Kind == "Pending" then
		abortPending()
	end
end

function DragMachine.IsDragging(): boolean
	return state.Kind == "Dragging"
end

function DragMachine.ConsumeActivation(): boolean
	return (Env.Clock() - lastDragEndClock) < ACTIVATION_CONSUME_WINDOW
end

-- Registry unregister hooks (injected by the assembler, so Registry never
-- requires the machine): release whatever the machine holds from `entry`.
function DragMachine.CancelIfSource(entry: SourceEntry)
	const st = state
	if st.Kind ~= "Idle" and st.Source == entry then
		DragMachine.Cancel()
	end
end

function DragMachine.ReleaseHoverIfTarget(entry: TargetEntry)
	const st = state
	if st.Kind == "Dragging" and st.HoveredTarget == entry then
		updateHover(nil)
	end
end

-- An unpositioned selection-grab lift, routed back through the public BeginDrag
-- (which owns input mode). Injected by the assembler to avoid a machine →
-- assembler require cycle.
local beginSelectionDrag: ((instance: GuiObject) -> DragHandle?)? = nil

function DragMachine.SetBeginSelectionDrag(fn: (instance: GuiObject) -> DragHandle?)
	beginSelectionDrag = fn
end

--------------------------------------------------------------------------------
--// Transition surface //--
--------------------------------------------------------------------------------

-- The injected surface the backends (and specs, via Core._api) drive the
-- machine through.
DragMachine.Api = {
	Press = press,
	Lift = lift,
	ReleaseAsClick = releaseAsClick,
	AbortPending = abortPending,
	UpdateHover = updateHover,
	ReportPointer = reportPointer,
	Drop = drop,
	CancelDrag = cancelDrag,
	GetState = function()
		return state
	end,
	ResolveSource = Registry.ResolveSource,
	ResolveTarget = Registry.ResolveTarget,
	HitTestTarget = hitTestTarget,
	BeginSelectionDrag = function(instance: GuiObject): DragHandle?
		const begin = beginSelectionDrag
		assert(begin, "[DragDrop] BeginSelectionDrag used before the assembler wired it")
		return begin(instance)
	end,
	IsDragging = DragMachine.IsDragging,
	GetConfig = Config.Get,
	DragStarted = DragStarted :: any,
	DragEnded = DragEnded :: any,
} :: Types.TransitionSurface

return DragMachine
