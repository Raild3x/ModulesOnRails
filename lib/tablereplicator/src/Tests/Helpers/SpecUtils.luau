--!strict
--[=[
	@ignore
	@class SpecUtils

	Shared test-only utilities used across every `tablereplicator2` spec
	file, so each file doesn't redeclare the same ~70 lines of setup.
	Requiring this module (from any spec file) installs the permanent no-op
	`SendMessage`/`NotifyDataSent` baseline on `ServerReplicator._Transport`
	exactly once -- `require` caches modules, so it's safe for every spec
	file to require this and not worry about install order or duplication.

	`Player` targets throughout this whole test suite are plain tables
	(`:: any`-cast), never real `Player` Instances: every targeting/hierarchy
	code path only ever uses a player value as an opaque dictionary key, so
	a real `Players` connection isn't needed to exercise it. That's also WHY
	the no-op baseline below is necessary -- the real `ServerTransport.
	SendMessage`/`NotifyDataSent` call `:FireClient`, which errors on a
	non-Instance target.
]=]

const ServerReplicator = require("../../Server/ServerReplicator")
const MessageCodec = require("../../Shared/Serialization/MessageCodec")

local SpecUtils = {}

-- Permanent no-op baseline for `ServerReplicator._Transport.SendMessage`/
-- `NotifyDataSent`, covering every send that happens OUTSIDE a
-- `spyOnTransport()` window: replicator construction/`Destroy` during test
-- setup/cleanup, and `ServerReplicator.All`'s "all" scope eagerly
-- snapshotting any player that fires `PlayerRequestedData`.
local function noop() end
;(ServerReplicator._Transport :: any).SendMessage = noop
;(ServerReplicator._Transport :: any).NotifyDataSent = noop
;(ServerReplicator._Transport :: any).FireSignal = noop

--[=[
	Reassigns `SendMessage` directly on the live transport instance,
	shadowing the class method (see `ServerTransport.__index`) so calls are
	recorded instead of hitting the real method. `restore()` puts back the
	no-op baseline above, NOT the real method. The recorded `.Message` is
	already decoded back into a `WireMessage` (via `MessageCodec.Decode`) so
	existing assertions against `.Message.Items` keep working unchanged even
	though the transport now sends a `buffer` instead of a plain table.
]=]
function SpecUtils.spyOnTransport(): ({ { Player: any, Message: any } }, () -> ())
	local calls = {}
	(ServerReplicator._Transport :: any).SendMessage = function(_self, player, buf, instances)
		table.insert(calls, { Player = player, Message = MessageCodec.Decode(buf, instances) })
	end
	return calls, function()
		(ServerReplicator._Transport :: any).SendMessage = noop
	end
end

-- `ServerReplicator.Token` enforces one-use-per-name globally for the whole
-- process, so every test needs its own unique name. Shared across every spec
-- file (not per-file) so two files can never collide even if they pick the
-- same label.
local tokenCounter = 0
function SpecUtils.uniqueToken(label: string)
	tokenCounter += 1
	return ServerReplicator.Token(`{label}#{tokenCounter}`)
end

function SpecUtils.getTokenName(token: any): string
	return token.__NAME__
end

function SpecUtils.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not SpecUtils.deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function SpecUtils.wireCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[SpecUtils.wireCopy(k)] = SpecUtils.wireCopy(v)
	end
	return copy
end

return SpecUtils
