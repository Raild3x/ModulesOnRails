--[=[
	@class DD Ghosts & Scripting

	This guide covers the two ways you extend [DragDrop](/api/DragDrop) beyond the
	defaults: customizing the **ghost** (the proxy that represents the payload while
	it is airborne) and driving drags **programmatically** through Scriptable mode.

	## Custom ghosts

	Practically every source should supply a `BuildGhost`. Without one the drag
	falls back to a bare debug plate that just lists the payload's tags — enough to
	see *that* something is being dragged while prototyping, but not something to
	ship. Supply `BuildGhost` on the source to render your own:

	```lua
	DragDrop.RegisterSource(slot, {
		GetPayload = function() return { Tags = { "Item" }, Guid = guid } end,
		BuildGhost = function(payload, source)
			local icon = Instance.new("ImageLabel")
			icon.Size = UDim2.fromScale(1, 1) -- fill the proxy (matches the source's footprint)
			icon.BackgroundTransparency = 1
			icon.Image = iconFor(payload.Guid)
			icon.ImageTransparency = 0.1
			icon.Rotation = 4 -- appearance is entirely yours
			return icon
		end,
	})
	```

	The contract:

	- The returned `GuiObject` is parented into a proxy frame sized to the source's
	  on-screen footprint. Return something with `Size = UDim2.fromScale(1, 1)` to
	  match the source; give it an explicit offset `Size` to define its own.
	- **Appearance is your job.** DragDrop never scales, tilts, or recolors the
	  proxy — do that inside `BuildGhost`. The system owns *placement* only (it
	  keeps the grab point under the cursor and springs between slots in grab mode).
	- The instance is destroyed when the drag ends. Don't reuse it across drags.

	By default the proxy lives in an internal high-`DisplayOrder` `ScreenGui`. To
	host it yourself (custom layering, a specific `ScreenGui`), set
	`Config.GhostContainer` to any `LayerCollector`:

	```lua
	DragDrop.Configure({ GhostContainer = myOverlayScreenGui })
	```

	To go back to the internal container (or restore any other default), call
	`DragDrop.ResetConfig()` — `Configure` can't clear an optional key, since nil
	values vanish from Luau tables.

	## Scriptable mode

	`SetInputMode("Scriptable")` disables all automatic input backends. Drags then
	start and move **only** through [BeginDrag](/api/DragDrop#BeginDrag) and the
	[DragHandle](/api/DragDrop#DragHandle) it returns — the same way you put a Camera
	into `Scriptable` and drive it by hand. Use it for cutscenes, guided tutorials,
	replays, and automated tests.

	```lua
	DragDrop.SetInputMode("Scriptable")

	local drag = DragDrop.BeginDrag(sourceSlot)      -- returns a DragHandle (or nil if refused)
	if drag then
		drag:SetHoveredTarget(destinationSlot)        -- explicit hover (no hit-test needed)
		local landed = drag:Drop()                    -- true if it dropped on a valid target
	end
	```

	Or drive it by screen position, letting the system hit-test for the target under
	the point:

	```lua
	local drag = DragDrop.BeginDrag(sourceSlot, startPosition) -- position => pointer-controlled
	drag:MoveTo(cursorPosition)  -- follows the point and resolves hover via hit-test
	drag:Drop()
	```

	The handle's methods become no-ops (mutating ones return `false`) once the drag
	has ended, so it is always safe to hold onto.

	`BeginDrag` also works in **Automatic** mode without a position — that is how a
	menu "Move" button initiates a grab-mode drag the gamepad/keyboard backend then
	drives. With a position it always produces a pointer-controlled drag that the
	automatic backends leave alone.

	### DragHandle reference

	| Method | Effect |
	| --- | --- |
	| `MoveTo(position)` | Move the ghost to a screen point and hit-test for hover. |
	| `SetHoveredTarget(target)` | Set hover explicitly; returns `false` if the target is invalid/incompatible. |
	| `Drop()` | End on the current hover; `false` if there was no valid target (a revert). |
	| `Cancel()` | Revert this drag. |
	| `IsActive()` | Whether this handle still controls the live drag. |
	| `GetPayload()` | The payload this drag carries. |

	---
	### See also

	- **[DD Getting Started](/api/DD%20Getting%20Started)** — registering sources and targets.
	- **[DD Input Devices](/api/DD%20Input%20Devices)** — per-device gestures and the switch-to-revert rule.
]=]
