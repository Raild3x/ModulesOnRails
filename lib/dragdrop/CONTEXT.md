# DragDrop — domain glossary

Terminology for the `raild3x/dragdrop` package, as used by the `.luau` source and
the moonwave docs.

## Core concepts

- **Payload** — the opaque value a drag carries from a source to a target. Only its
  `Tags` are read by the system (for compatibility); everything else is the
  consumer's. `GetPayload` runs on every lift, so tags can vary per lift.
- **Source** — a registered `GuiObject` a drag can start from (`RegisterSource`).
- **Target** — a registered `GuiObject` a drag can end on (`RegisterTarget`). A
  target `Accepts` a set of tags and may add a finer `CanDrop` gate.
- **Ghost** — the visual proxy that represents the airborne payload during a drag.
  The `GhostLayer` module mounts one per drag and returns a **GhostHandle**
  (`FollowPointer` / `SnapToRect` / `Cleanup`). The **DragMachine is the sole owner
  of the GhostHandle**: only it calls those methods. Backends never touch the
  ghost — the pointer backend *reports* the live pointer (see `ReportPointer` under
  the transition surface) and the machine drives Follow placement from it. See
  [ADR 0002](docs/adr/0002-single-ghost-owner.md).
- **DragMachine** — the device-agnostic drag state machine (`DragMachine.luau`):
  `Idle → Pending → Dragging → Idle`, typed as the `DragState` tagged union. Owns
  every transition, the per-drag Janitor, hit-testing, the DragHandle factory, and
  the transition surface it hands to the backends.
- **Core** — the process-global internal singleton (`Core.luau`) the `DragDrop`
  facade sits on. Assembles the slices — `Config` (config store), `Reactive`
  (observables + signals), `Env` (the Env seam), `Registry` (source/target
  registries), `Matching` (compatibility gates), and the DragMachine — wires their
  injected edges, and owns the input mode + backend lifecycle. See
  [ADR 0003](docs/adr/0003-typed-dragstate-and-core-split.md).

## Input

- **Backend** — a module that translates raw device input into DragMachine
  transitions. Two exist: the **pointer backend** (mouse + touch) and the
  **selection backend** (gamepad + keyboard). Backends never touch machine state
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

- **Transition surface** — the typed interface (`Types.TransitionSurface`,
  implemented by the DragMachine as `DragMachine.Api` and exposed to specs as
  `Core._api`) that Core injects into the backends. It is the device-agnostic seam:
  `Press`/`Lift`/`Drop`/`UpdateHover`/`ReportPointer`/… plus `GetState` (a read-only
  `DragState` snapshot backends narrow on `Kind`) and resolve/hit-test/config
  helpers. Backends call these transitions; they never mutate state or touch
  the ghost. `ReportPointer(pos, forceHover?)` is how the pointer backend tells the
  machine where the pointer is each frame (and at release, with `forceHover` to
  resolve the drop target); the machine — the sole ghost owner — does the Follow
  placement and re-hover, and owns the movement throttle.
- **Input environment** (the **Env seam**) — the single table
  (`Types.Env`, built in `Env.luau`) through which both the drag machine and
  its backends reach the outside world: rendering, preferred-input, clock, and the
  device-input surface (`InputBegan`/`InputChanged`/`InputEnded`/`RenderStepped`,
  `PointerLocation`, `SelectionChanged`/`GetSelectedObject`, `BindAction`/
  `UnbindAction`, `Delay`). Production wires the real services; the test harness
  installs fakes so gesture logic runs headlessly. `Core._setEnv` patches it in
  place and the same table identity is handed to the backends, so there is only one
  live environment.
- **InputLike** — the structural subset of a Roblox `InputObject` the backends read
  (`UserInputType`, `KeyCode`, `Position`). Real input objects satisfy it; test
  fakes are plain tables of the same shape, so input crosses the Env seam without
  the full `InputObject` type reaching the state machine. See
  [ADR 0001](docs/adr/0001-structural-input-type-at-env-seam.md).

## Drag ownership

- **Controlled** (a.k.a. scriptable) drag — a drag owned by the caller rather than a
  device backend: `Scriptable` input mode, or a positioned `BeginDrag`. Backends
  ignore controlled drags; the returned **DragHandle** drives them, and the
  automatic preferred-input / focus cancels do not apply.
