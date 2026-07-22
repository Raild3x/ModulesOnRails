--!strict
--!native
--!optimize 2
--[=[
	@ignore
	@class ReplicationScope
	@server

	Subscription state shared by one top-level replicator and all of its
	descendants. A child always uses its top-level ancestor's scope (see
	`ServerReplicator`), so changing who a top-level replicator targets changes
	targeting for its whole subtree at once.

	Owns ONLY who this subtree replicates to (active / pending / all) plus an
	`_activeVersion` counter that bumps whenever the active set changes.
	Per-frame data-op ordering and delivery is owned by `FrameCoordinator`,
	which reads the active set through here; the scope still exposes `SendTo`
	for the synchronous structural items `ServerReplicator` ships directly.
]=]

local Players = game:GetService("Players")

local ServerTransportModule = require("../Shared/Transport/ServerTransport")
type ServerTransport = ServerTransportModule.ServerTransport

local ReplicationScope = {}
ReplicationScope.__index = ReplicationScope

export type ReplicationScope = typeof(setmetatable(
	{} :: {
		_transport: ServerTransport,
		_all: boolean,
		_active: { [Player]: true },
		_pending: { [Player]: true },
		_activeVersion: number,
	},
	ReplicationScope
))

function ReplicationScope.new(transport: ServerTransport): ReplicationScope
	return setmetatable({
		_transport = transport,
		_all = false,
		_active = {},
		_pending = {},
		_activeVersion = 0,
	}, ReplicationScope)
end

--------------------------------------------------------------------------------
--// Targeting //--
--------------------------------------------------------------------------------

function ReplicationScope.IsReplicatingToAll(self: ReplicationScope): boolean
	return self._all
end

function ReplicationScope.SetAll(self: ReplicationScope, all: boolean)
	self._all = all
end

function ReplicationScope.IsActive(self: ReplicationScope, player: Player): boolean
	return self._active[player] == true
end

function ReplicationScope.IsPending(self: ReplicationScope, player: Player): boolean
	return self._pending[player] == true
end

--[=[
	True if `player` is targeted at all (actively replicating, or waiting to).
]=]
function ReplicationScope.IsTargeting(self: ReplicationScope, player: Player): boolean
	return self._all or self._active[player] == true or self._pending[player] == true
end

function ReplicationScope.AddPending(self: ReplicationScope, player: Player)
	self._pending[player] = true
end

function ReplicationScope.RemovePending(self: ReplicationScope, player: Player)
	self._pending[player] = nil
end

--[=[
	Marks `player` active, clearing any pending entry. Unconditional (not
	gated on having been pending first): a player targeted via `"All"` is
	never pre-registered as pending, since `IsTargeting` already resolves
	`true` for them without one.
]=]
function ReplicationScope.Activate(self: ReplicationScope, player: Player)
	self._pending[player] = nil
	self._active[player] = true
	self._activeVersion += 1
end

function ReplicationScope.RemoveActive(self: ReplicationScope, player: Player)
	self._active[player] = nil
	self._activeVersion += 1
end

--[=[
	Drops `player` from both pending and active (e.g. on `PlayerRemoving`).
]=]
function ReplicationScope.RemovePlayer(self: ReplicationScope, player: Player)
	self._pending[player] = nil
	self._active[player] = nil
	self._activeVersion += 1
end

function ReplicationScope.GetActivePlayers(self: ReplicationScope): { Player }
	local players = {}
	for player in self._active do
		table.insert(players, player)
	end
	return players
end

--[=[
	A counter that bumps every time the active set changes. `FrameCoordinator`
	reads it to know when its cached per-scope audience snapshot is stale, so a
	hot frame captures the active player list at most once per targeting "era".
]=]
function ReplicationScope.GetActiveVersion(self: ReplicationScope): number
	return self._activeVersion
end

--[=[
	Every player this scope is targeting right now: every current player when
	replicating to `"All"`, otherwise active + pending.
]=]
function ReplicationScope.GetTargetPlayers(self: ReplicationScope): { Player }
	if self._all then
		return Players:GetPlayers()
	end
	local players = {}
	for player in self._active do
		table.insert(players, player)
	end
	for player in self._pending do
		table.insert(players, player)
	end
	return players
end

--------------------------------------------------------------------------------
--// Outbound //--
--------------------------------------------------------------------------------

--[=[
	Sends an already-built message to one player (e.g. an individual snapshot).
	Per-frame data-op delivery is owned by `FrameCoordinator`, not the scope;
]=]
function ReplicationScope.SendTo(self: ReplicationScope, player: Player, buf: buffer, instances: { any }?)
	self._transport:SendMessage(player, buf, instances)
end

return ReplicationScope
