--[[
	DragDrop — the internal singleton the facade sits on.

	Assembles the package's slices — Config, Reactive, Env, Registry, Matching,
	DragMachine — wires their injected edges, owns the input mode + backend
	lifecycle, and exposes the surface DragDrop.luau re-exports. The drag state
	machine itself lives in DragMachine; the transition surface backends and
	specs drive is `DragMachine.Api`, exposed here as `_api`.
]]

const RunService = game:GetService("RunService")

const Types = require("./Types")
const Config = require("./Config")
const Registry = require("./Registry")
const Reactive = require("./Reactive")
const EnvModule = require("./Env")
const DragMachine = require("./DragMachine")
const PointerBackend = require("./Backends/PointerBackend")
const SelectionBackend = require("./Backends/SelectionBackend")

type Payload = Types.Payload
type Device = Types.Device
type TargetDescriptor = Types.TargetDescriptor
type DragHandle = Types.DragHandle
type InputMode = Types.InputMode

const Env = EnvModule.Env

--------------------------------------------------------------------------------
--// Input mode + backend lifecycle //--
--------------------------------------------------------------------------------

const backends: { Types.Backend } = {}
local backendsActive = false
local inputMode: InputMode = "Automatic"

-- Backends run only while there is something registered to drive, in Automatic
-- mode. Idempotent: a no-change reconcile touches nothing.
const function reconcileBackends()
	const shouldRun = inputMode == "Automatic" and Registry.HasRegistrations()
	if shouldRun == backendsActive then
		return
	end
	backendsActive = shouldRun
	for _, backend in backends do
		if shouldRun then
			backend.Start()
		else
			backend.Stop()
		end
	end
end

--------------------------------------------------------------------------------
--// Public surface (re-exported by the facade) //--
--------------------------------------------------------------------------------

const Core = {}

Core.DragStarted = Reactive.DragStarted
Core.Dropped = Reactive.Dropped
Core.DragEnded = Reactive.DragEnded
Core.ActivePayloadChanged = Reactive.ActivePayloadChanged
Core.HoveredTargetChanged = Reactive.HoveredTargetChanged

Core.RegisterSource = Registry.RegisterSource
Core.RegisterTarget = Registry.RegisterTarget

Core.Drop = DragMachine.Drop
Core.Cancel = DragMachine.Cancel
Core.IsDragging = DragMachine.IsDragging
Core.ConsumeActivation = DragMachine.ConsumeActivation

-- Same function objects (not wrappers), so Configure's error levels still blame
-- the consumer's call site.
Core.Configure = Config.Configure
Core.ResetConfig = Config.Reset

function Core.BeginDrag(instance: GuiObject, position: Vector2?): DragHandle?
	const entry = Registry.ResolveSource(instance)
	if not entry then
		return nil
	end

	const controlled = inputMode == "Scriptable" or position ~= nil
	-- A positioned BeginDrag is a pointer-controlled drag (Mouse); an unpositioned
	-- one is a selection grab on the current selection device. GhostStyle then falls
	-- out of the device via the machine's single mapping.
	local grabPoint: Vector2
	local device: Device
	if position ~= nil then
		grabPoint = position
		device = "Mouse"
	else
		grabPoint = entry.Instance.AbsolutePosition + entry.Instance.AbsoluteSize / 2
		device = if Env.CurrentInputClass() == "Gamepad" then "Gamepad" else "Keyboard"
	end

	return DragMachine.Begin(entry, grabPoint, device, controlled)
end

function Core.SetInputMode(mode: InputMode)
	if mode ~= "Automatic" and mode ~= "Scriptable" then
		error(`[DragDrop] Invalid input mode: {tostring(mode)}`, 2)
	end
	if mode == inputMode then
		return
	end
	DragMachine.Cancel() -- clean slate across a mode switch
	inputMode = mode
	reconcileBackends()
end

function Core.GetInputMode(): InputMode
	return inputMode
end

function Core.GetActivePayload(): Payload?
	return Reactive.ActivePayload.get()
end

function Core.GetHoveredTarget(): TargetDescriptor?
	return Reactive.HoveredTarget.get()
end

--------------------------------------------------------------------------------
--// Test seam (underscore-private) //--
--------------------------------------------------------------------------------

-- The machine's transition surface, exposed for specs (backends get it below).
Core._api = DragMachine.Api

Core._setEnv = EnvModule.Patch
Core._resetEnv = EnvModule.Reset

--------------------------------------------------------------------------------
--// Wiring (the injected edges between slices) //--
--------------------------------------------------------------------------------

-- Registration side effects the store can't own itself: backend lifecycle, and
-- releasing a drag/hover whose entry just unregistered (this keeps the edge an
-- injected callback rather than a Registry → state-machine require).
Registry.OnChanged = reconcileBackends
Registry.OnSourceRemoved = DragMachine.CancelIfSource
Registry.OnTargetRemoved = DragMachine.ReleaseHoverIfTarget

-- The selection backend's lift is an unpositioned BeginDrag; it routes through
-- the public surface because input mode lives here.
DragMachine.SetBeginSelectionDrag(function(instance: GuiObject): DragHandle?
	return Core.BeginDrag(instance, nil)
end)

if RunService:IsClient() then
	table.insert(backends, PointerBackend(DragMachine.Api, Env))
	table.insert(backends, SelectionBackend(DragMachine.Api, Env))
end

return Core
