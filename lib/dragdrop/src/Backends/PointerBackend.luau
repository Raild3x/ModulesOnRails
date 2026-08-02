--[[
	DragDrop — pointer backend (mouse + touch).

	Translates raw pointer input into drag-machine transitions. Mouse uses a drag
	threshold (press + movement lifts; press+release in place is a click). Touch
	uses long-press-to-lift with a movement slop, so a swipe that starts on a slot
	scrolls its ScrollingFrame instead of lifting.

	Constructed by Core with the injected transition `api` and input
	`env` (real device input in production, fakes under test); returns a
	{ Start, Stop } backend. Controlled (script-owned) drags are ignored here — the
	handle drives them.

	gameProcessed is intentionally ignored on InputBegan: presses commonly land on
	a panel's transparent hit-area button and arrive "processed".
]]

const Janitor = require("../../Janitor")
const InputUtil = require("../InputUtil")
const Types = require("../Types")

type TransitionSurface = Types.TransitionSurface
type Env = Types.Env
type InputLike = Types.InputLike
type PendingState = Types.PendingState
type DraggingState = Types.DraggingState

return function(api: TransitionSurface, env: Env)
	local janitor: any = nil
	local longPressGeneration = 0
	-- Last known canonical position of the active touch's InputObject. Touch
	-- drops and follows read this rather than the mouse location.
	local touchDragPos: Vector2? = nil
	-- A pointer press that began while a Sticky carry was live. Only such a
	-- press may place/cancel the carry on release — the release of the click
	-- that *started* the carry (a menu item) has no begin recorded here, so it
	-- can't instantly cancel its own carry.
	local carryPressBegan = false

	const function hitTestSource(absPos: Vector2)
		for _, gui in env.GuiObjectsAt(absPos) do
			const entry = api.ResolveSource(gui)
			if entry then
				return entry
			end
		end
		return nil
	end

	-- Current pointer position for the active drag, in canonical space.
	const function dragPointerPos(st: PendingState | DraggingState): Vector2
		if st.Device == "Touch" then
			-- A touch press captures its InputObject; a touch *carry* has none
			-- (no finger is down between the starting tap and the placing tap),
			-- so it falls back to the last known pointer location.
			const inputObject = st.InputObject
			if touchDragPos then
				return touchDragPos
			end
			return if inputObject then InputUtil.InputPosition(inputObject) else env.PointerLocation()
		end
		return env.PointerLocation()
	end

	const function armLongPress(input: InputLike)
		longPressGeneration += 1
		const myGeneration = longPressGeneration
		const holdSeconds = api.GetConfig("LongPressSeconds")
		env.Delay(holdSeconds, function()
			const st = api.GetState()
			if st.Kind == "Pending" and st.InputObject == input and myGeneration == longPressGeneration then
				api.Lift()
			end
		end)
	end

	const function onInputBegan(input: InputLike)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		const st = api.GetState()
		if st.Kind ~= "Idle" then
			-- A press during a Sticky carry is the placing gesture; remember it
			-- began so its release commits. Anything else mid-gesture (a second
			-- finger) is ignored.
			if st.Kind == "Dragging" and st.Sticky and not st.Controlled then
				carryPressBegan = true
			end
			return
		end

		const absPos = InputUtil.InputPosition(input)
		const entry = hitTestSource(absPos)
		if not entry then
			return
		end

		const device = if input.UserInputType == Enum.UserInputType.Touch then "Touch" else "Mouse"
		if device == "Touch" then
			touchDragPos = absPos
		end
		api.Press(entry, absPos, input, device)
		if device == "Touch" and api.GetState().Kind == "Pending" then
			armLongPress(input)
		end
	end

	const function onInputChanged(input: InputLike)
		const st = api.GetState()

		-- Keep the active touch position current for follow/drop while dragging.
		-- A carry has no captured InputObject, so any touch movement drives it —
		-- the placing finger is by definition the one on the screen.
		if
			st.Kind == "Dragging"
			and st.Device == "Touch"
			and (input == st.InputObject or (st.Sticky and input.UserInputType == Enum.UserInputType.Touch))
		then
			touchDragPos = InputUtil.InputPosition(input)
			return
		end

		if st.Kind ~= "Pending" then
			return
		end
		if st.Device == "Mouse" then
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end
			const absPos = env.PointerLocation()
			if (absPos - st.StartPos).Magnitude > api.GetConfig("DragThresholdPx") then
				api.Lift()
			end
		elseif st.Device == "Touch" then
			if input ~= st.InputObject then
				return
			end
			const absPos = InputUtil.InputPosition(input)
			touchDragPos = absPos
			if (absPos - st.StartPos).Magnitude > api.GetConfig("TouchSlopPx") then
				-- Moved before the hold fired: this is a scroll gesture, not a
				-- lift. Abort silently so the ScrollingFrame handles it.
				api.AbortPending()
			end
		end
	end

	const function inputMatchesGesture(st: PendingState | DraggingState, input: InputLike): boolean
		if st.Device == "Mouse" then
			return input.UserInputType == Enum.UserInputType.MouseButton1
		end
		return input == st.InputObject
	end

	const function onInputEnded(input: InputLike)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		const st = api.GetState()
		if st.Kind == "Pending" then
			if inputMatchesGesture(st, input) then
				api.ReleaseAsClick()
			end
		elseif st.Kind == "Dragging" and not st.Controlled and (st.Device == "Mouse" or st.Device == "Touch") then
			if st.Sticky then
				-- A carry doesn't end with the gesture: only a click that began
				-- during it places (over a target) or cancels (over nothing).
				if not carryPressBegan then
					return
				end
				carryPressBegan = false
				const releasePos = InputUtil.InputPosition(input)
				api.ReportPointer(releasePos, true)
				if api.HitTestTarget(releasePos) then
					api.Drop()
				else
					api.CancelDrag()
				end
				return
			end
			if not inputMatchesGesture(st, input) then
				return
			end
			-- Report the release point (forcing a fresh hover) so the machine
			-- resolves the drop target, then commit the drop.
			api.ReportPointer(dragPointerPos(st), true)
			api.Drop()
			touchDragPos = nil
		end
	end

	-- Drive the ghost by reporting the live pointer each frame; the machine owns
	-- the ghost and the re-hover throttle. The backend only sources the
	-- device-specific pointer position (mouse vs the active touch).
	const function onRender()
		const st = api.GetState()
		if st.Kind ~= "Dragging" or st.Controlled or (st.Device ~= "Mouse" and st.Device ~= "Touch") then
			return
		end
		api.ReportPointer(dragPointerPos(st))
	end

	const backend = {}

	function backend.Start()
		if janitor then
			return
		end
		janitor = Janitor.new()
		janitor:Add(env.InputBegan:Connect(onInputBegan))
		janitor:Add(env.InputChanged:Connect(onInputChanged))
		janitor:Add(env.InputEnded:Connect(onInputEnded))
		janitor:Add(env.RenderStepped:Connect(onRender))
		-- Every drag begins with no placing press recorded — a flag left set by a
		-- carry that ended out from under its press must not leak into the next.
		janitor:Add(api.DragStarted:Connect(function()
			carryPressBegan = false
		end), "Disconnect")
	end

	function backend.Stop()
		-- Invalidate any armed long-press so it can't fire after stop.
		longPressGeneration += 1
		touchDragPos = nil
		carryPressBegan = false
		if janitor then
			janitor:Destroy()
			janitor = nil
		end
	end

	return backend
end
