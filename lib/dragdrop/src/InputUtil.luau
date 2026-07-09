--[[
	DragDrop — shared input/geometry helpers.

	Owns the drag system's single source of truth for coordinates, GUI
	hit-testing, PlayerGui resolution, and preferred-input classification. Every
	other module works in ONE space, defined here:

	  "Canonical space" == GuiObject.AbsolutePosition space == the argument space
	  of LayerCollector:GetGuiObjectsAtPosition. `UserInputService:GetMouseLocation`
	  is offset from this by the GUI inset, so `PointerLocation()` subtracts it
	  once. `InputObject.Position` for mouse/touch is ALREADY in this space, so it
	  is used as-is (the reference double-subtracted the inset here — see #1).
]]

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const GuiService = game:GetService("GuiService")
const UserInputService = game:GetService("UserInputService")

const Types = require("./Types")

type InputClass = Types.InputClass

const InputUtil = {}

--------------------------------------------------------------------------------
--// PlayerGui resolution //--
--------------------------------------------------------------------------------

-- Resolved lazily; refreshed once PlayerGui is available at runtime.
local BasePlayerGui: Instance = game:GetService("StarterGui")

const function detectBasePlayerGui(): Instance
	local isEdit = false
	pcall(function()
		isEdit = RunService:IsEdit()
	end)
	if isEdit then
		return game:GetService("CoreGui")
	end

	if RunService:IsRunning() then
		const localPlayer = Players.LocalPlayer
		if localPlayer then
			const playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
				or localPlayer:WaitForChild("PlayerGui", 10)
			if playerGui then
				return playerGui
			end
		end
	end

	return game:GetService("StarterGui")
end

task.spawn(function()
	BasePlayerGui = detectBasePlayerGui()
end)

function InputUtil.GetBasePlayerGui(): Instance
	return BasePlayerGui
end

--------------------------------------------------------------------------------
--// Coordinate space //--
--------------------------------------------------------------------------------

-- The current GUI inset (top bar). Cheap to query; kept as a function so it
-- stays correct if the inset changes (resolution / topbar toggles).
function InputUtil.GetInset(): Vector2
	return GuiService:GetGuiInset()
end

-- Mouse pointer position in canonical space.
function InputUtil.PointerLocation(): Vector2
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end

-- An InputObject's position in canonical space. Mouse/touch `InputObject.Position`
-- is already inset-relative, so it is returned unchanged (unlike GetMouseLocation).
-- Typed to the one field read so a structurally-equal test fake also satisfies it.
function InputUtil.InputPosition(input: { Position: Vector3 }): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

--------------------------------------------------------------------------------
--// Hit-testing //--
--------------------------------------------------------------------------------

-- Topmost-first list of GuiObjects at a canonical-space point.
function InputUtil.GuiObjectsAt(absPos: Vector2): { GuiObject }
	const ok, result = pcall(function()
		return (BasePlayerGui :: any):GetGuiObjectsAtPosition(absPos.X, absPos.Y)
	end)
	if ok and result then
		return result
	end
	return {}
end

-- Walk `instance` and its ancestors, returning the first entry found in
-- `registry` (registries are keyed by the registered root, but hits and gamepad
-- selection usually land on a descendant such as a hit-area button).
function InputUtil.ResolveRegistered<T>(registry: { [Instance]: T }, instance: Instance?): T?
	local current = instance
	while current do
		const entry = registry[current]
		if entry ~= nil then
			return entry
		end
		current = current.Parent
	end
	return nil
end

-- The nearest LayerCollector ancestor (inclusive), or nil. Used to bound the
-- scroll-lock walk and to keep coordinate work inside one GUI root.
function InputUtil.GetLayerCollector(instance: Instance): LayerCollector?
	local current: Instance? = instance
	while current do
		if current:IsA("LayerCollector") then
			return current :: LayerCollector
		end
		current = current.Parent
	end
	return nil
end

--------------------------------------------------------------------------------
--// Preferred-input classification (#5) //--
--------------------------------------------------------------------------------

const InputTypeToClass: { [Enum.UserInputType]: InputClass } = {
	[Enum.UserInputType.MouseButton1] = "MouseKeyboard",
	[Enum.UserInputType.MouseButton2] = "MouseKeyboard",
	[Enum.UserInputType.MouseButton3] = "MouseKeyboard",
	[Enum.UserInputType.MouseMovement] = "MouseKeyboard",
	[Enum.UserInputType.MouseWheel] = "MouseKeyboard",
	[Enum.UserInputType.Keyboard] = "MouseKeyboard",
	[Enum.UserInputType.Touch] = "Touch",
	[Enum.UserInputType.Gamepad1] = "Gamepad",
	[Enum.UserInputType.Gamepad2] = "Gamepad",
	[Enum.UserInputType.Gamepad3] = "Gamepad",
	[Enum.UserInputType.Gamepad4] = "Gamepad",
	[Enum.UserInputType.Gamepad5] = "Gamepad",
	[Enum.UserInputType.Gamepad6] = "Gamepad",
	[Enum.UserInputType.Gamepad7] = "Gamepad",
	[Enum.UserInputType.Gamepad8] = "Gamepad",
}

-- Group a raw UserInputType into the class used for switch-cancel decisions.
-- Unknown / focus / accelerometer inputs classify as the current preferred class
-- (they should never, on their own, cancel a drag).
function InputUtil.ClassifyInputType(inputType: Enum.UserInputType): InputClass?
	return InputTypeToClass[inputType]
end

-- The current preferred input class, from the most recent meaningful input.
function InputUtil.CurrentInputClass(): InputClass
	const class = InputTypeToClass[UserInputService:GetLastInputType()]
	return class or "MouseKeyboard"
end

-- Observe changes to the preferred input CLASS (not every raw type change).
-- `callback(newClass)` fires only when the class actually changes. Returns a
-- disconnect function. Does not fire immediately (unlike a state observer) — it
-- reports transitions, which is exactly what switch-cancel needs.
function InputUtil.ObserveInputClass(callback: (newClass: InputClass) -> ()): () -> ()
	local lastClass = InputUtil.CurrentInputClass()
	const connection = UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
		const class = InputTypeToClass[inputType]
		if class == nil or class == lastClass then
			return
		end
		lastClass = class
		callback(class)
	end)
	return function()
		connection:Disconnect()
	end
end

return InputUtil
