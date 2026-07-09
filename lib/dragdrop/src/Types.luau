--[[
	DragDrop — shared type definitions.

	The drag system is data-agnostic: it carries an opaque `Payload` (anything
	with a `Type` discriminator) from a registered source to a registered target,
	and emits intent via the target's `OnDrop`. Nothing in this system inspects a
	payload past its `Type` field.

	See DragDrop.luau for the public facade and API docs.
]]

const Signal = require("../Signal")
const Janitor = require("../Janitor")

type Janitor = Janitor.Janitor

--// Public types //--

-- A signal typed by its handler function and the arguments it fires with.
export type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

--[=[
	@type Payload { Tags: { string }, [string]: any }
	@within DragDrop

	The opaque value carried by a drag. `Tags` is the only field the system reads:
	it lists the payload's kinds for target compatibility — a target's `Accepts`
	takes the drag if it shares at least one tag. Everything else is yours to
	shape (guids, indices, a display name for your ghost, ...).

	Because `Tags` travels with the payload and `GetPayload` runs on every lift, a
	source whose contents vary can return different tags per lift — e.g. a bag
	slot returns `{ "Item", "Food" }` for a ration and `{ "Item", "Weapon" }` for
	a sword, and each matches the right target.
]=]
export type Payload = {
	Tags: { string },
	[string]: any,
}

--[=[
	@interface TargetDescriptor
	@within DragDrop
	.Instance GuiObject -- The registered target the drop resolved onto.
	.Metadata { [any]: any } -- Whatever `Metadata` the target registered with.

	Handed to a target's `OnDrop` and returned by [DragDrop.GetHoveredTarget].
]=]
export type TargetDescriptor = {
	Instance: GuiObject,
	Metadata: { [any]: any },
}

--[=[
	@interface SourceOptions
	@within DragDrop
	.GetPayload () -> Payload? -- Returns the payload to lift, or nil to refuse the lift (empty slot, disabled, ...). Called on press.
	.OnActivated (() -> ())? -- Press + release without crossing the drag threshold (a "click").
	.OnLift ((payload: Payload) -> ())? -- Fired the moment the payload goes airborne.
	.OnDragEnd ((payload: Payload, dropped: boolean) -> ())? -- Fired on every drag end. `dropped=false` means cancelled/reverted.
	.BuildGhost ((payload: Payload, source: GuiObject) -> GuiObject)? -- Builds the dragged proxy. Strongly recommended; nil falls back to a bare debug plate.
]=]
export type SourceOptions = {
	GetPayload: () -> Payload?,
	OnActivated: (() -> ())?,
	OnLift: ((payload: Payload) -> ())?,
	OnDragEnd: ((payload: Payload, dropped: boolean) -> ())?,
	-- Ghost contract: the returned GuiObject is parented into a container sized to
	-- the source's on-screen footprint. `Size = UDim2.fromScale(1, 1)` matches the
	-- source; any explicit Size overrides it. All appearance (tilt, transparency,
	-- scale) is the builder's business. The instance is destroyed on drag end.
	-- Practically every source should supply this — the built-in fallback is a
	-- bare debug plate, not something to ship.
	BuildGhost: ((payload: Payload, source: GuiObject) -> GuiObject)?,
}

--[=[
	@interface TargetOptions
	@within DragDrop
	.Accepts { string }? -- Tags this target accepts; matches if it shares at least one tag with the payload's `Tags`. Empty or omitted accepts any payload.
	.CanDrop ((payload: Payload) -> boolean)? -- Optional finer gate, checked in addition to `Accepts`.
	.OnDrop (payload: Payload, target: TargetDescriptor) -> () -- Called when a compatible payload is dropped here.
	.OnHoverChanged ((payload: Payload?) -> ())? -- `payload` on enter, nil on leave.
	.Metadata { [any]: any }? -- Arbitrary data surfaced back through `TargetDescriptor.Metadata`.
]=]
export type TargetOptions = {
	Accepts: { string }?,
	CanDrop: ((payload: Payload) -> boolean)?,
	OnDrop: (payload: Payload, target: TargetDescriptor) -> (),
	OnHoverChanged: ((payload: Payload?) -> ())?,
	Metadata: { [any]: any }?,
}

--[=[
	@type InputMode "Automatic" | "Scriptable"
	@within DragDrop

	`Automatic` (default) wires the pointer and selection backends to real device
	input. `Scriptable` disables them so the only way a drag starts or moves is
	through [DragDrop.BeginDrag] and the returned [DragHandle] — like putting a
	camera in Scriptable mode.
]=]
export type InputMode = "Automatic" | "Scriptable"

--[=[
	@interface Config
	@within DragDrop
	.DragThresholdPx number? -- Mouse: movement past this (in pixels) lifts. Default 8.
	.TouchSlopPx number? -- Touch: movement past this before the hold fires = scroll, not lift. Default 12.
	.LongPressSeconds number? -- Touch: hold duration that lifts. Default 0.4.
	.SnapSpeed number? -- Selection mode: slot-to-slot ghost spring speed. Default 30.
	.GhostContainer LayerCollector? -- Parent for ghost mounts. nil = an internal high-DisplayOrder ScreenGui.
	.GamepadLiftKeyCode Enum.KeyCode? -- Button that lifts the selected source. Default ButtonX.
	.GamepadDropKeyCode Enum.KeyCode? -- Button that drops on the selected target. Default ButtonA.
	.GamepadCancelKeyCode Enum.KeyCode? -- Button that cancels a drag. Default ButtonB.
	.KeyboardLiftKeyCode Enum.KeyCode? -- Key that toggles lift/drop in grab mode. Default Return.
	.KeyboardCancelKeyCode Enum.KeyCode? -- Optional explicit keyboard cancel key. Default nil.

	Behavior knobs only — nothing here styles the ghost (that lives in `BuildGhost`).
]=]
export type Config = {
	DragThresholdPx: number?,
	TouchSlopPx: number?,
	LongPressSeconds: number?,
	SnapSpeed: number?,
	GhostContainer: LayerCollector?,
	GamepadLiftKeyCode: Enum.KeyCode?,
	GamepadDropKeyCode: Enum.KeyCode?,
	GamepadCancelKeyCode: Enum.KeyCode?,
	KeyboardLiftKeyCode: Enum.KeyCode?,
	KeyboardCancelKeyCode: Enum.KeyCode?,
}

--[=[
	@interface DragHandle
	@within DragDrop
	.MoveTo (self: DragHandle, position: Vector2) -> () -- Move the ghost to a screen point and hit-test for hover.
	.SetHoveredTarget (self: DragHandle, target: GuiObject?) -> boolean -- Set hover explicitly; false if the target is invalid/incompatible.
	.Drop (self: DragHandle) -> boolean -- End on the current hover; false if there was no valid target (reverted).
	.Cancel (self: DragHandle) -> () -- Revert this drag.
	.IsActive (self: DragHandle) -> boolean -- Whether this handle still controls the live drag.
	.GetPayload (self: DragHandle) -> Payload -- The payload this drag carries.

	A programmatic controller for a single drag, returned by [DragDrop.BeginDrag].
	Every method becomes a no-op (and the mutating ones return false) once the
	drag has ended.
]=]
export type DragHandle = {
	MoveTo: (self: DragHandle, position: Vector2) -> (),
	SetHoveredTarget: (self: DragHandle, target: GuiObject?) -> boolean,
	Drop: (self: DragHandle) -> boolean,
	Cancel: (self: DragHandle) -> (),
	IsActive: (self: DragHandle) -> boolean,
	GetPayload: (self: DragHandle) -> Payload,
}

--[=[
	@type Unregister () -> ()
	@within DragDrop

	Returned by [DragDrop.RegisterSource]/[DragDrop.RegisterTarget] and the
	`Observe*` functions. Call it to tear the registration/observer down.
]=]
export type Unregister = () -> ()

--// Internal types //--

-- A concrete input device. Collapses to an `InputClass` for switch-cancel logic.
export type Device = "Mouse" | "Touch" | "Gamepad" | "Keyboard"

-- Device grouping used to decide whether a preferred-input change should cancel
-- a drag: a keyboard press during a mouse drag stays in `MouseKeyboard` and must
-- NOT cancel, whereas touching the screen (Touch) or a controller (Gamepad) does.
export type InputClass = "MouseKeyboard" | "Touch" | "Gamepad"

export type SourceEntry = {
	Instance: GuiObject,
	Options: SourceOptions,
}

export type TargetEntry = {
	Instance: GuiObject,
	Options: TargetOptions,
}

-- A pluggable input backend. Backends translate raw device input into the
-- drag machine's transition calls; they are started on the first registration (in
-- Automatic mode) and stopped on the last, on Scriptable mode, or on teardown.
export type Backend = {
	Start: () -> (),
	Stop: () -> (),
}

-- Handle returned by the ghost layer for the lifetime of one drag.
export type GhostHandle = {
	-- Pointer devices: keep the captured grab point under `pointerAbs` (canonical
	-- AbsolutePosition space).
	FollowPointer: (pointerAbs: Vector2) -> (),
	-- Selection devices: spring the ghost so it centers on a slot's rect.
	SnapToRect: (absPos: Vector2, absSize: Vector2) -> (),
	Cleanup: () -> (),
}

--// Backend seam types //--

-- The subset of an InputObject that the backends actually read. Real Roblox
-- InputObjects satisfy this structurally; the test harness supplies plain tables
-- of the same shape. Position is in the same space InputObject.Position uses (the
-- backends pass it to InputUtil.InputPosition, which is pure over this field).
export type InputLike = {
	UserInputType: Enum.UserInputType,
	KeyCode: Enum.KeyCode,
	Position: Vector3,
}

-- A disconnectable handle (RBXScriptConnection, or the harness's fake).
export type Connection = { Disconnect: (Connection) -> () }

-- Anything a backend can `:Connect` to. Real Roblox signals and the harness's
-- fake signals both satisfy it; the callback args are left open because different
-- signals fire different shapes and the backends read them positionally.
export type Signalish = { Connect: (self: any, callback: (...any) -> ()) -> Connection }

-- The environment a backend translates input from. The real adapter (built in
-- Env.luau) wires these to UserInputService / GuiService / ContextActionService /
-- task.delay; the test harness installs fakes so gesture logic runs headlessly.
-- This is the seam that makes the input-translation layer testable through its
-- interface rather than around it.
export type Env = {
	-- Rendering + preferred-input + clock (shared with the drag machine's own reads).
	MountGhost: (params: any) -> GhostHandle,
	ObserveInputClass: (callback: (newClass: InputClass) -> ()) -> (() -> ()),
	CurrentInputClass: () -> InputClass,
	GuiObjectsAt: (absPos: Vector2) -> { GuiObject },
	Clock: () -> number,
	-- Pointer input (mouse + touch).
	InputBegan: Signalish,
	InputChanged: Signalish,
	InputEnded: Signalish,
	RenderStepped: Signalish,
	PointerLocation: () -> Vector2,
	-- Selection input (gamepad + keyboard grab mode).
	SelectionChanged: Signalish,
	GetSelectedObject: () -> Instance?,
	BindAction: (
		name: string,
		handler: (name: string, inputState: Enum.UserInputState, input: InputObject) -> Enum.ContextActionResult,
		priority: number,
		...Enum.KeyCode
	) -> (),
	UnbindAction: (name: string) -> (),
	-- Deferred timing for the touch long-press. Returns a canceller. The harness
	-- drives these off its controllable clock so long-press timing is deterministic.
	Delay: (seconds: number, callback: () -> ()) -> (() -> ()),
}

--// Drag state machine (tagged union on `Kind`) //--

-- Ghost placement style, derived from device (see ghostStyleForDevice).
export type GhostStyle = "Follow" | "Snap"

export type IdleState = {
	Kind: "Idle",
}

-- Press captured; the lift threshold / long-press has not resolved yet.
export type PendingState = {
	Kind: "Pending",
	Source: SourceEntry,
	Payload: Payload,
	StartPos: Vector2,
	InputObject: InputLike?,
	Device: Device,
	InputClass: InputClass,
}

-- Payload airborne; ghost + scroll locks live for this state's lifetime.
export type DraggingState = {
	Kind: "Dragging",
	Source: SourceEntry,
	Payload: Payload,
	Device: Device,
	InputClass: InputClass,
	InputObject: InputLike?,
	Ghost: GhostHandle,
	GhostStyle: GhostStyle,
	HoveredTarget: TargetEntry?,
	Controlled: boolean,
	Generation: number,
	Janitor: Janitor,
}

export type DragState = IdleState | PendingState | DraggingState

-- Enter Dragging from either a resolved Pending (backend lift) or directly
-- (BeginDrag). `Controlled` suppresses the automatic cancels.
export type EnterParams = {
	Source: SourceEntry,
	Payload: Payload,
	Device: Device,
	InputClass: InputClass,
	InputObject: InputLike?,
	GrabPoint: Vector2,
	Controlled: boolean,
	GhostStyle: GhostStyle,
}

-- The transition surface the drag machine exposes to its backends (and to specs,
-- as `Core._api`). Backends never touch the machine's state table directly; they
-- call these transitions and read a state snapshot via GetState.
export type TransitionSurface = {
	Press: (entry: SourceEntry?, absPos: Vector2, inputObject: InputLike?, device: Device) -> (),
	Lift: () -> (),
	ReleaseAsClick: () -> (),
	AbortPending: () -> (),
	UpdateHover: (rawEntry: TargetEntry?) -> (),
	-- The pointer backend reports the live pointer here; the drag machine owns the
	-- ghost, so it drives Follow placement and hover from the reported position.
	-- `forceHover` bypasses the movement throttle for the discrete release commit.
	ReportPointer: (absPos: Vector2, forceHover: boolean?) -> (),
	Drop: () -> boolean,
	CancelDrag: () -> (),
	-- The live drag state; backends narrow on `Kind` before reading variant fields.
	GetState: () -> DragState,
	ResolveSource: (instance: Instance?) -> SourceEntry?,
	ResolveTarget: (instance: Instance?) -> TargetEntry?,
	HitTestTarget: (absPos: Vector2) -> TargetEntry?,
	BeginSelectionDrag: (instance: GuiObject) -> DragHandle?,
	IsDragging: () -> boolean,
	GetConfig: (key: string) -> any,
	DragStarted: Signalish,
	DragEnded: Signalish,
}

return {}
