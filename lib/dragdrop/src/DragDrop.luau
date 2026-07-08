-- Authors: Logan Hunt (Raildex)
--[=[
	@class DragDrop

	Device-agnostic drag-and-drop for Roblox UI. A singleton that moves an opaque
	[Payload] from a registered source to a registered target across **mouse,
	touch, gamepad, and keyboard**, emitting intent through the target's `OnDrop`.
	It is data-agnostic: it never inspects a payload past its `Type`, so the same
	system can carry inventory items today and shop entries tomorrow.

	Register a source and/or a target on a `GuiObject` and keep the returned
	[Unregister] alive for as long as the element should participate. In a
	component framework, insert it into your cleanup scope:

	```lua
	local DragDrop = require(Packages.DragDrop)

	table.insert(scope, DragDrop.RegisterSource(slot, {
		GetPayload = function()
			return { Tags = { "Item" }, Guid = guid, FromIndex = i }
		end,
		BuildGhost = function(payload, source) return MyItemGhost(payload) end,
		OnActivated = openContextMenu, -- click / A-press without a lift
	}))
	table.insert(scope, DragDrop.RegisterTarget(slot, {
		Accepts = { "Item" }, -- only takes item drags
		OnDrop = function(payload, target) MoveItem(payload, target) end,
		Metadata = { Index = i },
	}))
	```

	### Compatibility

	A target with `Accepts` only takes drags whose payload `Tags` share at least
	one entry with it (so an item can't land in a currency slot). Tags travel with
	the payload — `{ Tags = { "Item", "Food" } }` fits item slots and food slots
	alike — so a source whose contents vary matches correctly per lift. A target
	with no `Accepts` (nil or empty) takes any payload. `CanDrop` is an optional
	finer gate checked in addition to `Accepts`.

	### Gestures per device

	- **Mouse** — press + ~8px movement lifts; press+release in place = `OnActivated`.
	- **Touch** — long-press (~0.4s) lifts; a swipe scrolls instead; tap = `OnActivated`.
	- **Gamepad** — a lift button (ButtonX) enters grab mode; selection navigation
	  moves the ghost; a drop button (ButtonA) drops, a cancel button (ButtonB) reverts.
	- **Keyboard** — the same grab mode via the keyboard: a lift key (Return) toggles
	  lift → drop on the selected object; selection navigation moves the ghost.

	### Input switching (revert)

	Switching the active input class mid-drag (e.g. touching the screen during a
	gamepad drag) **cancels and reverts** the drag cleanly — scroll locks restored,
	ghost removed, [DragDrop.DragEnded] fired with a nil target. Mouse↔keyboard
	stays within one class and never cancels.

	### Scriptable mode

	[DragDrop.SetInputMode] with `"Scriptable"` disables all automatic input, and
	[DragDrop.BeginDrag] returns a [DragHandle] you drive by hand — for cutscenes,
	tutorials, and tests.
]=]

const Controller = require("./Controller")
const Types = require("./Types")

export type Payload = Types.Payload
export type TargetDescriptor = Types.TargetDescriptor
export type SourceOptions = Types.SourceOptions
export type TargetOptions = Types.TargetOptions
export type Config = Types.Config
export type InputMode = Types.InputMode
export type DragHandle = Types.DragHandle
export type Unregister = Types.Unregister

const DragDrop = {}

--// Registration //--

--[=[
	@within DragDrop
	@function RegisterSource
	@param instance GuiObject
	@param options SourceOptions
	@return Unregister

	Marks `instance` (and its descendants) as something that can be picked up.
	Returns a function that unregisters it; the source also auto-unregisters if the
	instance is destroyed.
]=]
DragDrop.RegisterSource = Controller.RegisterSource

--[=[
	@within DragDrop
	@function RegisterTarget
	@param instance GuiObject
	@param options TargetOptions
	@return Unregister

	Marks `instance` (and its descendants) as somewhere a payload can be dropped.
	Returns a function that unregisters it; the target also auto-unregisters if the
	instance is destroyed.
]=]
DragDrop.RegisterTarget = Controller.RegisterTarget

--// Programmatic control //--

--[=[
	@within DragDrop
	@function BeginDrag
	@param instance GuiObject -- a registered source (or a descendant of one)
	@param position Vector2? -- optional initial ghost position (canonical space)
	@return DragHandle?

	Lifts a registered source programmatically and returns a [DragHandle], or nil
	if the lift is refused (not registered, `GetPayload` returned nil, or a drag is
	already active).

	- With `position`: a **pointer-controlled** drag whose ghost follows the point
	  you feed via `handle:MoveTo`. The automatic backends leave it alone.
	- Without `position`: a **selection grab-mode** drag. In Automatic mode the
	  gamepad/keyboard backend drives it (selection nav moves the ghost); in
	  Scriptable mode you drive it with `handle:SetHoveredTarget` and `handle:Drop`.
]=]
DragDrop.BeginDrag = Controller.BeginDrag

--[=[
	@within DragDrop
	@function SetInputMode
	@param mode InputMode

	Switches between `"Automatic"` (device backends wired to real input) and
	`"Scriptable"` (backends off; drags driven only through [DragDrop.BeginDrag]).
	Any active drag is cancelled across the switch.
]=]
DragDrop.SetInputMode = Controller.SetInputMode

--[=[
	@within DragDrop
	@function GetInputMode
	@return InputMode
]=]
DragDrop.GetInputMode = Controller.GetInputMode

--[=[
	@within DragDrop
	@function Drop
	@return boolean

	Ends the active drag on the currently hovered target. Returns `true` if it
	landed on a valid target, `false` if there was none (a revert). No-op when idle.
]=]
DragDrop.Drop = Controller.Drop

--[=[
	@within DragDrop
	@function Cancel

	Reverts the active drag, or aborts a pending press. No-op when idle.
]=]
DragDrop.Cancel = Controller.Cancel

--// State //--

--[=[
	@within DragDrop
	@function IsDragging
	@return boolean
]=]
DragDrop.IsDragging = Controller.IsDragging

--[=[
	@within DragDrop
	@function GetActivePayload
	@return Payload?

	The payload currently airborne, or nil when idle.
]=]
DragDrop.GetActivePayload = Controller.GetActivePayload

--[=[
	@within DragDrop
	@function GetHoveredTarget
	@return TargetDescriptor?

	The valid target the drag is currently over, or nil.
]=]
DragDrop.GetHoveredTarget = Controller.GetHoveredTarget

--[=[
	@within DragDrop
	@function ObserveActivePayload
	@param callback (payload: Payload?) -> ()
	@return Unregister

	Calls `callback` immediately with the current value and again whenever the
	active payload changes. Return value tears the observer down.
]=]
DragDrop.ObserveActivePayload = Controller.ObserveActivePayload

--[=[
	@within DragDrop
	@function ObserveHoveredTarget
	@param callback (target: TargetDescriptor?) -> ()
	@return Unregister

	Calls `callback` immediately with the current value and again whenever the
	hovered target changes.
]=]
DragDrop.ObserveHoveredTarget = Controller.ObserveHoveredTarget

--[=[
	@within DragDrop
	@function ConsumeActivation
	@return boolean

	True if a drag ended within the last few hundredths of a second — use it to
	swallow a stray `Button.Activated` that fires right after a drop, so a drag
	doesn't also read as a click.
]=]
DragDrop.ConsumeActivation = Controller.ConsumeActivation

--[=[
	@within DragDrop
	@function Configure
	@param config Config

	Applies a partial [Config] over the current settings. Errors on unknown keys
	or wrong value types. Behavior knobs only — ghost appearance lives in
	`SourceOptions.BuildGhost`.
]=]
DragDrop.Configure = Controller.Configure

--[=[
	@within DragDrop
	@function ResetConfig

	Restores every [Config] key to its default. This is also the only way to
	*clear* an optional key such as `GhostContainer` — [Configure](/api/DragDrop#Configure)
	cannot accept nil for them, since nil values vanish from Luau tables.
]=]
DragDrop.ResetConfig = Controller.ResetConfig

--// Signals //--

--[=[
	@within DragDrop
	@prop DragStarted Signal<(payload: Payload, source: GuiObject)>
	Fires when a payload goes airborne.
]=]
DragDrop.DragStarted =
	Controller.DragStarted :: Types.Signal<(payload: Payload, source: GuiObject) -> (), Payload, GuiObject>

--[=[
	@within DragDrop
	@prop Dropped Signal<(payload: Payload, target: TargetDescriptor)>
	Fires when a payload lands on a valid target, immediately after that target's
	`OnDrop` has run.
]=]
DragDrop.Dropped =
	Controller.Dropped :: Types.Signal<(payload: Payload, target: TargetDescriptor) -> (), Payload, TargetDescriptor>

--[=[
	@within DragDrop
	@prop DragEnded Signal<(payload: Payload, target: TargetDescriptor?)>
	Fires on every drag end. A nil target means the drag was cancelled or reverted.

	This is the **last** event of a drag. End-of-drag order:
	1. Reactive state clears — `GetActivePayload`/`GetHoveredTarget` go nil and
	   their observers fire (ghost/scroll-lock teardown has already run).
	2. The target's `OnDrop` runs, then [DragDrop.Dropped] fires.
	3. The source's `OnDragEnd` runs, then `DragEnded` fires.

	Because the observers fire *before* `OnDrop` mutates your data, a view that
	repaints only from observers will still show pre-drop data — repaint on
	`DragEnded` (or from your own data layer) to pick up the result of the drop.
]=]
DragDrop.DragEnded =
	Controller.DragEnded :: Types.Signal<(payload: Payload, target: TargetDescriptor?) -> (), Payload, TargetDescriptor?>

return DragDrop
