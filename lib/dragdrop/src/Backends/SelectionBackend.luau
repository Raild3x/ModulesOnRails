--[[
	DragDrop — selection backend (gamepad + keyboard "grab mode").

	Selection drags are modal, not literal dragging: normal UI navigation keeps
	moving GuiService.SelectedObject, and the ghost springs onto whichever
	registered target the selection lands on. A configurable lift key on a selected
	source enters grab mode; while carrying, a drop key drops on the selected
	target and a cancel key reverts. Drop/cancel are bound via ContextActionService
	only for the duration of a drag (so they never shadow those buttons outside
	grab mode) and sunk so they don't also close the screen.

	Both gamepad and keyboard flow through here — the only difference is which
	KeyCodes are used (from Config). Controlled (script-owned) drags are ignored.

	Constructed by Core with the injected transition `api` and input
	`env`; selection reads, action binds and input come through `env` so the grab
	flow can be driven headlessly under test.
]]

const Janitor = require("../../Janitor")
const Types = require("../Types")

type TransitionSurface = Types.TransitionSurface
type Env = Types.Env
type DragState = Types.DragState
type DraggingState = Types.DraggingState

const DROP_ACTION = "DragDropSelectionDrop"
const CANCEL_ACTION = "DragDropSelectionCancel"
const HIGH_PRIORITY = Enum.ContextActionPriority.High.Value

return function(api: TransitionSurface, env: Env)
	local janitor: any = nil
	local dragJanitor: any = nil -- CAS binds live only during a selection drag

	-- The live drag when it is a selection drag (grab mode), narrowed; else nil.
	const function selectionDrag(st: DragState): DraggingState?
		if st.Kind == "Dragging" and not st.Controlled and (st.Device == "Gamepad" or st.Device == "Keyboard") then
			return st
		end
		return nil
	end

	const function onSelectionChanged()
		if not selectionDrag(api.GetState()) then
			return
		end
		const selected = env.GetSelectedObject()
		const entry = if selected then api.ResolveTarget(selected) else nil
		api.UpdateHover(entry)
	end

	const function onAction(actionName: string, inputState: Enum.UserInputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if not selectionDrag(api.GetState()) then
			return Enum.ContextActionResult.Pass
		end
		if actionName == DROP_ACTION then
			api.Drop()
		elseif actionName == CANCEL_ACTION then
			api.CancelDrag()
		end
		return Enum.ContextActionResult.Sink
	end

	const function onDragStarted()
		const drag = selectionDrag(api.GetState())
		if not drag then
			return
		end
		if dragJanitor then
			dragJanitor:Destroy()
		end
		dragJanitor = Janitor.new()

		-- Device-appropriate drop/cancel keys, read live from config.
		local dropKey: Enum.KeyCode
		local cancelKey: Enum.KeyCode?
		if drag.Device == "Gamepad" then
			dropKey = api.GetConfig("GamepadDropKeyCode")
			cancelKey = api.GetConfig("GamepadCancelKeyCode")
		else
			dropKey = api.GetConfig("KeyboardLiftKeyCode") -- Return toggles lift→drop
			cancelKey = api.GetConfig("KeyboardCancelKeyCode")
		end

		env.BindAction(DROP_ACTION, onAction, HIGH_PRIORITY, dropKey)
		if cancelKey then
			env.BindAction(CANCEL_ACTION, onAction, HIGH_PRIORITY, cancelKey)
		end
		dragJanitor:Add(function()
			env.UnbindAction(DROP_ACTION)
			env.UnbindAction(CANCEL_ACTION)
		end, true)

		onSelectionChanged() -- snap the ghost onto the initially selected slot
	end

	const function onDragEnded()
		if dragJanitor then
			dragJanitor:Destroy()
			dragJanitor = nil
		end
	end

	-- A lift key on a selected source enters grab mode (a menu "Switch" button can
	-- also call DragDrop.BeginDrag directly).
	const function onInputBegan(input: Types.InputLike)
		if api.GetState().Kind ~= "Idle" then
			return
		end
		const keyCode = input.KeyCode
		if keyCode ~= api.GetConfig("GamepadLiftKeyCode") and keyCode ~= api.GetConfig("KeyboardLiftKeyCode") then
			return
		end
		const selected = env.GetSelectedObject()
		if not selected then
			return
		end
		const entry = api.ResolveSource(selected)
		if entry then
			api.BeginSelectionDrag(entry.Instance)
		end
	end

	const backend = {}

	function backend.Start()
		if janitor then
			return
		end
		janitor = Janitor.new()
		janitor:Add(env.SelectionChanged:Connect(onSelectionChanged))
		janitor:Add(env.InputBegan:Connect(onInputBegan))
		janitor:Add(api.DragStarted:Connect(onDragStarted), "Disconnect")
		janitor:Add(api.DragEnded:Connect(onDragEnded), "Disconnect")
		janitor:Add(function()
			if dragJanitor then
				dragJanitor:Destroy()
				dragJanitor = nil
			end
		end, true)
	end

	function backend.Stop()
		if janitor then
			janitor:Destroy()
			janitor = nil
		end
		if dragJanitor then
			dragJanitor:Destroy()
			dragJanitor = nil
		end
	end

	return backend
end
