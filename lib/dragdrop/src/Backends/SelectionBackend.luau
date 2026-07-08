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
]]

const ContextActionService = game:GetService("ContextActionService")
const GuiService = game:GetService("GuiService")
const UserInputService = game:GetService("UserInputService")

const Janitor = require("../../Janitor")

const DROP_ACTION = "DragDropSelectionDrop"
const CANCEL_ACTION = "DragDropSelectionCancel"
const HIGH_PRIORITY = Enum.ContextActionPriority.High.Value

return function(api)
	local janitor: any = nil
	local dragJanitor: any = nil -- CAS binds live only during a selection drag

	const function isSelectionDrag(st: any): boolean
		return st.Kind == "Dragging" and not st.Controlled and (st.Device == "Gamepad" or st.Device == "Keyboard")
	end

	const function onSelectionChanged()
		const st = api.GetState()
		if not isSelectionDrag(st) then
			return
		end
		const selected = GuiService.SelectedObject
		const entry = if selected then api.ResolveTarget(selected) else nil
		api.UpdateHover(entry)
	end

	const function onAction(actionName: string, inputState: Enum.UserInputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if not isSelectionDrag(api.GetState()) then
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
		const st = api.GetState()
		if not isSelectionDrag(st) then
			return
		end
		if dragJanitor then
			dragJanitor:Destroy()
		end
		dragJanitor = Janitor.new()

		-- Device-appropriate drop/cancel keys, read live from config.
		local dropKey: Enum.KeyCode
		local cancelKey: Enum.KeyCode?
		if st.Device == "Gamepad" then
			dropKey = api.GetConfig("GamepadDropKeyCode")
			cancelKey = api.GetConfig("GamepadCancelKeyCode")
		else
			dropKey = api.GetConfig("KeyboardLiftKeyCode") -- Return toggles lift→drop
			cancelKey = api.GetConfig("KeyboardCancelKeyCode")
		end

		ContextActionService:BindActionAtPriority(DROP_ACTION, onAction, false, HIGH_PRIORITY, dropKey)
		if cancelKey then
			ContextActionService:BindActionAtPriority(CANCEL_ACTION, onAction, false, HIGH_PRIORITY, cancelKey)
		end
		dragJanitor:Add(function()
			ContextActionService:UnbindAction(DROP_ACTION)
			ContextActionService:UnbindAction(CANCEL_ACTION)
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
	const function onInputBegan(input: InputObject)
		if api.GetState().Kind ~= "Idle" then
			return
		end
		const keyCode = input.KeyCode
		if keyCode ~= api.GetConfig("GamepadLiftKeyCode") and keyCode ~= api.GetConfig("KeyboardLiftKeyCode") then
			return
		end
		const selected = GuiService.SelectedObject
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
		janitor:Add(GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(onSelectionChanged))
		janitor:Add(UserInputService.InputBegan:Connect(onInputBegan))
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
