--[=[
	@class DD Input Devices

	[DragDrop](/api/DragDrop) is device-agnostic: the same source/target
	registration works whether the player uses a mouse, a touchscreen, a gamepad,
	or the keyboard. Two backends translate raw input into the same state machine —
	a **pointer** backend (mouse + touch) and a **selection** backend (gamepad +
	keyboard). You never interact with them directly.

	### Gesture per device

	| Device | Lift | Move | Drop | Cancel |
	| --- | --- | --- | --- | --- |
	| **Mouse** | press + move past `DragThresholdPx` | ghost follows cursor | release over a target | release off any target |
	| **Touch** | long-press (`LongPressSeconds`) | ghost follows finger | lift finger over a target | lift finger off any target |
	| **Gamepad** | `GamepadLiftKeyCode` on the selected source | navigate selection; ghost springs onto slots | `GamepadDropKeyCode` | `GamepadCancelKeyCode` |
	| **Keyboard** | `KeyboardLiftKeyCode` on the selected source | navigate selection; ghost springs onto slots | `KeyboardLiftKeyCode` again | `KeyboardCancelKeyCode` (opt) / menu |

	**Mouse vs. click.** A press that releases without crossing the threshold is a
	*click* and fires the source's `OnActivated` instead of lifting. **Touch vs.
	scroll.** If a touch moves past `TouchSlopPx` before the long-press fires, it is
	treated as a scroll gesture and the lift is abandoned, so a swipe that starts on
	a slot still scrolls the list.

	**Grab mode** (gamepad + keyboard) is modal rather than literal dragging: normal
	UI navigation keeps moving `GuiService.SelectedObject`, and the ghost springs
	onto whichever registered target the selection lands on. Drop/cancel keys are
	bound (and sunk) via `ContextActionService` only for the duration of a drag, so
	they never shadow those buttons elsewhere.

	### Switching input mid-drag reverts

	If the player changes input **class** while a drag is live — touching the screen
	during a gamepad drag, picking up a controller during a mouse drag — the drag is
	**cancelled and reverted**: scroll locks are restored, the ghost is removed, and
	[DragEnded](/api/DragDrop#DragEnded) fires with a `nil` target. The drag is not
	handed over to the new device.

	Mouse and keyboard are the **same** class, so tapping a key during a mouse drag
	(or clicking during keyboard grab mode) does **not** cancel. The three classes
	are `MouseKeyboard`, `Touch`, and `Gamepad`.

	Losing window focus or opening the Roblox menu mid-drag also reverts — those are
	moments where the release event might never arrive, and a stranded ghost would
	otherwise linger.

	### The Escape key

	Roblox reserves Escape (it opens the menu), so DragDrop can't sink it as a
	dedicated cancel. In practice opening the menu already reverts the drag, so
	Escape effectively cancels. If you want a clean keyboard cancel that does **not**
	open the menu, set `KeyboardCancelKeyCode` to a key of your choosing.

	### Clicks right after a drop

	Some button setups fire `Activated` immediately after a drop lands on them,
	which can read as an accidental click. Guard against it:

	```lua
	button.Activated:Connect(function()
		if DragDrop.ConsumeActivation() then
			return -- a drag just ended here; swallow this stray click
		end
		handleClick()
	end)
	```

	### Configuration

	Every threshold and keybind is adjustable via [Configure](/api/DragDrop#Configure).
	These are behavior knobs only — nothing here styles the ghost.

	```lua
	DragDrop.Configure({
		DragThresholdPx = 12,
		LongPressSeconds = 0.3,
		GamepadLiftKeyCode = Enum.KeyCode.ButtonY,
		KeyboardCancelKeyCode = Enum.KeyCode.Backspace,
	})
	```

	---
	### See also

	- **[DD Getting Started](/api/DD%20Getting%20Started)** — registering sources and targets.
	- **[DD Ghosts & Scripting](/api/DD%20Ghosts%20&%20Scripting)** — the drag proxy and Scriptable mode.
]=]
