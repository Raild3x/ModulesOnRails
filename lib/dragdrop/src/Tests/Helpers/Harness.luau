--[[
	DragDrop test harness.

	Installs fake implementations into the Controller's Env seam so specs can drive
	the full state machine headlessly — no real rendering (the real GhostLayer uses
	RenderStepped, which errors off the client), no real device input, and a
	controllable clock and preferred-input class.

	Usage:
		local harness = Harness.new()
		-- ... register frames, drive drags ...
		harness:Destroy() -- restores Env/Config and cancels any live drag
]]

const Controller = require("../../Controller")

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

	Controller._setEnv {
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

	return self
end

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

-- Advance the fake clock (seconds).
function Harness.Advance(self: any, seconds: number)
	self.Clock += seconds
end

function Harness.Destroy(self: any)
	Controller.Cancel()
	if Controller.GetInputMode() ~= "Automatic" then
		Controller.SetInputMode("Automatic")
	end
	Controller._resetEnv()
	Controller.ResetConfig()
end

return Harness
