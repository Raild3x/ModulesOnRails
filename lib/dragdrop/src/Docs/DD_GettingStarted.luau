--[=[
	@class DD Getting Started

	[DragDrop](/api/DragDrop) moves an opaque **payload** from a registered
	*source* to a registered *target* across every input device — mouse, touch,
	gamepad, and keyboard — and hands you the result through the target's `OnDrop`.
	It never inspects your payload past its `Tags`, so one system carries whatever
	your UI needs.

	### 1. Require the module

	```lua
	local DragDrop = require(Packages.DragDrop)
	```

	### 2. Register a source

	A **source** is something the player can pick up. `GetPayload` is called on
	press and returns the payload to lift — or `nil` to refuse (an empty slot, a
	disabled button, mid-animation, ...).

	```lua
	local unregister = DragDrop.RegisterSource(slotButton, {
		GetPayload = function()
			local item = getItemInSlot(i)
			if not item then
				return nil -- nothing here to lift
			end
			return { Tags = { "Item" }, Guid = item.Guid, FromIndex = i }
		end,
		BuildGhost = function(payload, source) -- the proxy that follows the drag
			return makeItemGhost(payload)
		end,
		OnActivated = function()  -- a press+release without a drag reads as a click
			openContextMenu(i)
		end,
	})
	```

	Keep the returned [Unregister](/api/DragDrop#Unregister) alive for as long as
	the element should participate. In a component/scope system, add it to your
	cleanup. The source also auto-unregisters if its instance is destroyed.

	### 3. Register a target

	A **target** is somewhere a payload can land. `OnDrop` receives the payload and
	a [TargetDescriptor](/api/DragDrop#TargetDescriptor) (the target instance plus
	the `Metadata` you registered).

	```lua
	DragDrop.RegisterTarget(slotButton, {
		Accepts = { "Item" }, -- only takes drags whose payload is tagged "Item"
		CanDrop = function(payload)
			return not isSlotLocked(i) -- optional finer gate
		end,
		OnDrop = function(payload, target)
			moveItem(payload.FromIndex, target.Metadata.Index)
		end,
		Metadata = { Index = i },
	})
	```

	### 4. Compatibility

	A target with `Accepts` only takes a drag whose payload `Tags` share at least
	one entry with it. `{ Tags = { "Potion" } }` fits potion slots, while
	`{ Tags = { "Item", "Food" } }` fits item slots and food slots alike. Because
	`Tags` travels with the payload and `GetPayload` runs on every lift, a slot
	whose contents vary matches correctly per lift. `CanDrop` runs *in addition*
	to `Accepts` for per-instance rules (a full slot, a cooldown, a mismatched
	element). A target with no `Accepts` (nil or empty) takes any payload.

	### 5. React to drag state (optional)

	Drag state is exposed as plain getters and signals.

	```lua
	-- Poll:
	if DragDrop.IsDragging() then ... end
	local payload = DragDrop.GetActivePayload()

	-- Subscribe to state changes. These fire on change but not on connect, so seed
	-- the initial paint with the matching getter:
	highlight(DragDrop.GetHoveredTarget())
	DragDrop.HoveredTargetChanged:Connect(function(target)
		highlight(target) -- target is a TargetDescriptor or nil
	end)

	-- Lifecycle signals:
	DragDrop.DragStarted:Connect(function(payload, sourceInstance) end)
	DragDrop.Dropped:Connect(function(payload, target) end)
	DragDrop.DragEnded:Connect(function(payload, target) end) -- nil target = cancelled/reverted
	```

	:::info Repainting after a drop
	When a drag ends, the `ActivePayloadChanged`/`HoveredTargetChanged` signals fire
	(with nil) *before* the target's `OnDrop` runs. If a view repaints only from
	those, it will still show pre-drop data. `DragEnded` fires **last** — after
	`OnDrop` and `OnDragEnd` — so repaint there (or from your own data layer) to
	reflect the drop.
	:::

	---
	### See also

	- **[DD Input Devices](/api/DD%20Input%20Devices)** — the gesture per device, and what happens when the player switches input mid-drag.
	- **[DD Ghosts & Scripting](/api/DD%20Ghosts%20&%20Scripting)** — customizing the drag proxy and driving drags by hand.
]=]
