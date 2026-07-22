--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeSession
	@server

	Manages a single active trade session between two players.
	Handles negotiation state, offer management, countdown, and execution.

	Key Features:
	- Offer management for both players (any offer change resets both locks)
	- Lock/unlock mechanism for confirming trades
	- Countdown system before execution
	- State transitions: Negotiating → Countdown → Processing → Completed/Stopped
	- Callback-driven item movement (validation, escrow, finalization)

	All escrow-field reads/writes and confirmed saves go through the EscrowLedger;
	this module only orchestrates the two players through the phases.
]=]

--// Services //--
const HttpService = game:GetService("HttpService")

--// Imports //--
const Packages = script.Parent.Parent
const Promise = require(Packages.Promise)
const Signal = require(Packages.Signal)
const Janitor = require(Packages.Janitor)

const Types = require(script.Parent.TradeTypes)
const TradeStore = require(script.Parent.TradeStore)
const EscrowLedger = require(script.Parent.EscrowLedger)

--// Types //--
type Janitor = Janitor.Janitor
type Promise<T...> = Promise.TypedPromise<T...>
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
export type TradeSession = Types.TradeSession
export type TradeSessionStatus = Types.TradeSessionStatus
export type TradeStopReason = Types.TradeStopReason
export type TradeOfferEntry = Types.TradeOfferEntry
export type TradeOfferPayload = Types.TradeOfferPayload
export type TradeSessionSnapshot = Types.TradeSessionSnapshot
export type TradeCallbacks = Types.TradeCallbacks
export type TradeOfferContext = Types.TradeOfferContext
export type TradeRollbackContext = Types.TradeRollbackContext
export type TradeFinalizeContext = Types.TradeFinalizeContext
export type TradeRecord = Types.TradeRecord

type TradeStore = TradeStore.TradeStore
type EscrowLedger = EscrowLedger.EscrowLedger

type TradeSession_Internal = TradeSession & {
	_janitor: Janitor,
	_sessionId: string,
	_player1: Player,
	_player2: Player,
	_status: TradeSessionStatus,
	_player1Offers: { TradeOfferEntry },
	_player2Offers: { TradeOfferEntry },
	_player1Locked: boolean,
	_player2Locked: boolean,
	_callbacks: TradeCallbacks,
	_ledger: EscrowLedger,
	_countdownSeconds: number,
	_countdownEndsAt: number?,
	_countdownThread: thread?,
	_startedAt: number,
	_processing: boolean,
	_tradeStore: TradeStore,
	_executionTimeoutSeconds: number,
	_executionTimeoutThread: thread?,
	_committedPlayers: { [Player]: boolean },
	_rollingBack: boolean,
	_destroyRequested: boolean,

	_getOffersForPlayer: (self: TradeSession_Internal, player: Player) -> { TradeOfferEntry },
	_getLockedStateForPlayer: (self: TradeSession_Internal, player: Player) -> boolean,
	_setLockedStateForPlayer: (self: TradeSession_Internal, player: Player, locked: boolean) -> (),
	_resetLocks: (self: TradeSession_Internal) -> (),
	_startCountdown: (self: TradeSession_Internal) -> (),
	_cancelCountdown: (self: TradeSession_Internal) -> (),
	_cancelExecutionTimeout: (self: TradeSession_Internal) -> (),
	_rollbackCommitted: (self: TradeSession_Internal, reason: TradeStopReason) -> (),
	_executeTradeAsync: (self: TradeSession_Internal) -> (),
	_stopSession: (self: TradeSession_Internal, reason: TradeStopReason) -> (),
	_finishDeferredDestroy: (self: TradeSession_Internal) -> (),
}

--// Constants //--
local DEFAULT_COUNTDOWN_SECONDS = 5
local DEFAULT_EXECUTION_TIMEOUT_SECONDS = 60
local COUNTDOWN_TICK_INTERVAL = 1 -- How often to fire CountdownTick signal (seconds)

--// Class //--
local TradeSession = {}
TradeSession.ClassName = "TradeSession"
TradeSession.__index = TradeSession

--[=[
	Creates a new TradeSession between two players.
	@param player1 Player -- First player in the trade
	@param player2 Player -- Second player in the trade
	@param callbacks TradeCallbacks -- Callbacks for validation and item movement
	@param ledger EscrowLedger -- Shared owner of the profile escrow fields
	@param tradeStore TradeStore -- DataStore wrapper for recording trade state
	@param countdownSeconds number? -- Countdown duration in seconds (default: 5)
	@param executionTimeoutSeconds number? -- Max seconds allowed for execution before rollback (default: 60)
	@return TradeSession
]=]
function TradeSession.new(
	player1: Player,
	player2: Player,
	callbacks: TradeCallbacks,
	ledger: EscrowLedger,
	tradeStore: TradeStore,
	countdownSeconds: number?,
	executionTimeoutSeconds: number?
): TradeSession
	local self = setmetatable({} :: any, TradeSession) :: TradeSession_Internal

	self._janitor = Janitor.new()
	self._sessionId = HttpService:GenerateGUID(false)
	self._player1 = player1
	self._player2 = player2
	self._status = "Negotiating"
	self._player1Offers = {}
	self._player2Offers = {}
	self._player1Locked = false
	self._player2Locked = false
	self._callbacks = callbacks
	self._ledger = ledger
	self._countdownSeconds = countdownSeconds or DEFAULT_COUNTDOWN_SECONDS
	self._countdownEndsAt = nil
	self._countdownThread = nil
	self._startedAt = os.time()
	self._processing = false
	self._tradeStore = tradeStore
	self._executionTimeoutSeconds = executionTimeoutSeconds or DEFAULT_EXECUTION_TIMEOUT_SECONDS
	self._executionTimeoutThread = nil
	self._committedPlayers = {}
	self._rollingBack = false
	self._destroyRequested = false

	-- Initialize signals
	self.OfferItemAdded = self._janitor:Add(Signal.new() :: any)
	self.OfferItemRemoved = self._janitor:Add(Signal.new() :: any)
	self.OfferLocked = self._janitor:Add(Signal.new() :: any)
	self.OfferUnlocked = self._janitor:Add(Signal.new() :: any)
	self.CountdownStarted = self._janitor:Add(Signal.new() :: any)
	self.CountdownTick = self._janitor:Add(Signal.new() :: any)
	self.CountdownCancelled = self._janitor:Add(Signal.new() :: any)
	self.CountdownCompleted = self._janitor:Add(Signal.new() :: any)
	self.Completed = self._janitor:Add(Signal.new() :: any)
	self.Stopped = self._janitor:Add(Signal.new() :: any)

	return (self :: any) :: TradeSession
end

--[=[
	Destroys the trade session and cleans up all resources.
	If execution is in flight, destruction is deferred until it finishes —
	tearing down signals under a running execution would corrupt the saga.
]=]
function TradeSession.Destroy(self: TradeSession_Internal)
	if self._processing then
		self._destroyRequested = true
		return
	end
	self:_cancelCountdown()
	self:_cancelExecutionTimeout()
	self._janitor:Destroy()
end

--// Private Methods //--

function TradeSession._finishDeferredDestroy(self: TradeSession_Internal)
	if self._destroyRequested then
		self._destroyRequested = false
		self:Destroy()
	end
end

function TradeSession._getOffersForPlayer(self: TradeSession_Internal, player: Player): { TradeOfferEntry }
	if player == self._player1 then
		return self._player1Offers
	elseif player == self._player2 then
		return self._player2Offers
	end
	error(`Player {player.Name} is not part of this trade session`)
end

function TradeSession._getLockedStateForPlayer(self: TradeSession_Internal, player: Player): boolean
	if player == self._player1 then
		return self._player1Locked
	elseif player == self._player2 then
		return self._player2Locked
	end
	error(`Player {player.Name} is not part of this trade session`)
end

function TradeSession._setLockedStateForPlayer(self: TradeSession_Internal, player: Player, locked: boolean)
	if player == self._player1 then
		self._player1Locked = locked
	elseif player == self._player2 then
		self._player2Locked = locked
	else
		error(`Player {player.Name} is not part of this trade session`)
	end
end

-- Any offer mutation invalidates both players' confirmations. Prevents the
-- last-second-switch scam where one player edits the offer after the other locked.
function TradeSession._resetLocks(self: TradeSession_Internal)
	for _, player in { self._player1, self._player2 } do
		if self:_getLockedStateForPlayer(player) then
			self:_setLockedStateForPlayer(player, false)
			self.OfferUnlocked:Fire(player)
		end
	end
end

function TradeSession._startCountdown(self: TradeSession_Internal)
	if self._countdownThread then
		return -- Already counting down
	end

	self._countdownEndsAt = os.time() + self._countdownSeconds
	self.CountdownStarted:Fire(self._countdownEndsAt)

	self._countdownThread = task.spawn(function()
		local remaining = self._countdownSeconds
		while remaining > 0 do
			task.wait(COUNTDOWN_TICK_INTERVAL)
			remaining = math.max(0, self._countdownEndsAt :: number - os.time())
			if remaining > 0 then
				self.CountdownTick:Fire(remaining)
			end
		end

		-- Countdown completed
		self._countdownThread = nil
		self._countdownEndsAt = nil
		self.CountdownCompleted:Fire()

		-- Start trade execution
		self:_executeTradeAsync()
	end)
end

function TradeSession._cancelCountdown(self: TradeSession_Internal)
	if self._countdownThread then
		task.cancel(self._countdownThread)
		self._countdownThread = nil
		self._countdownEndsAt = nil
		self.CountdownCancelled:Fire()
	end
end

function TradeSession._cancelExecutionTimeout(self: TradeSession_Internal)
	if self._executionTimeoutThread then
		task.cancel(self._executionTimeoutThread)
		self._executionTimeoutThread = nil
	end
end

-- Rolls back all players who successfully committed their outgoing items.
-- Cancels the execution timeout, rolls each committed player back through the
-- ledger, finalizes the DataStore record as rolledback, and stops the session.
function TradeSession._rollbackCommitted(self: TradeSession_Internal, reason: TradeStopReason)
	if self._rollingBack then
		return
	end
	self._rollingBack = true

	self:_cancelExecutionTimeout()

	for player in self._committedPlayers do
		const ok, err = (self._ledger:Rollback(player, reason, self) :: any):await()
		if not ok then
			warn(
				`[TradeSession] Rollback failed for {player.Name}: {err}.`
					.. ` Escrow state kept; recovery will retry on rejoin.`
			)
		end
	end
	table.clear(self._committedPlayers)

	self._tradeStore:FinalizeAsync(self._sessionId, "rolledback")

	self:_stopSession(reason)
end

function TradeSession._executeTradeAsync(self: TradeSession_Internal)
	if self._processing or (self._status ~= "Negotiating" and self._status ~= "Countdown") then
		return
	end

	self._processing = true
	self._status = "Processing"

	-- =========================================================================
	-- Pre-flight: re-validate all offers before any mutations.
	-- =========================================================================
	const preFlight: { { player: Player, offers: { TradeOfferEntry } } } = {
		{ player = self._player1, offers = self._player1Offers },
		{ player = self._player2, offers = self._player2Offers },
	}
	for _, pair in preFlight do
		for _, offer in pair.offers do
			const ctx: TradeOfferContext = {
				Session = self :: any,
				Player = pair.player,
				IdentifyingData = offer.IdentifierData,
			}
			const valid, errMsg = self._callbacks.ValidateOffer(ctx)
			if not valid then
				self._processing = false
				self._status = "Negotiating"
				self:_stopSession("ProcessingFailed")
				warn(
					`[TradeSession] Pre-flight validation failed for {pair.player.Name}:`
						.. ` offer={offer.OfferId} reason={errMsg}`
				)
				self:_finishDeferredDestroy()
				return
			end
		end
	end

	const tradeId = self._sessionId
	const executionStart = os.time()
	const jobId = game.JobId

	-- =========================================================================
	-- Record write (blocking). The TradeRecord is recovery's cross-player
	-- source of truth; nothing may be escrowed until it exists. Aborting here
	-- is free — no mutations have happened yet.
	-- =========================================================================
	const _, writeSucceeded = (self._tradeStore:WriteAsync {
		tradeId = tradeId,
		jobId = jobId,
		player1Id = self._player1.UserId,
		player2Id = self._player2.UserId,
		player1Phase = 0,
		player2Phase = 0,
		executionStart = executionStart,
		status = "active",
		completedAt = nil,
		expiresAt = nil,
	} :: any):await()

	if not writeSucceeded then
		warn(`[TradeSession] Could not write TradeRecord for {tradeId}. Aborting before escrow.`)
		self._processing = false
		self:_stopSession("ProcessingFailed")
		self:_finishDeferredDestroy()
		return
	end

	-- Start the execution timeout. If the phases don't complete before the
	-- point of no return in time, rollback all committed players.
	self._executionTimeoutThread = task.delay(self._executionTimeoutSeconds, function()
		if self._status == "Processing" :: any then
			warn(
				`[TradeSession] Execution timeout after {self._executionTimeoutSeconds}s`
					.. ` for trade {tradeId}. Rolling back.`
			)
			self:_rollbackCommitted("TimedOut")
		end
	end)

	-- Bail-out helper: true if a concurrent rollback (timeout) or stop landed
	-- while we were yielding on a save.
	const function interrupted(): boolean
		return self._rollingBack or self._status ~= ("Processing" :: any)
	end

	-- =========================================================================
	-- Phase 1: Commit Outgoing (concurrent)
	-- Both players' commits run simultaneously. Each player's offered items are
	-- moved to escrow by the consumer (MoveOfferToEscrow writes into ctx.Trade),
	-- then the ledger stamps the trade metadata and confirms the save.
	-- =========================================================================
	const function commitPlayer(player: Player, offers: { TradeOfferEntry }): Promise<()>
		return Promise.new(function(resolve, reject)
			const tradeOk, tradeOrErr = pcall(function()
				return self._ledger:EnsureTrade(player)
			end)
			if not tradeOk then
				reject(tradeOrErr)
				return
			end

			-- Escrow each item. This is the consumer's atomic inventory mutation.
			local escrowOk, escrowErr = pcall(function()
				for _, offer in offers do
					const ctx: TradeOfferContext = {
						Session = self :: any,
						Player = player,
						IdentifyingData = offer.IdentifierData,
						Trade = tradeOrErr,
					}
					self._callbacks.MoveOfferToEscrow(ctx)
				end
			end)
			if not escrowOk then
				-- A partial multi-item escrow may have already moved items in
				-- memory. Restore them (Rollback with no outgoing is a no-op
				-- beyond clearing the escrow table).
				const rbOk, rbErr = (self._ledger:Rollback(player, "ProcessingFailed", self) :: any):await()
				if not rbOk then
					warn(`[TradeSession] Post-escrow-failure rollback failed for {player.Name}: {rbErr}`)
				end
				reject(escrowErr)
				return
			end

			const commitOk, commitErr = (self._ledger:BeginCommit(player, {
				tradeId = tradeId,
				jobId = jobId,
				executionStart = executionStart,
			}) :: any):await()
			if not commitOk then
				-- The escrow mutation is live in memory even though the commit
				-- didn't confirm. Restore it now so a later autosave can't
				-- persist a half-escrowed profile.
				const rbOk, rbErr = (self._ledger:Rollback(player, "ProcessingFailed", self) :: any):await()
				if not rbOk then
					warn(`[TradeSession] Post-commit-failure rollback failed for {player.Name}: {rbErr}`)
				end
				reject(commitErr)
				return
			end

			-- After the yield: check whether rollback was triggered while we were
			-- saving. If so, immediately roll back this player (their escrow
			-- succeeded and is persisted) and bail.
			if self._rollingBack then
				const rbOk, rbErr = (self._ledger:Rollback(player, "ProcessingFailed", self) :: any):await()
				if not rbOk then
					warn(`[TradeSession] Mid-commit rollback failed for {player.Name}: {rbErr}`)
				end
				reject("Trade rolled back during commit")
				return
			end

			self._committedPlayers[player] = true
			self._tradeStore:UpdatePhaseAsync(tradeId, if player == self._player1 then 1 else 2, 1)
			resolve()
		end)
	end

	const phase1Ok, phase1Err = Promise.all({
		commitPlayer(self._player1, self._player1Offers) :: any,
		commitPlayer(self._player2, self._player2Offers) :: any,
	}):await()

	if not phase1Ok then
		warn(`[TradeSession] Phase 1 failed: {phase1Err}`)
		self:_rollbackCommitted("ProcessingFailed")
		self:_finishDeferredDestroy()
		return
	end
	if interrupted() then
		self:_finishDeferredDestroy()
		return
	end

	-- =========================================================================
	-- Phase 2: Copy Incoming (sequential)
	-- The ledger copies each player's outgoing blob into the other player's
	-- incoming field and confirms the save. Both profiles are loaded on this
	-- server at this point.
	-- =========================================================================
	do
		const p2CopyOk, p2CopyErr = (self._ledger:CopyIncoming(self._player2, self._player1) :: any):await()
		if not p2CopyOk then
			warn(`[TradeSession] Phase 2: P2 copy failed: {p2CopyErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			self:_finishDeferredDestroy()
			return
		end
		self._tradeStore:UpdatePhaseAsync(tradeId, 2, 2)
		if interrupted() then
			self:_finishDeferredDestroy()
			return
		end

		const p1CopyOk, p1CopyErr = (self._ledger:CopyIncoming(self._player1, self._player2) :: any):await()
		if not p1CopyOk then
			warn(`[TradeSession] Phase 2: P1 copy failed: {p1CopyErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			self:_finishDeferredDestroy()
			return
		end
		self._tradeStore:UpdatePhaseAsync(tradeId, 1, 2)
		if interrupted() then
			self:_finishDeferredDestroy()
			return
		end
	end

	-- =========================================================================
	-- Phase 3: Mark Received (sequential)
	-- The point of no return is crossed when BOTH of these are durable:
	--   1. P1's received = true is persisted in P1's profile.
	--   2. The TradeRecord shows P1 at phase 3 (this update is awaited).
	-- After that, rollback is no longer safe: recovery claims for any player
	-- whose own received is set OR whose partner's record phase is >= 3.
	-- =========================================================================
	do
		const p1RecvOk, p1RecvErr = (self._ledger:MarkReceived(self._player1) :: any):await()
		if not p1RecvOk then
			warn(`[TradeSession] Phase 3: P1 mark-received failed: {p1RecvErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			self:_finishDeferredDestroy()
			return
		end
		if interrupted() then
			self:_finishDeferredDestroy()
			return
		end

		-- Blocking: the record must witness P1's phase 3 before we give up the
		-- ability to roll back — it is what tells P2's recovery to complete
		-- rather than refund if this server dies right after this point.
		const _, p1PhaseRecorded = (self._tradeStore:UpdatePhaseAsync(tradeId, 1, 3) :: any):await()
		if not p1PhaseRecorded then
			warn(`[TradeSession] Phase 3: could not record P1 phase 3. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			self:_finishDeferredDestroy()
			return
		end
		if interrupted() then
			self:_finishDeferredDestroy()
			return
		end

		-- Past the point of no return. Rollback is no longer valid.
		self:_cancelExecutionTimeout()

		const p2RecvOk, p2RecvErr = (self._ledger:MarkReceived(self._player2) :: any):await()
		if not p2RecvOk then
			warn(
				`[TradeSession] Phase 3: P2 mark-received failed: {p2RecvErr}.`
					.. ` Past the point of no return; recovery will finalize both players on rejoin.`
			)
			self:_stopSession("ProcessingFailed")
			self:_finishDeferredDestroy()
			return
		end
		self._tradeStore:UpdatePhaseAsync(tradeId, 2, 3)
	end

	-- =========================================================================
	-- Phase 4: Claim (concurrent)
	-- The ledger finalizes each receiving player: FinalizeOffer + claimed=true
	-- + field clear persist atomically with the consumer's inventory add. A
	-- failed claim keeps received + incoming intact, so recovery retries it.
	-- =========================================================================
	const claimResults: { any } = Promise.allSettled({
		self._ledger:Claim(self._player1, self) :: any,
		self._ledger:Claim(self._player2, self) :: any,
	}):expect()
	for i, status in claimResults do
		if status ~= "Resolved" then
			const player = if i == 1 then self._player1 else self._player2
			warn(`[TradeSession] Phase 4: claim did not complete for {player.Name}. Recovery will retry on rejoin.`)
		end
	end

	const _, _ = (self._tradeStore:FinalizeWithPhasesAsync(tradeId, 4, 4, "completed") :: any):await()

	self._status = "Completed"
	self._processing = false
	self.Completed:Fire(self._player1, self._player2)
	self:_finishDeferredDestroy()
end

function TradeSession._stopSession(self: TradeSession_Internal, reason: TradeStopReason)
	if self._status == "Stopped" or self._status == "Completed" then
		return
	end

	self:_cancelCountdown()
	self._status = "Stopped"
	self._processing = false
	self.Stopped:Fire(reason)
end

--// Public Methods //--

--[=[
	Adds an offer item to the player's side of the trade.
	Validates the offer before adding it to the session.
	Resets both players' locks — any offer change invalidates confirmations.
	@param player Player -- The player adding the offer (must be part of this session)
	@param identifierData TradeOfferPayload -- Consumer-owned data identifying the item
	@return TradeOfferEntry -- The created offer entry with a unique OfferId
]=]
function TradeSession.AddOfferItem(
	self: TradeSession_Internal,
	player: Player,
	identifierData: TradeOfferPayload
): TradeOfferEntry
	assert(self._status == "Negotiating", "Cannot add items while processing, stopped, or completed")
	assert(player == self._player1 or player == self._player2, "Player is not part of this trade session")

	-- Validate offer
	const context: TradeOfferContext = {
		Session = self,
		Player = player,
		IdentifyingData = identifierData,
	}
	const valid, errorMsg = self._callbacks.ValidateOffer(context)
	assert(valid, errorMsg or "Offer validation failed")

	-- Create offer entry
	const offer: TradeOfferEntry = {
		OfferId = HttpService:GenerateGUID(false),
		Owner = player,
		IdentifierData = identifierData,
	}

	-- Add to appropriate list
	const offers = self:_getOffersForPlayer(player)
	table.insert(offers, offer)

	self:_resetLocks()
	self.OfferItemAdded:Fire(player, offer)
	return offer
end

--[=[
	Removes an offer item from the player's side of the trade.
	Resets both players' locks — any offer change invalidates confirmations.
	@param player Player -- The player removing the offer
	@param offerId string -- The unique ID of the offer to remove
]=]
function TradeSession.RemoveOfferItem(self: TradeSession_Internal, player: Player, offerId: string)
	assert(self._status == "Negotiating", "Cannot remove items while processing, stopped, or completed")
	assert(player == self._player1 or player == self._player2, "Player is not part of this trade session")

	const offers = self:_getOffersForPlayer(player)
	for i, offer in offers do
		if offer.OfferId == offerId then
			table.remove(offers, i)
			self:_resetLocks()
			self.OfferItemRemoved:Fire(player, offer)
			return
		end
	end

	error(`Offer with id {offerId} not found for player {player.Name}`)
end

--[=[
	Locks the player's current offer, signaling readiness to trade.
	When both players lock their offers, the countdown automatically starts.
	@param player Player -- The player locking their offers
]=]
function TradeSession.LockOffers(self: TradeSession_Internal, player: Player)
	assert(
		self._status == "Negotiating" or self._status == "Countdown",
		"Cannot lock offers while processing, stopped, or completed"
	)
	assert(player == self._player1 or player == self._player2, "Player is not part of this trade session")

	const alreadyLocked = self:_getLockedStateForPlayer(player)
	if alreadyLocked then
		return -- Already locked
	end

	self:_setLockedStateForPlayer(player, true)
	self.OfferLocked:Fire(player)

	-- Check if both are now locked
	if self._player1Locked and self._player2Locked then
		self._status = "Countdown"
		self:_startCountdown()
	end
end

--[=[
	Unlocks the player's offer, returning the session to negotiation.
	Automatically cancels the countdown if it's currently active.
	@param player Player -- The player unlocking their offers
]=]
function TradeSession.UnlockOffers(self: TradeSession_Internal, player: Player)
	assert(
		self._status == "Negotiating" or self._status == "Countdown",
		"Cannot unlock offers while processing, stopped, or completed"
	)
	assert(player == self._player1 or player == self._player2, "Player is not part of this trade session")

	const wasLocked = self:_getLockedStateForPlayer(player)
	if not wasLocked then
		return -- Already unlocked
	end

	self:_setLockedStateForPlayer(player, false)
	self:_cancelCountdown()
	self._status = "Negotiating"
	self.OfferUnlocked:Fire(player)
end

--[=[
	Returns the session ID.
	@return string
]=]
function TradeSession.GetSessionId(self: TradeSession_Internal): string
	return self._sessionId
end

--[=[
	Returns all offers for the specified player.
	@param player Player -- The player whose offers to retrieve
	@return { TradeOfferEntry } -- Array of offer entries
]=]
function TradeSession.GetOffers(self: TradeSession_Internal, player: Player): { TradeOfferEntry }
	return self:_getOffersForPlayer(player)
end

--[=[
	Returns the other player in the trade session.
	@param player Player -- One of the players in the session
	@return Player -- The other player
]=]
function TradeSession.GetOtherPlayer(self: TradeSession_Internal, player: Player): Player
	if player == self._player1 then
		return self._player2
	elseif player == self._player2 then
		return self._player1
	end
	error(`Player {player.Name} is not part of this trade session`)
end

--[=[
	Returns both players in the trade session.
	@return (Player, Player)
]=]
function TradeSession.GetPlayers(self: TradeSession_Internal): (Player, Player)
	return self._player1, self._player2
end

--[=[
	Returns the current session status.
	@return TradeSessionStatus
]=]
function TradeSession.GetStatus(self: TradeSession_Internal): TradeSessionStatus
	return self._status
end

--[=[
	Returns a snapshot of the current session state.
	@return TradeSessionSnapshot
]=]
function TradeSession.GetSnapshot(self: TradeSession_Internal): TradeSessionSnapshot
	return {
		SessionId = self._sessionId,
		Player1 = self._player1,
		Player2 = self._player2,
		Status = self._status,
		CountdownEndsAt = self._countdownEndsAt,
		Player1Locked = self._player1Locked,
		Player2Locked = self._player2Locked,
		Player1Offers = table.clone(self._player1Offers),
		Player2Offers = table.clone(self._player2Offers),
		StartedAt = self._startedAt,
		Processing = self._processing,
	}
end

--[=[
	Returns whether the player's offers are locked.
	@param player Player -- The player to check
	@return boolean -- True if the player has locked their offers
]=]
function TradeSession.IsLocked(self: TradeSession_Internal, player: Player): boolean
	return self:_getLockedStateForPlayer(player)
end

--[=[
	Returns whether the session is currently processing.
	@return boolean
]=]
function TradeSession.IsProcessing(self: TradeSession_Internal): boolean
	return self._processing
end

--[=[
	Returns whether the session is stopped.
	@return boolean
]=]
function TradeSession.IsStopped(self: TradeSession_Internal): boolean
	return self._status == "Stopped"
end

--[=[
	Returns whether the session is completed.
	@return boolean
]=]
function TradeSession.IsCompleted(self: TradeSession_Internal): boolean
	return self._status == "Completed"
end

--[=[
	Returns whether the countdown is currently active.
	@return boolean
]=]
function TradeSession.IsCountdownActive(self: TradeSession_Internal): boolean
	return self._countdownThread ~= nil
end

return TradeSession
