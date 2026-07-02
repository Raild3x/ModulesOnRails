--!strict
--[=[
	@class ClientReplicator
	@client

	The client-side mirror of a `ServerReplicator`. Construction is entirely
	server-driven — clients never create or destroy replicators directly.

	Call `RequestData()` once to request the initial snapshot and begin live
	replication. Register `ForEach`/`OnNew` listeners **before** calling it so
	they receive replicators from the initial snapshot too.

	```lua
	local ClientReplicator = require(Packages.TableReplicator).Client

	ClientReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	ClientReplicator.RequestData():andThen(function()
		print("initial snapshot applied")
	end)
	```

	Access replicated data through the `.Manager` property. To listen to server-fired
	custom signals, use the `.Server` proxy: `replicator.Server.MySignal:Connect(fn)`.
]=]

const Types = require("../Shared/Types")
const TableManagerModule = Types.TableManager
const BaseReplicator = require("../Shared/BaseReplicator")
const ClientTransportModule = require("../Shared/Transport/ClientTransport")
const Protocol = require("../Shared/Transport/Protocol")
const FlatCodec = require("../Shared/Serialization/FlatCodec")
const OpApplier = require("./OpApplier")
const ClientCustomRemote = require("./ClientCustomRemote")

type WireMessage = Types.WireMessage
type WireCreateItem = Types.WireCreateItem
type WireDestroyItem = Types.WireDestroyItem
type WireSetParentItem = Types.WireSetParentItem
type WireOpsItem = Types.WireOpsItem
type ClientTransport = ClientTransportModule.ClientTransport
type Promise = Types.Promise<()>

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

const ClientReplicator = setmetatable({}, BaseReplicator)
ClientReplicator.ClassName = "ClientReplicator"
ClientReplicator.__index = ClientReplicator


type CR_Internal = Types.CR_Internal
export type ClientReplicator = Types.ClientReplicator

--------------------------------------------------------------------------------
--// Message handling //--
--------------------------------------------------------------------------------

const getFromId = BaseReplicator.GetFromId :: (id: number) -> CR_Internal?

-- Forward-declared so `buildFromCreateItem` can capture it in the Server proxy
-- closure. Assigned in the Bootstrap section below; always set before any
-- `ClientCustomRemote.Fire`/`InvokeFunction` call can reach it.
local transport: ClientTransport? = nil
local getTransport: () -> ClientTransport = nil :: any


-- Builds a `ClientReplicator` from a decoded `Create` item. Its parent (if
-- any) is asserted to already exist: every server-side path that emits a
-- `Create` only does so after the referenced parent has already been sent
-- to the same player (see ServerReplicator's module docs), so a missing
-- parent here means the items arrived out of order -- a bug, not a race to
-- tolerate.
const function buildFromCreateItem(item: WireCreateItem): CR_Internal
	const parent = if item.ParentId ~= FlatCodec.NoParent
		then getFromId(item.ParentId)
		else nil
	assert(item.ParentId == FlatCodec.NoParent or parent ~= nil, `ClientReplicator: parent {item.ParentId} for new replicator {item.Id} does not exist yet`)

	-- Data is already deep-copied per item by MessageCodec.Decode (table interning is in-band).
	const manager = TableManagerModule.new(item.Data)
	-- Empty string on the wire encodes "no namespace" (anonymous replicator).
	const base = BaseReplicator.new({
		Id = item.Id,
		Namespace = if item.Token ~= "" then item.Token else nil,
		Tags = item.Tags,
		Manager = manager,
		Parent = parent,
	})
	const replicator = setmetatable(base, ClientReplicator) :: CR_Internal

	-- Type map populated from the Create item's Remotes field and updated by
	-- REMOTE_META signal ops for remotes registered after the snapshot.
	local remoteTypes: { [string]: string } = (item.Remotes :: any) or {}
	;(replicator :: any)._RemoteTypes = remoteTypes

	-- Build the Server proxy. Accessing `replicator.Server.MySignal` lazily
	-- creates a `ClientCustomRemote` for that name and caches it in the proxy
	-- table so subsequent accesses return the same object.
	local serverProxy = {}
	setmetatable(serverProxy, {
		__index = function(t, name)
			local remote = ClientCustomRemote.new(name, replicator, getTransport, nil, remoteTypes[name])
			rawset(t, name, remote)
			return remote
		end,
		__newindex = function(_t, k, _v)
			error(`ClientReplicator.Server: cannot set '{k}' -- Server proxy is read-only`)
		end,
	})
	;(replicator :: any).Server = serverProxy

	return replicator
end

-- Recursively tears down `self` and every descendant (mirrors the server
-- only ever sending one `Destroy` item for the root of a removed subtree).
const function destroyInternal(self: CR_Internal)
	for _, child in self:GetChildren() do
		destroyInternal(child)
	end
	getmetatable(ClientReplicator).Destroy(self)
end

-- Applies every item in one wire message, in order. `Create` items are
-- built first (silently -- no signals/listeners yet) so any later item in
-- the SAME message can already see a fully-formed hierarchy; `ChildAdded`
-- and creation listeners fire only after the whole message has been built.
const function handleMessage(message: WireMessage)
	const created: { CR_Internal } = {}

	for _, item in message.Items do
		if item.Op == FlatCodec.Op.Create then
			table.insert(created, buildFromCreateItem(item :: WireCreateItem))
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
			-- op Values are already deep-copied per entry by MessageCodec.Decode.
			-- Signal-kind entries are routed to the Server proxy; data ops go to
			-- OpApplier. We separate them here to preserve delivery order: a Signal
			-- that follows a Set in the same OpsItem fires after that Set is applied.
			const allOps = FlatCodec.DecodeOps(opsItem)
			const dataOps = {}
			for _, op in allOps do
				if op.Kind == "Signal" then
					-- Flush any buffered data ops first so they're applied before
					-- this signal fires (mirrors the server-side enqueue order).
					if #dataOps > 0 then
						OpApplier.Apply(replicator.Manager, dataOps :: any)
						table.clear(dataOps)
					end
					local signalName = op.Path[1] :: string
					local args = op.Value :: { any }
					local serverProxy = (replicator :: any).Server
					if serverProxy ~= nil then
						-- Remote-type metadata push: update the type map and any cached remote.
						if signalName == Protocol.REMOTE_META then
							local remoteName = args[1] :: string
							local remoteKind = args[2] :: string
							local remoteTypes: { [string]: string } = (replicator :: any)._RemoteTypes
							if remoteTypes then
								remoteTypes[remoteName] = remoteKind
							end
							local cached = rawget(serverProxy, remoteName) :: any
							if cached then
								cached._RemoteType = remoteKind
								cached._Unreliable = remoteKind == "Unreliable"
							end
						-- Ordered function response: resolve the pending InvokeAsync promise.
						elseif type(args) == "table" and args[1] == Protocol.ORDERED_FN_RESPONSE then
							local corrId = args[2] :: number
							local results = table.create(#args - 2)
							for i = 3, #args do results[i - 2] = args[i] end
							ClientCustomRemote._ResolveInvocation(corrId, results)
						else
							-- Regular ordered signal: fire the matching ClientCustomRemote.
							local remote = rawget(serverProxy, signalName) :: any
							if remote then
								remote:_FireClient(table.unpack(args))
							end
						end
					end
				else
					table.insert(dataOps, op)
				end
			end
			if #dataOps > 0 then
				OpApplier.Apply(replicator.Manager, dataOps :: any)
			end
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
	@within ClientReplicator
	@method Destroy
	@ignore
	ClientReplicators are torn down by the server, never by local code. Calling
	this method directly raises an error.
]=]
function ClientReplicator.Destroy(self: CR_Internal)
	error("Cannot destroy a ClientReplicator directly -- destruction is server-driven.")
end

--------------------------------------------------------------------------------
--// Bootstrap //--
--------------------------------------------------------------------------------

getTransport = function(): ClientTransport
	if transport == nil then
		const created = ClientTransportModule.new()
		created.MessageReceived:Connect(handleMessage)
		-- Route server→client custom signal fires to the matching remote on
		-- the receiving replicator's Server proxy.
		local sigReceived = created.SignalReceived :: any
		sigReceived:Connect(function(id: number, name: string, ...: any)
			const replicator = getFromId(id)
			if replicator == nil then return end
			local serverProxy = (replicator :: any).Server
			if serverProxy == nil then return end
			local remote = rawget(serverProxy, name) :: any
			if remote then
				remote:_FireClient(...)
			end
		end)
		transport = created
	end
	return transport :: ClientTransport
end

--[=[
	@tag Static
	@within ClientReplicator
	@function RequestData
	@return Promise<()>

	Requests the initial snapshot from the server and begins live replication.
	Returns a Promise that resolves once the server confirms the full snapshot
	has been sent. Safe to call more than once (subsequent calls are no-ops).

	Register `ForEach`/`OnNew` listeners **before** calling this so they receive
	replicators from the initial snapshot.
]=]
function ClientReplicator.RequestData(): Promise
	return getTransport():RequestData()
end

return ClientReplicator
