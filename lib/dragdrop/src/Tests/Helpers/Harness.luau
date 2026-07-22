--[[
	DragDrop test harness.

	Installs fake implementations into the package's Env seam so specs can drive
	the full state machine headlessly — no real rendering (the real GhostLayer uses
	RenderStepped, which errors off the client), no real device input, and a
	controllable clock and preferred-input class.

	It also exposes the same Env-shaped `InputEnv` to the pointer/selection backends
	(via StartPointerBackend / StartSelectionBackend), plus simulation helpers
	(MouseDown/Move/Up, TouchStart/Move/End, Render, SetSelected, PressKey,
	FireAction), which drive the backends through the fake signals. The fake clock
	(Advance) is the single time authority: it moves the clock and fires any due
	Delay timers, so the touch long-press is deterministic.

	Usage:
		local harness = Harness.new()
		local pointer = harness:StartPointerBackend()
		-- ... register frames, simulate input, assert ...
		harness:Destroy() -- stops backends, restores Env/Config, cancels any drag
]]

const Core = require("../../Core")
const PointerBackend = require("../../Backends/PointerBackend")
const SelectionBackend = require("../../Backends/SelectionBackend")
const Signal = require("../../../Signal")

const Harness = {}
Harness.__index = Harness

function Harness.new()
	const self = setmetatable({}, Harness)

	self.CurrentClass = "MouseKeyboard"
	self.Clock = 0
	self.ClassObservers = {} :: { [(newClass: string) -> ()]: true }
	self.HitList = {} :: { GuiObject } -- what GuiObjectsAt returns
	self.Ghosts = {} :: { any }
	self.LastGhost = nil :: any

	-- Backend input state.
	self.Pointer = Vector2.zero -- what env.PointerLocation returns (mouse)
	self.Selected = nil :: Instance? -- what env.GetSelectedObject returns
	self.Actions = {} :: { [string]: any } -- currently bound CAS actions
	self.Timers = {} :: { any } -- pending env.Delay callbacks
	self._backends = {} :: { any } -- backends started via this harness

	-- Fake input signals, built on the `Signal` package production uses. Its
	-- connections carry Disconnect + Destroy, so backend janitors clean them up,
	-- and Fire runs handlers synchronously.
	self.InputBegan = Signal.new()
	self.InputChanged = Signal.new()
	self.InputEnded = Signal.new()
	self.RenderStepped = Signal.new()
	self.SelectionChanged = Signal.new()

	const function fakeMount(_params: any): any
		const ghost = {
			Followed = nil :: Vector2?,
			Snapped = nil :: any,
			Cleaned = false,
		}
		ghost.FollowPointer = function(pointerAbs: Vector2)
			ghost.Followed = pointerAbs
		end
		ghost.SnapToRect = function(absPos: Vector2, absSize: Vector2)
			ghost.Snapped = { Pos = absPos, Size = absSize }
		end
		ghost.Cleanup = function()
			ghost.Cleaned = true
		end
		table.insert(self.Ghosts, ghost)
		self.LastGhost = ghost
		return ghost
	end

	Core._setEnv {
		MountGhost = fakeMount,
		CurrentInputClass = function()
			return self.CurrentClass
		end,
		ObserveInputClass = function(callback: (newClass: string) -> ())
			self.ClassObservers[callback] = true
			return function()
				self.ClassObservers[callback] = nil
			end
		end,
		Clock = function()
			return self.Clock
		end,
		GuiObjectsAt = function(_absPos: Vector2)
			return self.HitList
		end,
	}

	-- The Env handed to backends. Shares the harness's mutable state with the
	-- machine-side patch above, so both sides agree on clock, hit-list, etc.
	self.InputEnv = {
		GuiObjectsAt = function(_absPos: Vector2)
			return self.HitList
		end,
		Clock = function()
			return self.Clock
		end,
		PointerLocation = function()
			return self.Pointer
		end,
		InputBegan = self.InputBegan,
		InputChanged = self.InputChanged,
		InputEnded = self.InputEnded,
		RenderStepped = self.RenderStepped,
		SelectionChanged = self.SelectionChanged,
		GetSelectedObject = function(): Instance?
			return self.Selected
		end,
		BindAction = function(name: string, handler: any, priority: number, ...: Enum.KeyCode)
			self.Actions[name] = { Handler = handler, Priority = priority, Keys = { ... } }
		end,
		UnbindAction = function(name: string)
			self.Actions[name] = nil
		end,
		Delay = function(seconds: number, callback: () -> ()): () -> ()
			const timer = { Due = self.Clock + seconds, Callback = callback, Cancelled = false }
			table.insert(self.Timers, timer)
			return function()
				timer.Cancelled = true
			end
		end,
	}

	return self
end

--------------------------------------------------------------------------------
--// Backend construction //--
--------------------------------------------------------------------------------

function Harness.StartPointerBackend(self: any)
	const backend = PointerBackend(Core._api, self.InputEnv)
	backend.Start()
	table.insert(self._backends, backend)
	return backend
end

function Harness.StartSelectionBackend(self: any)
	const backend = SelectionBackend(Core._api, self.InputEnv)
	backend.Start()
	table.insert(self._backends, backend)
	return backend
end

--------------------------------------------------------------------------------
--// Pointer simulation //--
--------------------------------------------------------------------------------

const function pointerInput(userInputType: Enum.UserInputType, pos: Vector2): any
	return {
		UserInputType = userInputType,
		KeyCode = Enum.KeyCode.None,
		Position = Vector3.new(pos.X, pos.Y, 0),
	}
end

-- Press the mouse at `pos`. The pointer location is set to the same point so the
-- press's start position and subsequent PointerLocation reads agree.
function Harness.MouseDown(self: any, pos: Vector2)
	self.Pointer = pos
	self.InputBegan:Fire(pointerInput(Enum.UserInputType.MouseButton1, pos))
end

function Harness.MouseMove(self: any, pos: Vector2)
	self.Pointer = pos
	self.InputChanged:Fire(pointerInput(Enum.UserInputType.MouseMovement, pos))
end

function Harness.MouseUp(self: any, pos: Vector2?)
	if pos then
		self.Pointer = pos
	end
	self.InputEnded:Fire(pointerInput(Enum.UserInputType.MouseButton1, self.Pointer))
end

-- Touch inputs carry their identity across began/changed/ended, so these return
-- (and re-use) the same input table. TouchStart returns it; feed it back in.
function Harness.TouchStart(self: any, pos: Vector2): any
	const input = pointerInput(Enum.UserInputType.Touch, pos)
	self.InputBegan:Fire(input)
	return input
end

function Harness.TouchMove(self: any, input: any, pos: Vector2)
	input.Position = Vector3.new(pos.X, pos.Y, 0)
	self.InputChanged:Fire(input)
end

function Harness.TouchEnd(self: any, input: any, pos: Vector2?)
	if pos then
		input.Position = Vector3.new(pos.X, pos.Y, 0)
	end
	self.InputEnded:Fire(input)
end

-- Fire one RenderStepped frame (drives the pointer ghost follow + re-hover).
function Harness.Render(self: any, deltaTime: number?)
	self.RenderStepped:Fire(deltaTime or 1 / 60)
end

--------------------------------------------------------------------------------
--// Selection simulation //--
--------------------------------------------------------------------------------

-- Set GuiService.SelectedObject and fire the change (nil clears it).
function Harness.SetSelected(self: any, instance: Instance?)
	self.Selected = instance
	self.SelectionChanged:Fire()
end

-- Fire a key press (grab-mode lift). Only KeyCode is read by the selection backend.
function Harness.PressKey(self: any, keyCode: Enum.KeyCode)
	self.InputBegan:Fire {
		UserInputType = Enum.UserInputType.Keyboard,
		KeyCode = keyCode,
		Position = Vector3.zero,
	}
end

-- Invoke a bound ContextAction as CAS would; returns its ContextActionResult.
function Harness.FireAction(self: any, name: string, inputState: Enum.UserInputState?): any
	const action = self.Actions[name]
	if not action then
		error(`No action bound: {name}`)
	end
	return action.Handler(name, inputState or Enum.UserInputState.Begin, {} :: any)
end

function Harness.IsActionBound(self: any, name: string): boolean
	return self.Actions[name] ~= nil
end

--------------------------------------------------------------------------------
--// Clock / preferred-input //--
--------------------------------------------------------------------------------

-- Simulate a preferred-input class switch: updates the reported class and fires
-- every live class observer (iterating a snapshot so cancel-driven disconnects
-- mid-loop are safe).
function Harness.SwitchInput(self: any, newClass: string)
	self.CurrentClass = newClass
	const snapshot = {}
	for callback in self.ClassObservers do
		table.insert(snapshot, callback)
	end
	for _, callback in snapshot do
		if self.ClassObservers[callback] then
			callback(newClass)
		end
	end
end

-- Advance the fake clock (seconds) and fire any Delay timers that come due. This
-- is the single time authority: clock and long-press timers move together.
function Harness.Advance(self: any, seconds: number)
	self.Clock += seconds
	local index = 1
	while index <= #self.Timers do
		const timer = self.Timers[index]
		if not timer.Cancelled and timer.Due <= self.Clock then
			table.remove(self.Timers, index)
			timer.Callback()
		else
			index += 1
		end
	end
end

function Harness.Destroy(self: any)
	for _, backend in self._backends do
		backend.Stop()
	end
	self._backends = {}
	Core.Cancel()
	if Core.GetInputMode() ~= "Automatic" then
		Core.SetInputMode("Automatic")
	end
	Core._resetEnv()
	Core.ResetConfig()
end

return Harness
