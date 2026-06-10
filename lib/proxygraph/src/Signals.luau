--!strict
-- Authors: Logan Hunt (Raildex)
-- June 10, 2026
--[=[
	@class Signals

	Owns storage and lifecycle for the 7 signal types exposed per ProxyNode:
	`onValueChange`, `onChange`, `onKeyAdded`, `onKeyRemoved`,
	`onArrayInserted`, `onArrayRemoved`, `onArrayShifted`.

	Each signal is created lazily and independently — requesting one signal
	type for a node does not allocate the other 6. `getSignals(proxy)` returns
	a metatable-backed table that resolves each field on first access via the
	same lazy creation path.

	`destroy(proxy)` tears down (and `:Destroy()`s) any signals that were
	created for `proxy`, disconnecting all listeners (Observers,
	Computeds, Effects) in the process.
]=]

const SignalLib = require("../Signal")
const Types = require("./Types")

type Proxy = Types.Proxy<any>
type AnySignal = Types.AnySignal

export type SignalName =
	"onValueChange"
	| "onChange"
	| "onKeyAdded"
	| "onKeyRemoved"
	| "onArrayInserted"
	| "onArrayRemoved"
	| "onArrayShifted"

local Signals = {}

-- One table per signal type, keyed by proxy userdata identity.
local _tables: { [SignalName]: { [Proxy]: AnySignal } } = {
	onValueChange = {},
	onChange = {},
	onKeyAdded = {},
	onKeyRemoved = {},
	onArrayInserted = {},
	onArrayRemoved = {},
	onArrayShifted = {},
}

--[=[
	Returns `tbl[node]`, creating it via `factory()` and caching it on first
	access. Generic over the stored value type `S`.
]=]
function Signals.getOrCreate<S>(tbl: { [Proxy]: S }, node: Proxy, factory: () -> S): S
	local value = tbl[node]
	if value == nil then
		value = factory()
		tbl[node] = value
	end
	return value
end

--[=[
	Lazily creates (if needed) and returns the signal of type `name` for `proxy`.
]=]
function Signals.get(name: SignalName, proxy: Proxy): AnySignal
	return Signals.getOrCreate(_tables[name], proxy, function()
		return SignalLib.new() :: any
	end)
end

--[=[
	Returns the signal of type `name` for `proxy` WITHOUT creating it. Used by
	firing call sites so that firing never allocates a signal nobody is
	listening to.
]=]
function Signals.peek(name: SignalName, proxy: Proxy): AnySignal?
	return _tables[name][proxy]
end

--[=[
	Fires `sig` with `...` only if it exists and has at least one listener.
]=]
function Signals.tryFire(sig: AnySignal?, ...: any)
	if sig ~= nil and sig:IsConnectedTo() then
		sig:Fire(...)
	end
end

--[=[
	Returns the OnValueChange signal for `proxy`, creating it lazily on first
	call. Used by Computed/Effect to subscribe without allocating the full
	signals wrapper table.
]=]
function Signals.getOnValueChangeSignal(proxy: Proxy): AnySignal
	return Signals.get("onValueChange", proxy)
end

--[=[
	Returns a table exposing all 7 signal types for `proxy`. Each field is
	resolved (and lazily created/cached) only when first accessed.
]=]
function Signals.getSignals(proxy: Proxy): Types.SignalsTable
	return (
		setmetatable({}, {
			__index = function(_, key: string): AnySignal?
				if _tables[key :: SignalName] ~= nil then
					return Signals.get(key :: SignalName, proxy)
				end
				return nil
			end,
		}) :: any
	) :: Types.SignalsTable
end

--[=[
	Destroys (and disconnects all listeners from) every signal that was
	created for `proxy`, then clears them from storage. Safe to call on a
	proxy that has no signals created.
]=]
function Signals.destroy(proxy: Proxy)
	for _, tbl in _tables do
		local sig = tbl[proxy]
		if sig ~= nil then
			sig:Destroy()
			tbl[proxy] = nil
		end
	end
end

return Signals
