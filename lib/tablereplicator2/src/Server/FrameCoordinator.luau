--!strict
--[=[
	@ignore
	@class FrameCoordinator
	@server

	The single, server-wide ordering point for outbound data ops. Every
	top-level scope funnels its `OnApplied` ops here -- in true server arrival
	order -- instead of each scope buffering and flushing on its own. One
	deferred flush per frame then replays them to each active player in that
	exact global order.

	Audience is captured at enqueue time and intersected with the live active
	set at flush:
	  * a player added to a scope mid-frame is NOT in the captured audience of
	    ops enqueued before their snapshot, so they never double-apply an op
	    already baked into that snapshot; and
	  * a player removed mid-frame fails the live `IsActive` check at flush, so
	    they never receive an op for a replicator they were already told to
	    drop.
]=]

const RunService = game:GetService("RunService")

const FlatCodec = require("../Shared/Serialization/FlatCodec")
const RefCodec = require("../Shared/Serialization/RefCodec")
const MessageCodec = require("../Shared/Serialization/MessageCodec")
const OpBuffer = require("../Shared/OpBuffer")
const Types = require("../Shared/Types")

type Id = Types.Id
type AppliedOp = Types.AppliedOp
type BufferedOp = Types.BufferedOp
type WireItem = Types.WireItem

const ServerTransportModule = require("../Shared/Transport/ServerTransport")
type ServerTransport = ServerTransportModule.ServerTransport

-- Duck-typed view of `ReplicationScope` (only what the coordinator needs), so
-- there is no require dependency -- and therefore no cycle -- between them.
type Scope = {
	IsActive: (self: any, player: Player) -> boolean,
	GetActivePlayers: (self: any) -> { Player },
	GetActiveVersion: (self: any) -> number,
}

-- One queued data op plus the scope and the audience captured when it was
-- enqueued (see the module doc for why audience is captured, not resolved live).
type Entry = {
	Scope: Scope,
	Audience: { Player },
	Id: Id,
	Op: BufferedOp,
}

-- One replicator's contiguous run of ops in a single player's frame; collapses
-- to one `WireOpsItem` at send time.
type OpRun = {
	Id: Id,
	Ops: { BufferedOp },
}

--------------------------------------------------------------------------------
	--// Replication Scheduler //--
--------------------------------------------------------------------------------

local scheduleDirty = false
const scheduledCoordinators: { [FrameCoordinator]: boolean? } = {}
const function scheduleCoordinatorFlush(coordinator: FrameCoordinator)
	scheduleDirty = true
	scheduledCoordinators[coordinator] = true
end

do
	const function reschedule()
		if scheduleDirty then
			scheduleDirty = false
			task.defer(reschedule)
			return 
		end
		for coordinator in scheduledCoordinators do
			coordinator:Flush()
		end
		table.clear(scheduledCoordinators)
	end

	-- Hearbeat is the last thing to run before Replication, so we defer 
	-- here to try and flush during it's following resumption point
	RunService.Heartbeat:Connect(function()
		task.defer(reschedule)
	end)
end


const FrameCoordinator = {}
FrameCoordinator.__index = FrameCoordinator

export type FrameCoordinator = typeof(setmetatable(
	{} :: {
		_transport: ServerTransport,
		_entries: { Entry },
		_audienceCache: { [Scope]: { version: number, players: { Player } } },
		_flushScheduled: boolean,
		_scheduledOps: number,
	},
	FrameCoordinator
))

function FrameCoordinator.new(transport: ServerTransport): FrameCoordinator
	return setmetatable({
		_transport = transport,
		_entries = {},
		_audienceCache = {},
		_flushScheduled = false,
		_scheduledOps = 0,
	}, FrameCoordinator)
end

--[=[
	Queues one `AppliedOp` for replicator `id` (living in `scope`) and schedules
	the global flush. The op's audience is the scope's active players at this
	instant; the capture is shared across every op enqueued in the same
	targeting "era" (see `ReplicationScope.GetActiveVersion`) so a hot frame
	allocates at most one player list per scope per era.
]=]
function FrameCoordinator.QueueOp(self: FrameCoordinator, scope: Scope, replicatorId: Id, op: AppliedOp)
	const version = scope:GetActiveVersion()
	local cached = self._audienceCache[scope]
	if cached == nil or cached.version ~= version then
		cached = { version = version, players = scope:GetActivePlayers() }
		self._audienceCache[scope] = cached
	end

	table.insert(self._entries, {
		Scope = scope,
		Audience = cached.players,
		Id = replicatorId,
		Op = OpBuffer.NormalizeAppliedOp(op),
	})

	scheduleCoordinatorFlush(self)
end

--[=[
	Drops every queued op for replicator `id`. Called when a replicator is
	destroyed so an op enqueued earlier this frame can't flush out after the
	(synchronous) `Destroy` item and reference a replicator the client already
	tore down.
]=]
function FrameCoordinator.DropReplicator(self: FrameCoordinator, replicatorId: Id)
	const entries = self._entries
	const kept: { Entry } = {}
	for _, entry in entries do
		if entry.Id ~= replicatorId then
			table.insert(kept, entry)
		end
	end
	self._entries = kept
end

--[=[
	Drains the global op buffer and sends one ordered message per active player.
	Safe to call directly (e.g. from tests) to force a deterministic flush
	instead of waiting for the deferred one.
]=]
function FrameCoordinator.Flush(self: FrameCoordinator)
	const entries = self._entries
	self._entries = {}
	table.clear(self._audienceCache)
	self._scheduledOps = 0

	if entries[1] == nil then
		return
	end

	-- Assemble each active player's ordered run list, preserving global order.
	-- Consecutive ops for the same replicator collapse into one run (per-player
	-- adjacency). NOTE: when the byte-codec phase wants reusable per-item
	-- segments, switch this to merge on *global* adjacency so run boundaries are
	-- identical for every player (see the plan's performance section).
	const perPlayer: { [Player]: { OpRun } } = {}

	for _, entry in entries do
		const scope = entry.Scope
		for _, player in entry.Audience do
			if not scope:IsActive(player) then
				continue
			end

			local runs = perPlayer[player]
			if runs == nil then
				runs = {}
				perPlayer[player] = runs
			end

			const last = runs[#runs]
			if last ~= nil and last.Id == entry.Id then
				table.insert(last.Ops, entry.Op)
			else
				table.insert(runs, { Id = entry.Id, Ops = { entry.Op } })
			end
		end
	end

	for player, runs in perPlayer do
		self:_SendFrame(player, runs)
	end
end

--[=[
	@private
	The single encode-and-send seam: turns one player's ordered run list into a
	wire message and hands it to the transport. Runs through `RefCodec.Encode`
	so a table shared across this frame's ops (e.g. one fanned-out to two
	managers) is sent once, then `MessageCodec.Encode` into a `buffer` (no more
	plain-table `FireClient` payloads). A future phase shares an encoded
	payload across an audience class without any change to ordering or
	assembly above.
]=]
function FrameCoordinator._SendFrame(self: FrameCoordinator, player: Player, runs: { OpRun })
	const items = table.create(#runs) :: { WireItem }
	for i, run in runs do
		items[i] = FlatCodec.OpsItem(run.Id, run.Ops)
	end
	const encoded, refs = RefCodec.Encode(items)
	const buf, instances = MessageCodec.Encode(encoded, refs)
	self._transport:SendMessage(player, buf, instances)
end

return FrameCoordinator
