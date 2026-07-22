--!strict
-- Authors: Logan Hunt (Raildex)
--[=[
	@class EscrowLedger
	@private

	Sole owner of the per-player escrow state stored under
	profile.Data[TradeDataKey]. Both live execution (TradeSession) and recovery
	(TradeRecovery) route every read and write of the trade fields through this
	module — neither touches the profile table directly.

	Every mutating operation follows the same shape: mutate the loaded profile
	in memory, then CommitProfile with a predicate that resolves only once a
	persisted snapshot provably contains the write. Because the consumer's
	inventory and the escrow fields live in the same profile Data table, each
	operation persists atomically with the inventory change it pairs with —
	a crash before the save replays cleanly, a crash after it is already durable.

	Operations (each per single player, each returns a Promise from CommitProfile):
	- EnsureTrade   — create/get the live escrow table (handed to MoveOfferToEscrow)
	- BeginCommit   — Phase 1: stamp tradeId/jobId/executionStart after escrow
	- CopyIncoming  — Phase 2: copy the other player's Outgoing into Incoming
	- MarkReceived  — Phase 3: set received = true
	- Claim         — Phase 4: FinalizeOffer + claimed = true + clear fields
	- Rollback      — RollbackOffer + remove the escrow table
	- Clear         — remove the escrow table (no item movement)
	- Read          — snapshot of the current escrow fields (nil-safe)
]=]

--// Imports //--
const Packages = script.Parent.Parent
const Promise = require(Packages.Promise)

const Types = require(script.Parent.TradeTypes)

--// Types //--
type TradeCallbacks = Types.TradeCallbacks
type TradeStopReason = Types.TradeStopReason

export type TradeMeta = {
	tradeId: string,
	jobId: string,
	executionStart: number,
}

export type EscrowLedger = {
	EnsureTrade: (self: EscrowLedger, player: Player) -> { [string]: any },
	BeginCommit: (self: EscrowLedger, player: Player, meta: TradeMeta) -> any,
	CopyIncoming: (self: EscrowLedger, toPlayer: Player, fromPlayer: Player) -> any,
	MarkReceived: (self: EscrowLedger, player: Player) -> any,
	Claim: (self: EscrowLedger, player: Player, session: any?) -> any,
	Rollback: (self: EscrowLedger, player: Player, reason: TradeStopReason, session: any?) -> any,
	Clear: (self: EscrowLedger, player: Player) -> any,
	Read: (self: EscrowLedger, player: Player) -> { [string]: any }?,
}

type EscrowLedger_Internal = EscrowLedger & {
	_callbacks: TradeCallbacks,
	_dataKey: string,

	_getProfile: (self: EscrowLedger_Internal, player: Player) -> any?,
	_getTrade: (self: EscrowLedger_Internal, player: Player) -> { [string]: any }?,
	_commit: (
		self: EscrowLedger_Internal,
		player: Player,
		isPersisted: ((lastSavedData: { [any]: any }) -> boolean)?
	) -> any,
}

--// Class //--
local EscrowLedger = {}
EscrowLedger.__index = EscrowLedger

--[=[
	@param callbacks TradeCallbacks -- Consumer callbacks (item movement + persistence)
	@param dataKey string -- The profile.Data key this ledger owns
]=]
function EscrowLedger.new(callbacks: TradeCallbacks, dataKey: string): EscrowLedger
	local self = setmetatable({} :: any, EscrowLedger) :: EscrowLedger_Internal
	self._callbacks = callbacks
	self._dataKey = dataKey
	return (self :: any) :: EscrowLedger
end

--// Private //--

function EscrowLedger._getProfile(self: EscrowLedger_Internal, player: Player): any?
	return self._callbacks.GetProfile(player)
end

function EscrowLedger._getTrade(self: EscrowLedger_Internal, player: Player): { [string]: any }?
	const profile = self:_getProfile(player)
	return if profile and profile.Data then profile.Data[self._dataKey] else nil
end

function EscrowLedger._commit(
	self: EscrowLedger_Internal,
	player: Player,
	isPersisted: ((lastSavedData: { [any]: any }) -> boolean)?
): any
	return self._callbacks.CommitProfile(player, isPersisted)
end

--// Public //--

--[=[
	Returns the live escrow table for the player, creating it if absent.
	Errors if the profile is not loaded. This is the table handed to
	MoveOfferToEscrow as context.Trade.
]=]
function EscrowLedger.EnsureTrade(self: EscrowLedger_Internal, player: Player): { [string]: any }
	const profile = self:_getProfile(player)
	assert(profile, `Profile for {player.Name} not loaded`)
	if not profile.Data[self._dataKey] then
		profile.Data[self._dataKey] = {}
	end
	return profile.Data[self._dataKey]
end

--[=[
	Phase 1: stamps the trade metadata onto the player's escrow table (after the
	consumer's MoveOfferToEscrow calls have accumulated into Trade.outgoing) and
	commits. Resolves once the persisted snapshot contains this tradeId at phase 1.
]=]
function EscrowLedger.BeginCommit(self: EscrowLedger_Internal, player: Player, meta: TradeMeta): any
	const profile = self:_getProfile(player)
	if not profile then
		return Promise.reject(`Profile for {player.Name} not loaded`)
	end
	const trade = self:EnsureTrade(player)
	trade.tradeId = meta.tradeId
	trade.jobId = meta.jobId
	trade.executionStart = meta.executionStart
	trade.phase = 1

	const dataKey = self._dataKey
	return self:_commit(player, function(lastSaved)
		const t = lastSaved[dataKey]
		return t ~= nil and t.tradeId == meta.tradeId and (t.phase or 0) >= 1
	end)
end

--[=[
	Phase 2: copies fromPlayer's Outgoing into toPlayer's Incoming and commits
	toPlayer's profile. Resolves once the persisted snapshot shows phase 2.
]=]
function EscrowLedger.CopyIncoming(self: EscrowLedger_Internal, toPlayer: Player, fromPlayer: Player): any
	const toTrade = self:_getTrade(toPlayer)
	const fromTrade = self:_getTrade(fromPlayer)
	if not toTrade or not fromTrade then
		return Promise.reject(
			`Profile or escrow table missing for CopyIncoming ({toPlayer.Name} ← {fromPlayer.Name})`
		)
	end
	const tradeId = toTrade.tradeId
	toTrade.incoming = fromTrade.outgoing
	toTrade.phase = 2

	const dataKey = self._dataKey
	return self:_commit(toPlayer, function(lastSaved)
		const t = lastSaved[dataKey]
		return t ~= nil and t.tradeId == tradeId and (t.phase or 0) >= 2
	end)
end

--[=[
	Phase 3: sets received = true and commits. Once this resolves for a player,
	that player is past the point of no return — their recovery will Claim.
]=]
function EscrowLedger.MarkReceived(self: EscrowLedger_Internal, player: Player): any
	const trade = self:_getTrade(player)
	if not trade then
		return Promise.reject(`Escrow table missing for MarkReceived ({player.Name})`)
	end
	const tradeId = trade.tradeId
	trade.received = true
	trade.phase = 3

	const dataKey = self._dataKey
	return self:_commit(player, function(lastSaved)
		const t = lastSaved[dataKey]
		return t ~= nil and t.tradeId == tradeId and t.received == true
	end)
end

--[=[
	Phase 4: calls FinalizeOffer with the player's Incoming, marks claimed, and
	clears the escrow fields — all in the same in-memory operation as the
	consumer's inventory mutation, so they persist atomically together.

	If FinalizeOffer throws, nothing is cleared and the returned promise
	rejects: the profile keeps received = true + incoming, so the next
	recovery attempt retries the claim.

	After the claim is confirmed persisted, the whole escrow table is removed
	with a best-effort second commit.
]=]
function EscrowLedger.Claim(self: EscrowLedger_Internal, player: Player, session: any?): any
	const profile = self:_getProfile(player)
	const trade = self:_getTrade(player)
	if not profile or not trade then
		return Promise.reject(`Profile or escrow table missing for Claim ({player.Name})`)
	end

	const finalizeOk, finalizeErr = pcall(function()
		self._callbacks.FinalizeOffer {
			Session = session,
			Player = player,
			Incoming = trade.incoming,
		}
	end)
	if not finalizeOk then
		return Promise.reject(`FinalizeOffer failed for {player.Name}: {finalizeErr}`)
	end

	trade.claimed = true
	trade.incoming = nil
	trade.outgoing = nil
	trade.received = nil
	trade.tradeId = nil
	trade.jobId = nil
	trade.executionStart = nil
	trade.phase = 4

	const dataKey = self._dataKey
	return self:_commit(player, function(lastSaved)
		const t = lastSaved[dataKey]
		return t == nil or t.claimed == true
	end):andThen(function()
		-- Claim is durable; drop the leftover table (best-effort — if this
		-- save never lands, recovery's claimed branch cleans it up).
		if profile.Data[dataKey] then
			profile.Data[dataKey] = nil
			return self:_commit(player)
		end
		return nil
	end)
end

--[=[
	Calls RollbackOffer with the player's Outgoing (if any) and removes the
	escrow table — in the same in-memory operation as the consumer's inventory
	restore, so they persist atomically together.

	If RollbackOffer throws, nothing is cleared and the returned promise
	rejects: the profile keeps its escrow state, so the next recovery attempt
	retries the rollback.
]=]
function EscrowLedger.Rollback(self: EscrowLedger_Internal, player: Player, reason: TradeStopReason, session: any?): any
	const profile = self:_getProfile(player)
	if not profile then
		return Promise.reject(`Profile for {player.Name} not loaded during Rollback`)
	end
	const trade = self:_getTrade(player)
	const outgoing = if trade then trade.outgoing else nil

	if outgoing ~= nil then
		const rollbackOk, rollbackErr = pcall(function()
			self._callbacks.RollbackOffer {
				Session = session,
				Player = player,
				Outgoing = outgoing,
				Reason = reason,
			}
		end)
		if not rollbackOk then
			return Promise.reject(`RollbackOffer failed for {player.Name}: {rollbackErr}`)
		end
	end

	profile.Data[self._dataKey] = nil
	const dataKey = self._dataKey
	return self:_commit(player, function(lastSaved)
		const t = lastSaved[dataKey]
		return t == nil or t.tradeId == nil
	end)
end

--[=[
	Removes the escrow table without moving any items (cleanup for stale or
	already-claimed leftovers).
]=]
function EscrowLedger.Clear(self: EscrowLedger_Internal, player: Player): any
	const profile = self:_getProfile(player)
	if not profile then
		return Promise.reject(`Profile for {player.Name} not loaded during Clear`)
	end
	if profile.Data[self._dataKey] == nil then
		return Promise.resolve()
	end
	profile.Data[self._dataKey] = nil
	const dataKey = self._dataKey
	return self:_commit(player, function(lastSaved)
		const t = lastSaved[dataKey]
		return t == nil or t.tradeId == nil
	end)
end

--[=[
	Returns the player's current escrow fields, or nil if absent/not loaded.
]=]
function EscrowLedger.Read(self: EscrowLedger_Internal, player: Player): { [string]: any }?
	return self:_getTrade(player)
end

return EscrowLedger
