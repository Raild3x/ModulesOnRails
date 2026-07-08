# DragDrop — domain glossary

Terminology for the `raild3x/dragdrop` package. Use these terms exactly in issues,
tests, and refactor proposals; the `.luau` source and moonwave docs already use
them. Architecture vocabulary (module, interface, seam, depth, adapter) comes from
the `/codebase-design` skill and is not redefined here.

## Core concepts

- **Payload** — the opaque value a drag carries from a source to a target. Only its
  `Tags` are read by the system (for compatibility); everything else is the
  consumer's. `GetPayload` runs on every lift, so tags can vary per lift.
- **Source** — a registered `GuiObject` a drag can start from (`RegisterSource`).
- **Target** — a registered `GuiObject` a drag can end on (`RegisterTarget`). A
  target `Accepts` a set of tags and may add a finer `CanDrop` gate.
- **Ghost** — the visual proxy that represents the airborne payload during a drag.
  The `GhostLayer` module mounts one per drag and returns a **GhostHandle**
  (`FollowPointer` / `SnapToRect` / `Cleanup`).
- **Controller** — the process-global singleton state machine. Owns the registries,
  the config store, the reactive state (active payload / hovered target), the
  signals, and the drag state machine. It is device-agnostic: `Idle → Pending →
  Dragging → Idle`.

## Input

- **Backend** — a module that translates raw device input into controller
  transitions. Two exist: the **pointer backend** (mouse + touch) and the
  **selection backend** (gamepad + keyboard). Backends never touch controller state
  directly; they cross the transition surface. Each self-filters by device, so both
  run at once and each ignores input that isn't its own.
- **Grab mode** — the selection backend's modal drag: navigation keeps moving
  `GuiService.SelectedObject`, the ghost snaps onto whichever registered target the
  selection lands on, and a lift/drop/cancel key drives the drag. Not literal
  dragging.
- **Canonical space** — the coordinate space the whole package works in:
  `AbsolutePosition`-relative, GUI-inset removed. `InputUtil` owns the conversions.
- **Device** vs **InputClass** — a `Device` is concrete (`Mouse`/`Touch`/`Gamepad`/
  `Keyboard`); an `InputClass` is the switch-cancel grouping (`MouseKeyboard`/
  `Touch`/`Gamepad`). A mouse↔keyboard change stays in one class and must not
  cancel a drag; a change to a different class does.

## Seams (the two injection points)

- **Transition surface** — the typed interface (`Types.TransitionSurface`, exposed
  as `Controller._api`) that the controller injects into its backends and exposes to
  specs. It is the device-agnostic seam: `Press`/`Lift`/`Drop`/`UpdateHover`/… plus
  `GetState` (a read-only snapshot) and resolve/hit-test/config helpers. Backends
  call these transitions; they never mutate state.
- **Input environment** (the **Env seam**) — the single table
  (`Types.Env`, the controller's `DefaultEnv`) through which both the controller and
  its backends reach the outside world: rendering, preferred-input, clock, and the
  device-input surface (`InputBegan`/`InputChanged`/`InputEnded`/`RenderStepped`,
  `PointerLocation`, `SelectionChanged`/`GetSelectedObject`, `BindAction`/
  `UnbindAction`, `Delay`). Production wires the real services; the test harness
  installs fakes so gesture logic runs headlessly. `_setEnv` patches it in place and
  the same table identity is handed to the backends, so there is only one live
  environment.
- **InputLike** — the structural subset of a Roblox `InputObject` the backends read
  (`UserInputType`, `KeyCode`, `Position`). Real input objects satisfy it; test
  fakes are plain tables of the same shape. This is what lets input cross the Env
  seam without dragging the full `InputObject` type through the state machine. See
  [ADR 0001](docs/adr/0001-structural-input-type-at-env-seam.md).

## Drag ownership

- **Controlled** (a.k.a. scriptable) drag — a drag owned by the caller rather than a
  device backend: `Scriptable` input mode, or a positioned `BeginDrag`. Backends
  ignore controlled drags; the returned **DragHandle** drives them, and the
  automatic preferred-input / focus cancels do not apply.
