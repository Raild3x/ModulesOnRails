--[[
	DragDrop — reactive state (Fusion-free observables) + cross-cutting signals.

	Owns the two observed values (active payload, hovered target), the three
	public signals, and SafeCall — the pcall guard every user callback in the
	package runs under, so a throwing consumer callback can never break a drag.
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
	observe: (callback: (value: T) -> ()) -> () -> (),
}

const function createObservable<T>(initial: T): Observable<T>
	local value: T = initial
	const observers: { [number]: (value: T) -> () } = {}
	local nextId = 0

	return {
		get = function(): T
			return value
		end,
		set = function(newValue: T)
			if value == newValue then
				return
			end
			value = newValue
			for _, callback in observers do
				Reactive.SafeCall(callback, newValue)
			end
		end,
		observe = function(callback: (value: T) -> ()): () -> ()
			const id = nextId
			nextId += 1
			observers[id] = callback
			Reactive.SafeCall(callback, value) -- fire immediately with current value
			return function()
				observers[id] = nil
			end
		end,
	}
end

Reactive.ActivePayload = createObservable(nil :: Payload?)
Reactive.HoveredTarget = createObservable(nil :: TargetDescriptor?)

Reactive.DragStarted = Signal.new()
Reactive.Dropped = Signal.new()
Reactive.DragEnded = Signal.new()

return Reactive
