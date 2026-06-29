--!strict
--[=[
	@class ClientReplicator
	@client

	The client-side mirror of a `ServerReplicator`. Construction is entirely
	server-driven -- use `ClientReplicator.RequestData()` to start
	replication, then `BaseReplicator.OnNew`/`ForEach`/`PromiseFirst` (see
	`BaseReplicator`) to find replicators as they arrive.

	```lua
	ClientReplicator.OnNew("PlayerData", function(replicator)
		local manager = replicator:GetManager()
		manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	ClientReplicator.RequestData():andThen(function()
		print("initial snapshot applied")
	end)
	```
]=]

const Promise = require("../../Promise")
const TableManagerModule = require("../../TableManager")
const Types = require("../Shared/Types")
const BaseReplicator = require("../Shared/BaseReplicator")
const ClientTransportModule = require("../Shared/Transport/ClientTransport")
const FlatCodec = require("../Shared/Serialization/FlatCodec")
const RefCodec = require("../Shared/Serialization/RefCodec")
const OpApplier = require("./OpApplier")
const TokenCache = require("../Shared/TokenCache")

type ReplicationToken = Types.ReplicationToken
type WireMessage = Types.WireMessage
type WireCreateItem = Types.WireCreateItem
type WireDestroyItem = Types.WireDestroyItem
type WireSetParentItem = Types.WireSetParentItem
type WireOpsItem = Types.WireOpsItem
type ClientTransport = ClientTransportModule.ClientTransport
type Promise = Promise.Promise

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

const ClientReplicator = setmetatable({}, BaseReplicator)
ClientReplicator.ClassName = "ClientReplicator"
ClientReplicator.__index = ClientReplicator


type CR_Internal = BaseReplicator.BR_Internal<CR_Internal>
export type ClientReplicator = BaseReplicator.BR_Public<ClientReplicator>

--------------------------------------------------------------------------------
--// Message handling //--
--------------------------------------------------------------------------------

const getFromId = BaseReplicator.GetFromId :: (id: number) -> CR_Internal?

--[=[
	@private
	Builds a `ClientReplicator` from a decoded `Create` item. Its parent (if
	any) is asserted to already exist: every server-side path that emits a
	`Create` only does so after the referenced parent has already been sent
	to the same player (see ServerReplicator's module docs), so a missing
	parent here means the items arrived out of order -- a bug, not a race to
	tolerate.
]=]
const function buildFromCreateItem(item: WireCreateItem, refs: { [number]: any }?): CR_Internal
	const parent = if item.ParentId ~= FlatCodec.NoParent
		then getFromId(item.ParentId)
		else nil
	assert(item.ParentId == FlatCodec.NoParent or parent ~= nil, `ClientReplicator: parent {item.ParentId} for new replicator {item.Id} does not exist yet`)

	-- Expand any Model V placeholders in the snapshot into independent copies.
	const data = if refs then RefCodec.ResolveValue(item.Data, refs) else item.Data
	const manager = TableManagerModule.new(data)
	const base = BaseReplicator.new({
		Id = item.Id,
		Token = TokenCache.getOrCreateToken(item.Token),
		Tags = item.Tags,
		Manager = manager,
		Parent = parent,
	})
	return setmetatable(base, ClientReplicator) :: CR_Internal
end

--[=[
	@private
	Recursively tears down `self` and every descendant (mirrors the server
	only ever sending one `Destroy` item for the root of a removed subtree).
]=]
const function destroyInternal(self: CR_Internal)
	for _, child in self:GetChildren() do
		destroyInternal(child)
	end
	getmetatable(ClientReplicator).Destroy(self)
end

--[=[
	@private
	Applies every item in one wire message, in order. `Create` items are
	built first (silently -- no signals/listeners yet) so any later item in
	the SAME message can already see a fully-formed hierarchy; `ChildAdded`
	and creation listeners fire only after the whole message has been built.
]=]
const function handleMessage(message: WireMessage)
	const created: { CR_Internal } = {}
	const refs = message.Refs

	for _, item in message.Items do
		if item.Op == FlatCodec.Op.Create then
			table.insert(created, buildFromCreateItem(item :: WireCreateItem, refs))
		elseif item.Op == FlatCodec.Op.Destroy then
			const destroyItem = item :: WireDestroyItem
			const replicator = getFromId(destroyItem.Id)
			assert(replicator ~= nil, `ClientReplicator: Destroy referenced unknown replicator {destroyItem.Id}`)
			destroyInternal(replicator :: CR_Internal)
		elseif item.Op == FlatCodec.Op.SetParent then
			const setParentItem = item :: WireSetParentItem
			const child = getFromId(setParentItem.Id)
			const newParent = getFromId(setParentItem.ParentId)
			assert(child ~= nil and newParent ~= nil, `ClientReplicator: SetParent referenced an unknown replicator ({setParentItem.Id} -> {setParentItem.ParentId})`)
			child:_SetParentRefs(newParent)
		elseif item.Op == FlatCodec.Op.Ops then
			const opsItem = item :: WireOpsItem
			const replicator = getFromId(opsItem.Id)
			assert(replicator ~= nil, `ClientReplicator: Ops referenced unknown replicator {opsItem.Id}`)

			const ops = FlatCodec.DecodeOps(opsItem)
			if refs then
				-- Expand any Model V placeholders in op values into independent copies.
				for _, op in ops do
					op.Value = RefCodec.ResolveValue(op.Value, refs)
				end
			end
			OpApplier.Apply(replicator.Manager, ops)
		end
	end

	for _, replicator in created do
		const parent = replicator:GetParent()
		if parent then
			parent.ChildAdded:Fire(replicator)
		end
	end
	for _, replicator in created do
		replicator:_FireCreationListeners()
	end
end

-- Test-only escape hatch: lets a spec feed a hand-built `WireMessage`
-- straight into the apply pipeline without a live `ClientTransport`
-- (which would need a real `ServerTransport` instance on the other end of
-- the RemoteEvent to ever resolve). Not part of the public API.
ClientReplicator._HandleMessage = handleMessage

--------------------------------------------------------------------------------
--// Lifecycle //--
--------------------------------------------------------------------------------

--[=[
	Replication is entirely server-driven; a `ClientReplicator` is torn down
	when the server sends a `Destroy` for it, never by local code.
]=]
function ClientReplicator.Destroy(self: CR_Internal)
	error("Cannot destroy a ClientReplicator directly -- destruction is server-driven.")
end

--------------------------------------------------------------------------------
--// Bootstrap //--
--------------------------------------------------------------------------------

local transport: ClientTransport? = nil
const function getTransport(): ClientTransport
	if transport == nil then
		const created = ClientTransportModule.new()
		created.MessageReceived:Connect(handleMessage)
		transport = created
	end
	return transport :: ClientTransport
end

--[=[
	@tag Static
	Requests the initial snapshot from the server and begins live
	replication. Safe to call more than once. Register `OnNew`/`ForEach`
	listeners before calling this so they don't miss anything already in the
	snapshot.
]=]
function ClientReplicator.RequestData(): Promise
	return getTransport():RequestData()
end

return ClientReplicator
