--!strict
--[=[
	@ignore
	@class RemoteComponentClientMethodGuard

	Guards the methods of a client-built remote object against being called with
	`.` instead of `:`. Comm's client method wrapper takes the owning object as an
	implicit `self` first argument; a dot-call passes the caller's first *real*
	argument into that slot instead, silently dropping the intended arguments and
	sending the wrong request. The guard detects the mismatch by identity and
	raises a clear error at the call site instead.
]=]

local ClientMethodGuard = {}

--[=[
	@within RemoteComponentClientMethodGuard
	Wraps every function-valued entry of `owner`, in place, so that calling it with
	a `self` other than `owner` (i.e. a `.` call) errors. Non-function entries
	(signals, properties) are left untouched. `label` names the object in errors.
]=]
function ClientMethodGuard.apply(owner: { [string]: any }, label: string): ()
	for name, value in owner do
		if type(value) == "function" then
			local inner = value
			owner[name] = function(self, ...)
				if self ~= owner then
					error(
						`RemoteComponent: '{label}.{name}' is a remote method — call it with ':' `
							.. `(e.g. obj:{name}(...)), not '.', otherwise its arguments are dropped.`,
						2
					)
				end
				return inner(self, ...)
			end
		end
	end
end

return ClientMethodGuard
