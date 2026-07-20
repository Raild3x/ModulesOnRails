-- Authors: Logan Hunt (Raildex)
--[=[
	@class DragDrop

	Device-agnostic drag-and-drop for Roblox UI. A singleton that moves an opaque
	[Payload] from a registered source to a registered target across **mouse,
	touch, gamepad, and keyboard**, emitting intent through the target's `OnDrop`.
	It never inspects a payload past its `Tags`, so one registration handles any
	kind of content.

	Register a source and/or a target on a `GuiObject` and keep the returned
	[Unregister] alive for as long as the element should participate. In a
	component framework, insert it into your cleanup scope:

	```lua
	local DragDrop = require(Packages.DragDrop)

	local disconnectSource = DragDrop.RegisterSource(slot, {
		GetPayload = function()
			return { Tags = { "Item" }, Guid = guid, FromIndex = i }
		end,
		BuildGhost = function(payload, source) return MyItemGhost(payload) end,
		OnActivated = openContextMenu, -- click / A-press without a lift
	})

	local disconnectTarget = DragDrop.RegisterTarget(slot, {
		Accepts = { "Item" }, -- only takes item drags
		OnDrop = function(payload, target) MoveItem(payload, target) end,
		Metadata = { Index = i },
	})
	```

	### Where to read more

	- **[DD Getting Started](/api/DD%20Getting%20Started)** — registering sources and
	  targets, how `Tags`/`Accepts`/`CanDrop` decide compatibility, and reacting to
	  drag state.
	- **[DD Input Devices](/api/DD%20Input%20Devices)** — the gesture per device, the
	  configurable thresholds and keybinds, and what switching input class mid-drag
	  does.
	- **[DD Ghosts & Scripting](/api/DD%20Ghosts%20&%20Scripting)** — customizing the
	  drag proxy with `BuildGhost`, and driving drags by hand through
	  [DragDrop.SetInputMode] and [DragHandle].
]=]

const Core = require("./Core")
const Types = require("./Types")

export type Payload = Types.Payload
export type TargetDescriptor = Types.TargetDescriptor
export type SourceOptions = Types.SourceOptions
export type TargetOptions = Types.TargetOptions
export type Config = Types.Config
export type InputMode = Types.InputMode
export type DragHandle = Types.DragHandle

const DragDrop = {}

--// Registration //--

--[=[
	@within DragDrop
	@function RegisterSource
	@param instance GuiObject
	@param options SourceOptions
	@return () -> ()

	Marks `instance` (and its descendants) as something that can be picked up.
	Returns a function that unregisters it; the source also auto-unregisters if the
	instance is destroyed.

	```lua
	local unregister = DragDrop.RegisterSource(slot, {
		GetPayload = function()
			if slot.IsEmpty then return nil end -- refuse the lift
			return { Tags = { "Item" }, Guid = slot.Guid, FromIndex = i }
		end,
		BuildGhost = function(payload) return MyItemGhost(payload) end,
		OnActivated = function() openContextMenu(i) end, -- click without a lift
	})

	-- later, when the slot goes away:
	unregister()
	```
]=]
DragDrop.RegisterSource = Core.RegisterSource

--[=[
	@within DragDrop
	@function RegisterTarget
	@param instance GuiObject
	@param options TargetOptions
	@return () -> ()

	Marks `instance` (and its descendants) as somewhere a payload can be dropped.
	Returns a function that unregisters it; the target also auto-unregisters if the
	instance is destroyed.

	```lua
	local unregister = DragDrop.RegisterTarget(slot, {
		Accepts = { "Item" }, -- only item drags; omit to accept any payload
		CanDrop = function(payload) return not slot.Locked end, -- finer gate
		OnDrop = function(payload, target)
			MoveItem(payload.Guid, target.Metadata.Index)
		end,
		OnHoverChanged = function(payload)
			slot.Highlight.Visible = payload ~= nil -- nil on leave
		end,
		Metadata = { Index = i },
	})
	```
]=]
DragDrop.RegisterTarget = Core.RegisterTarget

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

	```lua
	-- Pointer-controlled: feed the ghost a position yourself.
	local handle = DragDrop.BeginDrag(slot, UserInputService:GetMouseLocation())
	if handle then
		handle:MoveTo(UserInputService:GetMouseLocation()) -- each frame
		handle:Drop() -- lands on whatever it's hovering
	end

	-- Selection grab-mode (no position): drive it explicitly under Scriptable mode.
	local handle = DragDrop.BeginDrag(sourceSlot)
	if handle then
		handle:SetHoveredTarget(destSlot)
		handle:Drop()
	end
	```
]=]
DragDrop.BeginDrag = Core.BeginDrag

--[=[
	@within DragDrop
	@function SetInputMode
	@param mode InputMode

	Switches between `"Automatic"` (device backends wired to real input) and
	`"Scriptable"` (backends off; drags driven only through [DragDrop.BeginDrag]).
	Any active drag is cancelled across the switch.

	```lua
	-- In a test: take control away from real input, then drive a drag by hand.
	DragDrop.SetInputMode("Scriptable")
	local handle = DragDrop.BeginDrag(sourceSlot)
	handle:SetHoveredTarget(destSlot)
	handle:Drop()
	DragDrop.SetInputMode("Automatic") -- hand input back
	```
]=]
DragDrop.SetInputMode = Core.SetInputMode

--[=[
	@within DragDrop
	@function GetInputMode
	@return InputMode

	```lua
	if DragDrop.GetInputMode() == "Automatic" then
		-- real device input is live
	end
	```
]=]
DragDrop.GetInputMode = Core.GetInputMode

--[=[
	@within DragDrop
	@function Drop
	@return boolean

	Ends the active drag on the currently hovered target. Returns `true` if it
	landed on a valid target, `false` if there was none (a revert). No-op when idle.

	```lua
	-- Bind a "confirm" key to commit whatever drag is in flight.
	local landed = DragDrop.Drop()
	if not landed then
		-- reverted: nothing valid under the ghost
	end
	```
]=]
DragDrop.Drop = Core.Drop

--[=[
	@within DragDrop
	@function Cancel

	Reverts the active drag, or aborts a pending press. No-op when idle.

	```lua
	-- Escape backs out of whatever is in flight.
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape then
			DragDrop.Cancel()
		end
	end)
	```
]=]
DragDrop.Cancel = Core.Cancel

--// State //--

--[=[
	@within DragDrop
	@function IsDragging
	@return boolean

	```lua
	-- Suppress a hover tooltip while something is airborne.
	if not DragDrop.IsDragging() then
		showTooltip(slot)
	end
	```
]=]
DragDrop.IsDragging = Core.IsDragging

--[=[
	@within DragDrop
	@function GetActivePayload
	@return Payload?

	The payload currently airborne, or nil when idle.

	```lua
	local payload = DragDrop.GetActivePayload()
	if payload and table.find(payload.Tags, "Item") then
		-- an item is in flight right now
	end
	```
]=]
DragDrop.GetActivePayload = Core.GetActivePayload

--[=[
	@within DragDrop
	@function GetHoveredTarget
	@return TargetDescriptor?

	The valid target the drag is currently over, or nil.

	```lua
	local target = DragDrop.GetHoveredTarget()
	if target then
		print("would drop into slot", target.Metadata.Index)
	end
	```
]=]
DragDrop.GetHoveredTarget = Core.GetHoveredTarget

--[=[
	@within DragDrop
	@prop ActivePayloadChanged Signal<(payload: Payload?)>
	Fires whenever the airborne payload changes — the new payload on lift, nil on
	drop or cancel.

	It does **not** fire on connect, so read the current value with
	[DragDrop.GetActivePayload] when you subscribe. It is a plain [Signal], so it
	works with anything that consumes signals — `:Once`, `:Wait`, a Janitor, a
	reactive binding.

	```lua
	-- Dim every incompatible slot while a drag is live. Seed from the getter, then
	-- keep it in sync from the signal.
	local function repaint(payload: DragDrop.Payload?)
		for _, slot in slots do
			slot.Dimmed = payload ~= nil and not accepts(slot, payload)
		end
	end
	repaint(DragDrop.GetActivePayload())
	local conn = DragDrop.ActivePayloadChanged:Connect(repaint)

	-- later:
	conn:Disconnect()
	```
]=]
DragDrop.ActivePayloadChanged = Core.ActivePayloadChanged

--[=[
	@within DragDrop
	@prop HoveredTargetChanged Signal<(target: TargetDescriptor?)>
	Fires whenever the hovered target changes — the new [TargetDescriptor] on enter,
	nil on leave.

	It does **not** fire on connect, so read the current value with
	[DragDrop.GetHoveredTarget] when you subscribe.

	```lua
	-- Move a "drop here" highlight to whatever the ghost is over.
	local conn = DragDrop.HoveredTargetChanged:Connect(function(target)
		highlight.Visible = target ~= nil
		if target then highlight.Parent = target.Instance end
	end)
	```
]=]
DragDrop.HoveredTargetChanged = Core.HoveredTargetChanged

--[=[
	@within DragDrop
	@function ConsumeActivation
	@return boolean

	True if a drag ended within the last few hundredths of a second — use it to
	swallow a stray `Button.Activated` that fires right after a drop, so a drag
	doesn't also read as a click.

	```lua
	button.Activated:Connect(function()
		if DragDrop.ConsumeActivation() then
			return -- this "click" was really the tail of a drag; ignore it
		end
		openSlot()
	end)
	```
]=]
DragDrop.ConsumeActivation = Core.ConsumeActivation

--[=[
	@within DragDrop
	@function Configure
	@param config Config

	Applies a partial [Config] over the current settings. Errors on unknown keys
	or wrong value types. Behavior knobs only — ghost appearance lives in
	`SourceOptions.BuildGhost`.

	```lua
	DragDrop.Configure({
		DragThresholdPx = 12, -- a little more slop before a mouse lift
		LongPressSeconds = 0.3, -- quicker touch lift
		GhostContainer = playerGui.DragLayer, -- mount ghosts here
	})
	```
]=]
DragDrop.Configure = Core.Configure

--[=[
	@within DragDrop
	@function ResetConfig

	Restores every [Config] key to its default. This is also the only way to
	*clear* an optional key such as `GhostContainer` — [Configure](/api/DragDrop#Configure)
	cannot accept nil for them, since nil values vanish from Luau tables.

	```lua
	DragDrop.Configure({ GhostContainer = myLayer })
	-- ...
	DragDrop.ResetConfig() -- back to defaults, GhostContainer cleared to nil
	```
]=]
DragDrop.ResetConfig = Core.ResetConfig

--// Signals //--

--[=[
	@within DragDrop
	@prop DragStarted Signal<(payload: Payload, source: GuiObject)>
	Fires when a payload goes airborne.

	```lua
	DragDrop.DragStarted:Connect(function(payload, source)
		playPickupSound()
		source.BackgroundTransparency = 0.6 -- fade the origin slot while lifted
	end)
	```
]=]
DragDrop.DragStarted = Core.DragStarted

--[=[
	@within DragDrop
	@prop Dropped Signal<(payload: Payload, target: TargetDescriptor)>
	Fires when a payload lands on a valid target, immediately after that target's
	`OnDrop` has run.

	```lua
	-- A global listener for analytics, independent of any one target's OnDrop.
	DragDrop.Dropped:Connect(function(payload, target)
		Analytics:Log("item_moved", {
			guid = payload.Guid,
			to = target.Metadata.Index,
		})
	end)
	```
]=]
DragDrop.Dropped = Core.Dropped

--[=[
	@within DragDrop
	@prop DragEnded Signal<(payload: Payload, target: TargetDescriptor?)>
	Fires on every drag end. A nil target means the drag was cancelled or reverted.

	This is the **last** event of a drag. End-of-drag order:
	1. Reactive state clears — `GetActivePayload`/`GetHoveredTarget` go nil and
	   [DragDrop.ActivePayloadChanged]/[DragDrop.HoveredTargetChanged] fire
	   (ghost/scroll-lock teardown has already run).
	2. The target's `OnDrop` runs, then [DragDrop.Dropped] fires.
	3. The source's `OnDragEnd` runs, then `DragEnded` fires.

	Because those change signals fire *before* `OnDrop` mutates your data, a view
	that repaints only from them will still show pre-drop data — repaint on
	`DragEnded` (or from your own data layer) to pick up the result of the drop.

	```lua
	DragDrop.DragEnded:Connect(function(payload, target)
		if target == nil then
			playRevertSound() -- cancelled or reverted
		end
		repaintInventory() -- OnDrop has already applied the move by now
	end)
	```
]=]
DragDrop.DragEnded = Core.DragEnded

return DragDrop
