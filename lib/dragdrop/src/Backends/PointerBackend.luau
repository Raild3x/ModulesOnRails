--[[
	DragDrop — pointer backend (mouse + touch).

	Translates raw pointer input into controller transitions. Mouse uses a drag
	threshold (press + movement lifts; press+release in place is a click). Touch
	uses long-press-to-lift with a movement slop, so a swipe that starts on a slot
	scrolls its ScrollingFrame instead of lifting.

	Constructed by the controller with the injected transition `api`; returns a
	{ Start, Stop } backend. Controlled (script-owned) drags are ignored here — the
	handle drives them.

	gameProcessed is intentionally ignored on InputBegan: presses commonly land on
	a panel's transparent hit-area button and arrive "processed".
]]

const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")

const Janitor = require("../../Janitor")
const InputUtil = require("../InputUtil")

return function(api)
	local janitor: any = nil
	local longPressGeneration = 0
	-- Last known canonical position of the active touch's InputObject (#2): touch
	-- drops/follows must not read the MOUSE location.
	local touchDragPos: Vector2? = nil
	local lastRenderPos: Vector2? = nil

	const function hitTestSource(absPos: Vector2)
		for _, gui in InputUtil.GuiObjectsAt(absPos) do
			const entry = api.ResolveSource(gui)
			if entry then
				return entry
			end
		end
		return nil
	end

	const function hitTestTarget(absPos: Vector2)
		for _, gui in InputUtil.GuiObjectsAt(absPos) do
			const entry = api.ResolveTarget(gui)
			if entry then
				return entry
			end
		end
		return nil
	end

	-- Current pointer position for the active drag, in canonical space.
	const function dragPointerPos(st: any): Vector2
		if st.Device == "Touch" then
			return touchDragPos or InputUtil.InputPosition(st.InputObject)
		end
		return InputUtil.PointerLocation()
	end

	const function armLongPress(input: InputObject)
		longPressGeneration += 1
		const myGeneration = longPressGeneration
		const holdSeconds = api.GetConfig("LongPressSeconds")
		task.delay(holdSeconds, function()
			const st = api.GetState()
			if st.Kind == "Pending" and st.InputObject == input and myGeneration == longPressGeneration then
				api.Lift()
			end
		end)
	end

	const function onInputBegan(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if api.GetState().Kind ~= "Idle" then
			return -- already pressing/dragging (e.g. a second finger)
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

	const function onInputChanged(input: InputObject)
		const st = api.GetState()

		-- Keep the active touch position current for follow/drop while dragging.
		if st.Kind == "Dragging" and st.Device == "Touch" and input == st.InputObject then
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
			const absPos = InputUtil.PointerLocation()
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

	const function inputMatchesGesture(st: any, input: InputObject): boolean
		if st.Device == "Mouse" then
			return input.UserInputType == Enum.UserInputType.MouseButton1
		end
		return input == st.InputObject
	end

	const function onInputEnded(input: InputObject)
		const st = api.GetState()
		if st.Kind == "Pending" then
			if inputMatchesGesture(st, input) then
				api.ReleaseAsClick()
			end
		elseif st.Kind == "Dragging" and not st.Controlled and (st.Device == "Mouse" or st.Device == "Touch") then
			if not inputMatchesGesture(st, input) then
				return
			end
			const absPos = dragPointerPos(st)
			api.UpdateHover(hitTestTarget(absPos))
			api.Drop()
			touchDragPos = nil
		end
	end

	const function onRender()
		const st = api.GetState()
		if st.Kind ~= "Dragging" or st.Controlled or (st.Device ~= "Mouse" and st.Device ~= "Touch") then
			lastRenderPos = nil
			return
		end
		const absPos = dragPointerPos(st)
		st.Ghost.FollowPointer(absPos)
		-- Only re-hit-test when the pointer actually moved (#7).
		if lastRenderPos == nil or (absPos - lastRenderPos).Magnitude > 0 then
			lastRenderPos = absPos
			api.UpdateHover(hitTestTarget(absPos))
		end
	end

	const backend = {}

	function backend.Start()
		if janitor then
			return
		end
		janitor = Janitor.new()
		janitor:Add(UserInputService.InputBegan:Connect(onInputBegan))
		janitor:Add(UserInputService.InputChanged:Connect(onInputChanged))
		janitor:Add(UserInputService.InputEnded:Connect(onInputEnded))
		janitor:Add(RunService.RenderStepped:Connect(onRender))
	end

	function backend.Stop()
		-- Invalidate any armed long-press so it can't fire after stop (#6).
		longPressGeneration += 1
		touchDragPos = nil
		lastRenderPos = nil
		if janitor then
			janitor:Destroy()
			janitor = nil
		end
	end

	return backend
end
