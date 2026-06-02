--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeSession
	@server

	Manages a single active trade session between two players.
	Handles negotiation state, offer management, countdown, and execution.

	Key Features:
	- Offer management for both players
	- Lock/unlock mechanism for confirming trades
	- Countdown system before execution
	- State transitions: Negotiating → Countdown → Processing → Completed/Stopped
	- Callback-driven item movement (validation, escrow, finalization)
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

	_getOffersForPlayer: (self: TradeSession_Internal, player: Player) -> { TradeOfferEntry },
	_getLockedStateForPlayer: (self: TradeSession_Internal, player: Player) -> boolean,
	_setLockedStateForPlayer: (self: TradeSession_Internal, player: Player, locked: boolean) -> (),
	_startCountdown: (self: TradeSession_Internal) -> (),
	_cancelCountdown: (self: TradeSession_Internal) -> (),
	_cancelExecutionTimeout: (self: TradeSession_Internal) -> (),
	_waitForSave: (self: TradeSession_Internal, player: Player) -> Promise<()>,
	_rollbackSinglePlayer: (self: TradeSession_Internal, player: Player, reason: TradeStopReason) -> (),
	_rollbackCommitted: (self: TradeSession_Internal, reason: TradeStopReason) -> (),
	_executeTradeAsync: (self: TradeSession_Internal) -> (),
	_stopSession: (self: TradeSession_Internal, reason: TradeStopReason) -> (),
}

--// Constants //--
local DEFAULT_COUNTDOWN_SECONDS = 5
local DEFAULT_EXECUTION_TIMEOUT_SECONDS = 60
local COUNTDOWN_TICK_INTERVAL = 1 -- How often to fire CountdownTick signal (seconds)
local TRADE_KEY = "ProfileTradeManager_ActiveTradeSession"

--// Class //--
local TradeSession = {}
TradeSession.ClassName = "TradeSession"
TradeSession.__index = TradeSession

--[=[
	Creates a new TradeSession between two players.
	@param player1 Player -- First player in the trade
	@param player2 Player -- Second player in the trade
	@param callbacks TradeCallbacks -- Callbacks for validation and item movement
	@param tradeStore TradeStore -- DataStore wrapper for recording trade state
	@param countdownSeconds number? -- Countdown duration in seconds (default: 5)
	@param executionTimeoutSeconds number? -- Max seconds allowed for execution before rollback (default: 60)
	@return TradeSession
]=]
function TradeSession.new(
	player1: Player,
	player2: Player,
	callbacks: TradeCallbacks,
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
]=]
function TradeSession.Destroy(self: TradeSession_Internal)
	self:_cancelCountdown()
	self._janitor:Destroy()
end

--// Private Methods //--

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

-- Waits for the player's profile to be saved. The connection is one-shot and
-- cleans itself up after firing. Cancellation disconnects the callback.
function TradeSession._waitForSave(self: TradeSession_Internal, player: Player): Promise<()>
	return Promise.new(function(resolve, _, onCancel)
		local connection: any = nil
		connection = self._callbacks.RegisterSaveCallback(player, function()
			if connection then
				connection:Disconnect()
				connection = nil
			end
			resolve()
		end)
		onCancel(function()
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end)
	end)
end

-- Rolls back a single player who has already committed their outgoing items.
-- Calls RollbackOffer, clears their trade fields, and triggers a save.
function TradeSession._rollbackSinglePlayer(self: TradeSession_Internal, player: Player, reason: TradeStopReason)
	const profile = self._callbacks.GetProfile(player)
	const outgoing = if profile and profile.Data[TRADE_KEY] then profile.Data[TRADE_KEY].outgoing else nil
	pcall(function()
		const ctx: TradeRollbackContext = {
			Session = self :: any,
			Player = player,
			Outgoing = outgoing,
			Reason = reason,
		}
		self._callbacks.RollbackOffer(ctx)
	end)
	if profile and profile.Data[TRADE_KEY] then
		profile.Data[TRADE_KEY].outgoing = nil
		profile.Data[TRADE_KEY].incoming = nil
		profile.Data[TRADE_KEY].received = nil
		profile.Data[TRADE_KEY].claimed = nil
		profile.Data[TRADE_KEY].tradeId = nil
		profile.Data[TRADE_KEY].jobId = nil
		profile.Data[TRADE_KEY].executionStart = nil
	end
	self._callbacks.TriggerSave(player)
end

-- Rolls back all players who successfully committed their outgoing items.
-- Cancels the execution timeout, calls RollbackOffer for each committed player,
-- finalizes the DataStore record, and fires the Stopped signal.
function TradeSession._rollbackCommitted(self: TradeSession_Internal, reason: TradeStopReason)
	if self._rollingBack then
		return
	end
	self._rollingBack = true

	self:_cancelExecutionTimeout()

	for player in self._committedPlayers do
		self:_rollbackSinglePlayer(player, reason)
	end
	table.clear(self._committedPlayers)

	task.spawn(function()
		self._tradeStore:FinalizeAsync(self._sessionId, "rolledback")
	end)

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
				return
			end
		end
	end

	const tradeId = self._sessionId
	const executionStart = os.time()
	const jobId = game.JobId

	-- Write the initial TradeRecord to the DataStore (fire-and-forget; non-fatal if it fails).
	task.spawn(function()
		self._tradeStore:WriteAsync {
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
		}
	end)

	-- Start the execution timeout. If phases 1-3 don't complete in time,
	-- rollback all committed players.
	self._executionTimeoutThread = task.delay(self._executionTimeoutSeconds, function()
		if self._status == "Processing" :: any then
			warn(
				`[TradeSession] Execution timeout after {self._executionTimeoutSeconds}s`
					.. ` for trade {tradeId}. Rolling back.`
			)
			self:_rollbackCommitted("TimedOut")
		end
	end)

	-- =========================================================================
	-- Phase 1: Commit Outgoing (concurrent)
	-- Both players' commits run simultaneously. Each player atomically removes
	-- their offered items from inventory (via MoveOfferToEscrow) and the package
	-- writes trade metadata to the profile, then forces a save.
	-- A _rollingBack guard prevents double-rollback if the timeout fires while
	-- a commit coroutine is still in-flight after a yield.
	-- =========================================================================
	const function commitPlayer(player: Player, offers: { TradeOfferEntry }, playerIndex: number): Promise<()>
		return Promise.new(function(resolve, reject)
			-- Escrow each item. This is the consumer's atomic inventory mutation.
			local escrowOk, escrowErr = pcall(function()
				for _, offer in offers do
					const ctx: TradeOfferContext = {
						Session = self :: any,
						Player = player,
						IdentifyingData = offer.IdentifierData,
					}
					self._callbacks.MoveOfferToEscrow(ctx)
				end
			end)
			if not escrowOk then
				reject(escrowErr)
				return
			end

			-- Write trade metadata to the profile so recovery can find this trade.
			const profile = self._callbacks.GetProfile(player)
			if not profile then
				reject(`Profile for {player.Name} not found after escrow`)
				return
			end
			if not profile.Data[TRADE_KEY] then
				profile.Data[TRADE_KEY] = {}
			end
			profile.Data[TRADE_KEY].tradeId = tradeId
			profile.Data[TRADE_KEY].jobId = jobId
			profile.Data[TRADE_KEY].executionStart = executionStart

			-- Force save and wait. TriggerSave is called before RegisterSaveCallback
			-- so the queued save will include all data written above.
			self._callbacks.TriggerSave(player)
			const saveOk, saveErr = (self:_waitForSave(player) :: any):await()
			if not saveOk then
				reject(saveErr)
				return
			end

			-- After the yield: check whether rollback was triggered while we were saving.
			-- If so, immediately roll back this player (their escrow succeeded) and bail.
			if self._rollingBack then
				self:_rollbackSinglePlayer(player, "ProcessingFailed")
				reject("Trade rolled back during commit")
				return
			end

			self._committedPlayers[player] = true
			task.spawn(function()
				self._tradeStore:UpdatePhaseAsync(tradeId, playerIndex, 1)
			end)
			resolve()
		end)
	end

	const phase1Ok, phase1Err = Promise.all({
		commitPlayer(self._player1, self._player1Offers, 1) :: any,
		commitPlayer(self._player2, self._player2Offers, 2) :: any,
	}):await()

	if not phase1Ok then
		warn(`[TradeSession] Phase 1 failed: {phase1Err}`)
		self:_rollbackCommitted("ProcessingFailed")
		return
	end

	-- =========================================================================
	-- Phase 2: Copy Incoming (sequential)
	-- The package reads each player's outgoing blob from their loaded profile
	-- and writes it to the other player's incoming field, then forces a save.
	-- Both profiles are guaranteed to be on this server at this point.
	-- =========================================================================
	do
		const p1Profile = self._callbacks.GetProfile(self._player1)
		const p2Profile = self._callbacks.GetProfile(self._player2)
		if not p1Profile or not p2Profile then
			warn(`[TradeSession] Phase 2: profile missing. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			return
		end

		-- Capture both outgoing values before writing incoming (same profile objects).
		const p1Outgoing = p1Profile.Data[TRADE_KEY] and p1Profile.Data[TRADE_KEY].outgoing
		const p2Outgoing = p2Profile.Data[TRADE_KEY] and p2Profile.Data[TRADE_KEY].outgoing

		-- P2 receives P1's items
		if not p2Profile.Data[TRADE_KEY] then
			p2Profile.Data[TRADE_KEY] = {}
		end
		p2Profile.Data[TRADE_KEY].incoming = p1Outgoing
		self._callbacks.TriggerSave(self._player2)
		const p2CopyOk, p2CopyErr = (self:_waitForSave(self._player2) :: any):await()
		if not p2CopyOk then
			warn(`[TradeSession] Phase 2: P2 save failed: {p2CopyErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			return
		end
		task.spawn(function()
			self._tradeStore:UpdatePhaseAsync(tradeId, 2, 2)
		end)

		-- P1 receives P2's items
		if not p1Profile.Data[TRADE_KEY] then
			p1Profile.Data[TRADE_KEY] = {}
		end
		p1Profile.Data[TRADE_KEY].incoming = p2Outgoing
		self._callbacks.TriggerSave(self._player1)
		const p1CopyOk, p1CopyErr = (self:_waitForSave(self._player1) :: any):await()
		if not p1CopyOk then
			warn(`[TradeSession] Phase 2: P1 save failed: {p1CopyErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			return
		end
		task.spawn(function()
			self._tradeStore:UpdatePhaseAsync(tradeId, 1, 2)
		end)
	end

	-- =========================================================================
	-- Phase 3: Mark Received (sequential)
	-- Both players' profiles have received = true, confirming that incoming data
	-- is saved. The point of no return is when P1's received = true is persisted.
	-- After that, P1 cannot be safely rolled back — recovery handles both players
	-- on rejoin if P2's save fails.
	-- =========================================================================
	do
		const p1Profile = self._callbacks.GetProfile(self._player1)
		const p2Profile = self._callbacks.GetProfile(self._player2)
		if not p1Profile or not p2Profile then
			warn(`[TradeSession] Phase 3: profile missing. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			return
		end

		p1Profile.Data[TRADE_KEY].received = true
		self._callbacks.TriggerSave(self._player1)
		const p1RecvOk, p1RecvErr = (self:_waitForSave(self._player1) :: any):await()
		if not p1RecvOk then
			warn(`[TradeSession] Phase 3: P1 save failed: {p1RecvErr}. Rolling back.`)
			self:_rollbackCommitted("ProcessingFailed")
			return
		end
		self._tradeStore:UpdatePhaseAsync(tradeId, 1, 3)

		-- P1 is past the point of no return. Cancel the timeout — rollback is no
		-- longer safe. If P2's save fails, recovery will finalize both on rejoin.
		self:_cancelExecutionTimeout()

		p2Profile.Data[TRADE_KEY].received = true
		self._callbacks.TriggerSave(self._player2)
		const p2RecvOk, p2RecvErr = (self:_waitForSave(self._player2) :: any):await()
		if not p2RecvOk then
			warn(
				`[TradeSession] Phase 3: P2 save failed: {p2RecvErr}.`
					.. ` P1 is past the point of no return; recovery will finalize both players on rejoin.`
			)
			self:_stopSession("ProcessingFailed")
			return
		end
		self._tradeStore:UpdatePhaseAsync(tradeId, 2, 3)
	end

	-- =========================================================================
	-- Phase 4: Claim (sequential)
	-- Both players have received = true. Cancel the execution timeout if it was
	-- not already cancelled at the end of Phase 3. The package calls FinalizeOffer
	-- for each receiving player, then clears all trade fields. If FinalizeOffer
	-- throws, claimed = true stays in the profile so recovery can retry on rejoin.
	-- =========================================================================
	self:_cancelExecutionTimeout()

	const function finalizePlayer(player: Player)
		const profile = self._callbacks.GetProfile(player)
		if not profile then
			warn(`[TradeSession] Phase 4: profile for {player.Name} missing. Will be claimed on rejoin.`)
			return Promise.reject()
		end

		const incoming = profile.Data[TRADE_KEY] and profile.Data[TRADE_KEY].incoming
		const finalizeOk, finalizeErr = pcall(function()
			const ctx: TradeFinalizeContext = {
				Session = self :: any,
				Player = player,
				Incoming = incoming,
			}
			self._callbacks.FinalizeOffer(ctx)
		end)
		if not finalizeOk then
			warn(
				`[TradeSession] Phase 4: FinalizeOffer for {player.Name} failed: {finalizeErr}.`
					.. ` Item will be claimed via recovery on rejoin.`
			)
		end

		-- Always mark claimed and clear fields so recovery knows where we are.
		profile.Data[TRADE_KEY].claimed = true
		profile.Data[TRADE_KEY].incoming = nil
		profile.Data[TRADE_KEY].outgoing = nil
		profile.Data[TRADE_KEY].received = nil
		profile.Data[TRADE_KEY].tradeId = nil
		profile.Data[TRADE_KEY].jobId = nil
		profile.Data[TRADE_KEY].executionStart = nil
		self._callbacks.TriggerSave(player)
		return self:_waitForSave(player):andThen(function()
			-- Once the save confirms, fully clear the Trade table if everything went well.
			if finalizeOk then
				profile.Data[TRADE_KEY] = nil
			end
		end)
	end

	Promise.allSettled({
		finalizePlayer(self._player1),
		finalizePlayer(self._player2),
	})
		:andThen(function()
			-- Update DataStore phases and finalize the record regardless of per-player errors.
			self._tradeStore:FinalizeWithPhasesAsync(tradeId, 4, 4, "completed")
		end)
		:await()

	self._status = "Completed"
	self._processing = false
	self.Completed:Fire(self._player1, self._player2)
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

	self.OfferItemAdded:Fire(player, offer)
	return offer
end

--[=[
	Removes an offer item from the player's side of the trade.
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
