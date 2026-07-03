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
const MessageCodec = require("../Shared/Serialization/MessageCodec")
const OpBuffer = require("../Shared/OpBuffer")
const Types = require("../Shared/Types")

type Id = Types.Id
type AppliedOp = Types.AppliedOp
type BufferedOp = Types.BufferedOp
type WireItem = Types.WireItem

const ServerTransportModule = require("../Shared/Transport/ServerTransport")
type ServerTransport = ServerTransportModule.ServerTransport

-- Duck-typed view of `ReplicationScope` (only what the coordinator needs)
type Scope = {
	IsActive: (self: any, player: Player) -> boolean,
	GetActivePlayers: (self: any) -> { Player },
	GetActiveVersion: (self: any) -> number,
}

-- One queued data op plus the scope and the audience captured when it was
-- enqueued (see the module doc for why audience is captured, not resolved live).
-- `Seq` is the enqueue order; a coalesced in-place update bumps it to "now" so
-- the entry resorts to its last-write position at flush (see `Flush`). `Dead`
-- marks an entry subsumed by a later ancestor `Set` on a coalesced replicator
-- -- it stays in `_entries` (cheaper than a mid-array removal) and is filtered
-- out at flush.
type Entry = {
	Scope: Scope,
	Audience: { Player },
	Id: Id,
	Op: BufferedOp,
	Seq: number,
	Dead: boolean?,
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

-- The per-frame drain. Hoisted out of the `IsRunning()` gate below so tests can
-- drive it (via the `_PumpScheduler` seam) -- the Heartbeat connection is still
-- only installed in a live game (RunService:IsRunning()), so production behavior
-- is unchanged.
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

-- One Heartbeat step: if anything is queued this frame, defer a drain so it
-- flushes at the following resumption point. Hearbeat is the last thing to run
-- before Replication, so deferring here targets its following resumption point.
const function pumpScheduler()
	if next(scheduledCoordinators) ~= nil then
		task.defer(reschedule)
	end
end

if RunService:IsRunning() then
	RunService.Heartbeat:Connect(pumpScheduler)
end


const FrameCoordinator = {}
FrameCoordinator.__index = FrameCoordinator

-- Test seam (not part of the public API): runs one Heartbeat scheduler step, so
-- specs can exercise the deferred auto-flush path that is otherwise only wired to
-- Heartbeat in a live game (RunService:IsRunning()).
FrameCoordinator._PumpScheduler = pumpScheduler

-- Per coalesced replicator, `pathKey -> live entry` (see `OpBuffer.PathKey`)
-- so a repeat `Set` on the same path can be updated in place instead of
-- appended. Only ever populated for `Id`s enqueued with `coalesced = true`.
type CoalesceSlots = { [Id]: { [string]: Entry } }

export type FrameCoordinator = typeof(setmetatable(
	{} :: {
		_transport: ServerTransport,
		_entries: { Entry },
		_audienceCache: { [Scope]: { version: number, players: { Player } } },
		_flushScheduled: boolean,
		_seq: number,
		_coalesceSlots: CoalesceSlots,
	},
	FrameCoordinator
))

function FrameCoordinator.new(transport: ServerTransport): FrameCoordinator
	return setmetatable({
		_transport = transport,
		_entries = {},
		_audienceCache = {},
		_flushScheduled = false,
		_seq = 0,
		_coalesceSlots = {},
	}, FrameCoordinator)
end

--[=[
	Queues one `AppliedOp` for replicator `id` (living in `scope`) and schedules
	the global flush. The op's audience is the scope's active players at this
	instant; the capture is shared across every op enqueued in the same
	targeting "era" (see `ReplicationScope.GetActiveVersion`) so a hot frame
	allocates at most one player list per scope per era.

	When `coalesced` is true (an opt-in per-replicator flag), a `Set` is
	collapsed in place rather than appended:
	  * an exact-path repeat overwrites the existing pending entry's value and
	    bumps its `Seq` to "now", so it resorts to its last-write position at
	    flush (preserving the server-wide ordering guarantee for everyone else);
	  * a later ancestor `Set` tombstones (marks `Dead`) any already-buffered
	    descendant `Set`, since the ancestor's value subsumes it;
	  * array ops (`ArrayInsert`/`ArrayRemove`/`ArraySet`) are never collapsed --
	    they're appended normally and act as a barrier, invalidating (not
	    tombstoning) any pending `Set` on an overlapping path so a later `Set`
	    on that path starts a fresh entry after the array op rather than
	    merging across it;
	  * `BatchBegin`/`BatchEnd` markers are dropped entirely -- safe because
	    `OpApplier` already wraps one replicator's whole flush in a single
	    outer `Batch`, making nested markers inert.
]=]
function FrameCoordinator.QueueOp(self: FrameCoordinator, scope: Scope, replicatorId: Id, op: AppliedOp, coalesced: boolean?)
	debug.profilebegin("TR.QueueOp")
	const version = scope:GetActiveVersion()
	local cached = self._audienceCache[scope]
	if cached == nil or cached.version ~= version then
		cached = { version = version, players = scope:GetActivePlayers() }
		self._audienceCache[scope] = cached
	end

	self._seq += 1
	const seq = self._seq

	if not coalesced then
		table.insert(self._entries, {
			Scope = scope,
			Audience = cached.players,
			Id = replicatorId,
			Op = OpBuffer.NormalizeAppliedOp(op),
			Seq = seq,
		})
		scheduleCoordinatorFlush(self)
		debug.profileend()
		return
	end

	if op.Kind == "BatchBegin" or op.Kind == "BatchEnd" then
		debug.profileend()
		return
	end

	local slots = self._coalesceSlots[replicatorId]
	if slots == nil then
		slots = {}
		self._coalesceSlots[replicatorId] = slots
	end

	if op.Kind == "Set" then
		const path = op.Path
		const key = OpBuffer.PathKey(path)

		-- A later ancestor Set subsumes any already-buffered descendant Set.
		for existingKey, slot in slots do
			if existingKey ~= key and OpBuffer.PathRelation(path, slot.Op.Path) == "aPrefixB" then
				slot.Dead = true
				slots[existingKey] = nil
			end
		end

		const value = if op.Diff ~= nil then (op.Diff :: any).new else op.NewValue
		const existing = slots[key]
		if existing ~= nil then
			existing.Op = { Kind = "Set", Path = path, Value = value }
			existing.Seq = seq
			existing.Audience = cached.players
		else
			const entry: Entry = {
				Scope = scope,
				Audience = cached.players,
				Id = replicatorId,
				Op = { Kind = "Set", Path = path, Value = value },
				Seq = seq,
			}
			table.insert(self._entries, entry)
			slots[key] = entry
		end

		scheduleCoordinatorFlush(self)
		debug.profileend()
		return
	end

	-- Array ops are order-sensitive and never collapsed; they're a barrier
	-- for any overlapping pending Set (equal, ancestor, or descendant path).
	const entry: Entry = {
		Scope = scope,
		Audience = cached.players,
		Id = replicatorId,
		Op = OpBuffer.NormalizeAppliedOp(op),
		Seq = seq,
	}
	table.insert(self._entries, entry)

	const opPath = entry.Op.Path
	for existingKey, slot in slots do
		if OpBuffer.PathRelation(opPath, slot.Op.Path) ~= "disjoint" then
			slots[existingKey] = nil
		end
	end

	scheduleCoordinatorFlush(self)
	debug.profileend()
end

--[=[
	Queues an ordered signal (or ordered function response) for replicator `id`.
	The signal rides the same sorted ops buffer as data ops, so it arrives at
	each player in the exact same sequence relative to any data ops enqueued
	in the same frame.

	`audience` is the set of players who should receive the signal (typically
	one player for `Fire` or `scope:GetActivePlayers()` for `FireAll`).
	`args` is a plain array of the signal's payload values.

	Signals are never coalesced or tombstoned — every call produces one entry.
]=]
function FrameCoordinator.QueueSignal(
	self: FrameCoordinator,
	scope: Scope,
	replicatorId: Id,
	name: string,
	audience: { Player },
	args: { any }
)
	self._seq += 1
	table.insert(self._entries, {
		Scope = scope,
		Audience = audience,
		Id = replicatorId,
		Op = { Kind = "Signal" :: "Signal", Path = { name }, Value = args },
		Seq = self._seq,
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
	self._coalesceSlots[replicatorId] = nil
end

--[[
	Assembles each active player's ordered run list from `entries` (already in
	send order) and ships one message per player. Shared by `Flush` (whole
	buffer) and `FlushReplicator` (one replicator's slice). Consecutive ops for
	the same replicator collapse into one run (per-player adjacency).
]]
const function sendEntries(self: FrameCoordinator, entries: { Entry })
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
	Flushes exactly one replicator's queued entries now, leaving every other
	replicator's frame buffering untouched -- the per-replicator counterpart to
	`Flush`, used by `ImmediateFlush` replicators to reach the wire synchronously
	(before the caller's next line) without sweeping out unrelated pending ops.

	Only ever called for a non-coalesced replicator (`ImmediateFlush` and
	`Coalesced` are mutually exclusive), so its entries carry neither bumped
	`Seq` nor `Dead` -- array order already equals send order, so no sort or
	dead-filter is needed. Unlike `Flush`, this does NOT reset `_seq` or clear
	`_audienceCache`: the frame continues and the remaining entries still need
	their captured audience and the monotonic seq counter.
]=]
function FrameCoordinator.FlushReplicator(self: FrameCoordinator, replicatorId: Id)
	const entries = self._entries
	const mine: { Entry } = {}
	const rest: { Entry } = {}
	for _, entry in entries do
		if entry.Id == replicatorId then
			table.insert(mine, entry)
		else
			table.insert(rest, entry)
		end
	end

	if mine[1] == nil then
		return
	end

	self._entries = rest
	self._coalesceSlots[replicatorId] = nil

	debug.profilebegin("TR.FlushReplicator")
	sendEntries(self, mine)
	debug.profileend()
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
	table.clear(self._coalesceSlots)
	self._seq = 0
	
	if entries[1] == nil then
		return
	end
	debug.profilebegin("TR.Flush")

	-- Drop entries a later ancestor Set subsumed, then resort by Seq: a
	-- coalesced in-place update bumps its entry's Seq without moving it in
	-- `_entries`, so enqueue order no longer reflects last-write order once
	-- any in-place update has happened this frame.
	const live = table.create(#entries) :: { Entry }
	for _, entry in entries do
		if not entry.Dead then
			table.insert(live, entry)
		end
	end
	table.sort(live, function(a: Entry, b: Entry)
		return a.Seq < b.Seq
	end)

	-- Assemble each active player's ordered run list, preserving global order.
	-- Consecutive ops for the same replicator collapse into one run (per-player
	-- adjacency). NOTE: when the byte-codec phase wants reusable per-item
	-- segments, switch this to merge on *global* adjacency so run boundaries are
	-- identical for every player (see the plan's performance section).
	sendEntries(self, live)
	debug.profileend()
end

function FrameCoordinator._SendFrame(self: FrameCoordinator, player: Player, runs: { OpRun })
	const items = table.create(#runs) :: { WireItem }
	for i, run in runs do
		items[i] = FlatCodec.OpsItem(run.Id, run.Ops)
	end
	const buf, instances = MessageCodec.Encode(items)
	self._transport:SendMessage(player, buf, instances)
end

return FrameCoordinator
