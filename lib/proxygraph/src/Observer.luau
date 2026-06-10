--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class Observer

	`Observer(proxy)` returns a thin object that exposes all signal types for
	a given ProxyNode or Computed state without polluting the proxy's key
	namespace.

	Signals are created lazily inside ProxyNode.getSignals() so connecting to
	an Observer for the first time on a node carries a one-time allocation
	cost; subsequent calls return the cached signal.

	Usage:
	```lua
	local obs = Observer(proxy.health)
	obs.OnValueChange:Connect(function(new, old) ... end)
	obs.OnChange:Connect(function(new, old) ... end)
	```
]=]

local ProxyNode = require("./ProxyNode")
local DepTracker = require("./DepTracker")
local Types = require("./Types")
type AnySignal = Types.AnySignal

export type Observer<T> = {
	OnChange: Types.Signal<(newValue: T, oldValue: T) -> ()>,
	OnValueChange: Types.Signal<(newValue: T, oldValue: T) -> ()>,
	OnKeyAdded: Types.Signal<(key: any, value: any) -> ()>?,
	OnKeyRemoved: Types.Signal<(key: any, value: any) -> ()>?,
	OnArrayInserted: Types.Signal<(index: number, value: any) -> ()>?,
	OnArrayRemoved: Types.Signal<(index: number, value: any) -> ()>?,
	OnArrayShifted: Types.Signal<(index: number, value: any) -> ()>?,
}

local Observer = {}

--[=[
	Creates an Observer object for `state`. Accepts a `Proxy<T>` or a
	`Computed<T>`; passing anything else is a runtime error.

	The generic parameter `T` flows through to `Observer<T>` for future
	signal typing (Phase 10). For Computed states only `OnChange` and
	`OnValueChange` are meaningful; the structural signals are nil.
]=]
function Observer.new<T>(state: Types.State<T>): Observer<T>
	if ProxyNode.isProxy(state) then
		local signals = ProxyNode.getSignals(state :: any)
		return {
			OnChange = signals.onChange,
			OnValueChange = signals.onValueChange,
			OnKeyAdded = signals.onKeyAdded,
			OnKeyRemoved = signals.onKeyRemoved,
			OnArrayInserted = signals.onArrayInserted,
			OnArrayRemoved = signals.onArrayRemoved,
			OnArrayShifted = signals.onArrayShifted,
		}
	elseif DepTracker.isState(state) then
		local cs = state :: Types.InternalComputedState<T>
		return {
			OnChange = cs._onValueChange,
			OnValueChange = cs._onValueChange,
			OnKeyAdded = nil,
			OnKeyRemoved = nil,
			OnArrayInserted = nil,
			OnArrayRemoved = nil,
			OnArrayShifted = nil,
		}
	end
	error("Observer() expects a ProxyNode proxy or Computed state; got " .. tostring(state), 2)
end

return Observer
