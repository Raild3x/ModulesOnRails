--[[
	DragDrop — observable state + cross-cutting signals.

	Owns the two observed values (active payload, hovered target) and their change
	signals, the three drag-lifecycle signals, and SafeCall — the pcall guard every
	user option callback in the package runs under, so a throwing consumer callback
	can never break a drag. Signal handlers are already isolated: Signal fires each
	on its own task.spawn thread.
]]

const Signal = require("../Signal")
const Types = require("./Types")

type Payload = Types.Payload
type TargetDescriptor = Types.TargetDescriptor

const Reactive = {}

-- Run a user-supplied callback guarded; non-functions are ignored.
function Reactive.SafeCall(fn: any, ...)
	if typeof(fn) == "function" then
		const ok, err = pcall(fn, ...)
		if not ok then
			warn("[DragDrop] callback error:", err)
		end
	end
end

type Observable<T> = {
	get: () -> T,
	set: (value: T) -> (),
	-- Fires the new value on every real change (deduped by `set`). Does not fire
	-- on connect; consumers seed the current value from `get`.
	changed: Signal.Signal<(value: T) -> (), T>,
}

const function createObservable<T>(initial: T): Observable<T>
	local value: T = initial
	const changed: Signal.Signal<(value: T) -> (), T> = Signal.new()

	return {
		get = function(): T
			return value
		end,
		set = function(newValue: T)
			if value == newValue then
				return
			end
			value = newValue
			changed:Fire(newValue)
		end,
		changed = changed,
	}
end

Reactive.ActivePayload = createObservable(nil :: Payload?)
Reactive.HoveredTarget = createObservable(nil :: TargetDescriptor?)

-- Public change signals, one per observed value. They fire the new value on every
-- change (nil on drag end) but never on connect, so pair them with
-- GetActivePayload / GetHoveredTarget to read the current value when you subscribe.
Reactive.ActivePayloadChanged = Reactive.ActivePayload.changed
Reactive.HoveredTargetChanged = Reactive.HoveredTarget.changed

-- Drag lifecycle signals, typed at their definition so every consumer (Core, the
-- facade, the backends) sees the same shape without re-asserting it at each hop.
Reactive.DragStarted = Signal.new() :: Types.Signal<(payload: Payload, source: GuiObject) -> (), Payload, GuiObject>
Reactive.Dropped =
	Signal.new() :: Types.Signal<(payload: Payload, target: TargetDescriptor) -> (), Payload, TargetDescriptor>
Reactive.DragEnded =
	Signal.new() :: Types.Signal<(payload: Payload, target: TargetDescriptor?) -> (), Payload, TargetDescriptor?>

return Reactive
