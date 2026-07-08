--[[
	DragDrop — shared type definitions.

	The drag system is data-agnostic: it carries an opaque `Payload` (anything
	with a `Type` discriminator) from a registered source to a registered target,
	and emits intent via the target's `OnDrop`. Nothing in this system inspects a
	payload past its `Type` field.

	See DragDrop.luau for the public facade and API docs.
]]

const Signal = require("../Signal")

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
-- controller's transition calls; they are started on the first registration (in
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

return {}
