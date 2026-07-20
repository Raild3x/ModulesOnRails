--[[
	DragDrop — the live input environment (the Env seam).

	The one table through which the drag machine and its backends reach the outside
	world: rendering, preferred-input, clock, and the device-input surface. See
	Types.Env for the shape. Production wires the real services below; the test
	harness patches fakes in with `Patch` and restores with `Reset`. Both mutate
	the table in place: the backends capture it at construction, so its identity
	must never change. There is only ever one live environment.
]]

const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")
const GuiService = game:GetService("GuiService")
const ContextActionService = game:GetService("ContextActionService")

const Types = require("./Types")
const InputUtil = require("./InputUtil")
const GhostLayer = require("./GhostLayer")

const DefaultEnv: Types.Env = {
	-- Rendering + preferred-input + clock.
	MountGhost = GhostLayer.mount,
	ObserveInputClass = InputUtil.ObserveInputClass,
	CurrentInputClass = InputUtil.CurrentInputClass,
	GuiObjectsAt = InputUtil.GuiObjectsAt,
	Clock = os.clock,
	-- Pointer input.
	InputBegan = UserInputService.InputBegan :: any,
	InputChanged = UserInputService.InputChanged :: any,
	InputEnded = UserInputService.InputEnded :: any,
	RenderStepped = RunService.RenderStepped :: any,
	PointerLocation = InputUtil.PointerLocation,
	-- Selection input.
	SelectionChanged = GuiService:GetPropertyChangedSignal("SelectedObject") :: any,
	GetSelectedObject = function(): Instance?
		return GuiService.SelectedObject
	end,
	BindAction = function(name, handler, priority, ...)
		-- createTouchButton is always false: grab-mode drop/cancel never surface a
		-- mobile button (touch uses the pointer backend, not selection).
		ContextActionService:BindActionAtPriority(name, handler, false, priority, ...)
	end,
	UnbindAction = function(name: string)
		ContextActionService:UnbindAction(name)
	end,
	Delay = function(seconds: number, callback: () -> ()): () -> ()
		const thread = task.delay(seconds, callback)
		return function()
			task.cancel(thread)
		end
	end,
}

const live: Types.Env = table.clone(DefaultEnv)

return {
	-- The live environment. Read through it; never replace it.
	Env = live,
	-- Test seam: overlay fakes onto the live env (see Tests/Helpers/Harness).
	Patch = function(patch: { [string]: any })
		for key, value in patch do
			(live :: any)[key] = value
		end
	end,
	-- Refill in place from the defaults rather than reassigning, preserving the
	-- table identity everyone captured.
	Reset = function()
		table.clear(live :: any)
		for key, value in DefaultEnv :: any do
			(live :: any)[key] = value
		end
	end,
}
