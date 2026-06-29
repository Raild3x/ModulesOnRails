--!strict
--[=[
	@ignore
	@class FakeIntermediary

	A same-process stand-in for the RemoteEvent boundary between
	`ServerReplicator` and one-or-more `ClientReplicator` worlds, so a spec
	can drive the real server API and assert on real client-side
	`BaseReplicator` state -- for multiple independent simulated clients at
	once -- without a second, real client process.

	Each `:Connect()`-ed `FakeClient` gets its own `BaseReplicator` realm
	(see `BaseReplicator._Realm`/`_NewRealm`), so two clients never see each
	other's replicators, matching how two real Roblox clients each run in
	their own Lua VM. Composes with `spyOnTransport()`/the spec's `noop()`
	baseline by ALWAYS chaining to whatever `SendMessage` was installed
	before it (saved at construction, restored on `:Destroy()`).

	`FakeClient:RequestData()` fires `PlayerRequestedData` directly; it
	deliberately never calls the real `ClientReplicator.RequestData()`,
	which would hang waiting for a real RemoteEvent in this test realm.
	Every `:RequestData()` call also (re-)delivers a mirror of
	`ServerReplicator.All` into that client's realm (its scope replicates to
	everyone) -- pre-existing, documented behavior, not something this
	helper fixes. Data ops still require the caller to invoke
	`ServerReplicator._FrameCoordinator:Flush()` themselves, exactly like
	existing tests already do; this helper does not auto-flush.
	`:Destroy()` only restores transport/realm state -- it does not
	simulate `PlayerRemoving`; fire that directly on a client's `.Player` if
	a test needs it.
]=]

const ServerReplicator = require("../../Server/ServerReplicator")
const ClientReplicator = require("../../Client/ClientReplicator")
const BaseReplicator = require("../../Shared/BaseReplicator")
const Types = require("../../Shared/Types")

type SendMessage = (self: any, player: Player, message: Types.WireMessage) -> ()

--[=[
	A real `RemoteEvent:FireClient` deep-copies its payload crossing the
	network boundary, so the server's own `Tags`/`Manager.Raw` tables (passed
	into wire items BY REFERENCE -- see `ServerReplicator.buildCreateItem`)
	never alias the client's. Forwarding `message` as-is would skip that copy
	entirely, aliasing server/client state and re-freezing an already-frozen
	`Tags` table. This stands in for that copy.
]=]
const function deepCopyMessage(value: any): any
	if type(value) ~= "table" then
		return value
	end
	const copy = {}
	for k, v in value do
		copy[deepCopyMessage(k)] = deepCopyMessage(v)
	end
	return copy
end

--------------------------------------------------------------------------------
--// FakeClient //--
--------------------------------------------------------------------------------

local FakeClient = {}
FakeClient.__index = FakeClient

export type FakeClient = typeof(setmetatable(
	{} :: {
		Player: Player,
		_realm: BaseReplicator.Realm,
	},
	FakeClient
))

function FakeClient.new(player: Player): FakeClient
	return setmetatable({
		Player = player,
		_realm = BaseReplicator._NewRealm(),
	}, FakeClient) :: FakeClient
end

--[=[
	Runs `fn` with this client's realm active, restoring whatever realm was
	active before -- even if `fn` throws -- so a failed assertion inside
	`fn` can never leave a later test running against the wrong realm.
	Scopes any `BaseReplicator` static (`GetFromId`, `GetAll`, `OnNew`, ...)
	to THIS simulated client.
]=]
function FakeClient.Use(self: FakeClient, fn: () -> any?): any
	const previous = BaseReplicator._Realm
	BaseReplicator._Realm = self._realm
	const ok, result = pcall(fn)
	BaseReplicator._Realm = previous
	if not ok then
		error(result, 0)
	end
	return result
end

function FakeClient.GetFromId(self: FakeClient, id: number): any
	return self:Use(function()
		return BaseReplicator.GetFromId(id)
	end)
end

--[=[
	Simulates this client calling `ClientReplicator.RequestData()`:
	synchronously fires the real handshake signal so any snapshot lands in
	this client's realm before this returns.
]=]
function FakeClient.RequestData(self: FakeClient)
	ServerReplicator._Transport.PlayerRequestedData:Fire(self.Player)
end

--------------------------------------------------------------------------------
--// FakeIntermediary //--
--------------------------------------------------------------------------------

const FakeIntermediary = {}
FakeIntermediary.__index = FakeIntermediary

export type FakeIntermediary = typeof(setmetatable(
	{} :: {
		_clientsByPlayer: { [Player]: FakeClient },
		_previousSendMessage: SendMessage,
		_destroyed: boolean,
	},
	FakeIntermediary
))

function FakeIntermediary.new(): FakeIntermediary
	const transport = ServerReplicator._Transport
	const self = setmetatable({
		_clientsByPlayer = {},
		_previousSendMessage = transport.SendMessage,
		_destroyed = false,
	}, FakeIntermediary) :: FakeIntermediary

	transport.SendMessage = function(transportSelf, sentTo, message)
		const client = self._clientsByPlayer[sentTo]
		if client then
			const delivered = deepCopyMessage(message)
			client:Use(function()
				ClientReplicator._HandleMessage(delivered)
				return nil
			end)
		end
		self._previousSendMessage(transportSelf, sentTo, message)
	end

	return self
end

--[=[
	Connects a new simulated client for `player` (a fresh plain-table
	stand-in is created if omitted), with its own independent
	`BaseReplicator` realm.
]=]
function FakeIntermediary.Connect(self: FakeIntermediary, player: Player?): FakeClient
	const resolvedPlayer = (player or ({ Name = "FakeClientPlayer" } :: any)) :: Player
	const client = FakeClient.new(resolvedPlayer)
	self._clientsByPlayer[resolvedPlayer] = client
	return client
end

function FakeIntermediary.Destroy(self: FakeIntermediary)
	if self._destroyed then
		return
	end
	self._destroyed = true
	ServerReplicator._Transport.SendMessage = self._previousSendMessage
end

return FakeIntermediary
