--!strict
-- TradeManager Type Definitions
-- Defines all types used across the TradeManager system

export type TradeStopReason =
	"Denied"
	| "Cancelled"
	| "CountdownCancelled"
	| "PlayerLeft"
	| "PlayerUnloaded"
	| "ProcessingFailed"
	| "TimedOut"
	| "RecoveredRollback"
	| "Completed"

export type TradeSessionStatus = "Negotiating" | "Countdown" | "Processing" | "Completed" | "Stopped"

--- Phase of trade execution for a single player.
--- 0 = none, 1 = committed, 2 = copied, 3 = received, 4 = claimed.
export type TradePhase = number

export type TradeRequest = {
	RequestId: string,
	Prompter: Player,
	Receiver: Player,
	CreatedAt: number,
	ExpiresAt: number?,
}

export type TradeOfferEntry = {
	OfferId: string,
	Owner: Player,
	IdentifierData: any,
}

export type TradeSessionSnapshot = {
	SessionId: string,
	Player1: Player,
	Player2: Player,
	Status: TradeSessionStatus,
	CountdownEndsAt: number?,
	Player1Locked: boolean,
	Player2Locked: boolean,
	Player1Offers: { TradeOfferEntry },
	Player2Offers: { TradeOfferEntry },
	StartedAt: number,
	Processing: boolean,
}

export type TradeOfferPayload = any

export type TradeOfferContext = {
	Session: any, -- TradeSession (forward reference)
	Player: Player,
	IdentifyingData: TradeOfferPayload,
	--- The live escrow table for this player's trade (profile.Data[TradeDataKey]).
	--- Non-nil during MoveOfferToEscrow; accumulate offered items into Trade.outgoing.
	--- Nil during ValidateOffer.
	Trade: { [string]: any }?,
}

--[=[
	Context passed to FinalizeOffer.
	Player is the receiving player — items go to them.
	Incoming is whatever was stored in profile.Data.Trade.incoming by the package
	(copied from the offering player's profile.Data.Trade.outgoing in Phase 2).
]=]
export type TradeFinalizeContext = {
	Session: any, -- TradeSession (forward reference)
	Player: Player,
	Incoming: any,
}

--[=[
	Context passed to RollbackOffer.
	Player is the original owner whose items are being returned.
	Outgoing is whatever was stored in profile.Data.Trade.outgoing by MoveOfferToEscrow.
	May also be called during recovery, in which case Session is nil.
]=]
export type TradeRollbackContext = {
	Session: any?, -- TradeSession; nil during recovery
	Player: Player,
	Outgoing: any,
	Reason: TradeStopReason?,
}

--[=[
	The record stored in the shared DataStore (_PTM_TradeRecords by default) for
	phase tracking and cross-server recovery. Item data is NOT stored here — it
	lives in each player's own profile under profile.Data.Trade.
]=]
export type TradeRecord = {
	tradeId: string,
	jobId: string,
	player1Id: number,
	player2Id: number,
	player1Phase: TradePhase,
	player2Phase: TradePhase,
	executionStart: number,
	status: "active" | "completed" | "rolledback",
	completedAt: number?,
	expiresAt: number?,
}

--[=[
	The escrow field schema stored under profile.Data[TradeDataKey] (default key:
	"TRADE_SESSION", configurable via TradeManagerConfig.TradeDataKey).

	The EscrowLedger is the sole owner of this table. Consumers never read or
	write it directly — MoveOfferToEscrow receives the live table as
	context.Trade, FinalizeOffer receives context.Incoming, and RollbackOffer
	receives context.Outgoing. The field does NOT need to be present in the
	consumer's profile data template.

	- outgoing: written by the consumer's MoveOfferToEscrow callback via
	  context.Trade. May be any serializable value; accumulate multiple items
	  into a table here.
	- incoming: written by the package during Phase 2 (copy of the other player's outgoing).
	- received: written by the package during Phase 3.
	- claimed: written by the package during Phase 4.
]=]
export type TradeProfileFields = {
	tradeId: string?,
	jobId: string?,
	outgoing: any,
	incoming: any,
	received: boolean,
	claimed: boolean,
	executionStart: number?,
	--- Highest phase this player's own profile has reached; written by the
	--- EscrowLedger and used by CommitProfile persistence predicates.
	phase: number?,
}

export type TradeCallbacks = {
	--- Called per-item during negotiation to check if an item can be offered.
	ValidateOffer: (context: TradeOfferContext) -> (boolean, string?),

	--- Called per-item during Phase 1. Must atomically remove the item from the
	--- player's inventory and accumulate it into profile.Data.Trade.outgoing in
	--- any serializable format. profile.Data.Trade will be a table at this point.
	MoveOfferToEscrow: (context: TradeOfferContext) -> (),

	--- Called once per receiving player during Phase 4. Player is the receiver.
	--- Incoming is the full profile.Data.Trade.incoming blob (set by the package
	--- from the other player's outgoing in Phase 2). Must add the items to the
	--- player's inventory. The package clears trade fields after this returns.
	FinalizeOffer: (context: TradeFinalizeContext) -> (),

	--- Called once per committed player during rollback or recovery. Player is the
	--- original owner. Outgoing is the full profile.Data.Trade.outgoing blob set by
	--- MoveOfferToEscrow. Must return the items to the player's inventory.
	RollbackOffer: (context: TradeRollbackContext) -> (),

	--- Returns the player's loaded profile object. Must return nil if not loaded.
	GetProfile: (player: Player) -> any?,

	--- Saves the player's profile and returns a Promise that resolves once the
	--- save is confirmed persisted, including all writes made before this call.
	--- The optional isPersisted predicate receives the persisted data snapshot;
	--- when provided, the promise must resolve only once a persisted snapshot
	--- satisfies it (adapters whose save primitive already guarantees inclusion
	--- of prior writes, e.g. a synchronous in-memory fake, may ignore it).
	--- With PlayerProfileManager: `return ppm:PromiseSave(player, isPersisted)`.
	CommitProfile: (player: Player, isPersisted: ((lastSavedData: { [any]: any }) -> boolean)?) -> any,
}

export type TradeManagerConfig = {
	--- Callbacks for item operations and profile integration.
	Callbacks: TradeCallbacks,
	--- The profile.Data key under which the package stores per-player escrow
	--- state during a trade. Default: "TRADE_SESSION".
	TradeDataKey: string?,
	--- How long trade requests remain valid before auto-expiry. Default: 60 seconds.
	RequestExpirySeconds: number?,
	--- Duration of the user-facing countdown before trade execution begins. Default: 5 seconds.
	CountdownSeconds: number?,
	--- Override the DataStore used for trade records.
	--- If nil, uses DataStoreService:GetDataStore("_PTM_TradeRecords").
	TradeStoreOverride: any?,
	--- How long completed/rolled-back trade records are kept for auditing.
	--- Default: 86400 seconds (24 hours).
	TradeRecordTtlSeconds: number?,
	--- Safety timeout for the execution phases. If phases 1-3 do not complete
	--- within this window, a full rollback is triggered. Default: 60 seconds.
	ExecutionTimeoutSeconds: number?,
}

export type TradeManager = {
	ClassName: "TradeManager",

	TradeStarted: any, -- Signal<(userId1: number, userId2: number) -> ()>
	TradeStopped: any, -- Signal<(userId1: number, userId2: number, reason: TradeStopReason) -> ()>
	TradePrompted: any, -- Signal<(prompter: Player, receiver: Player) -> ()>
	TradePromptCancelled: any, -- Signal<(prompter: Player, receiver: Player) -> ()>

	Destroy: (self: TradeManager) -> (),

	PromptTradeRequest: (self: TradeManager, prompter: Player, receiver: Player) -> (),
	AcceptTradeRequest: (self: TradeManager, receiver: Player, prompter: Player) -> any, -- TradeSession
	DenyTradeRequest: (self: TradeManager, receiver: Player, prompter: Player) -> (),
	CancelTradeRequest: (self: TradeManager, prompter: Player, receiver: Player) -> (),
	CreateTradeSession: (self: TradeManager, player1: Player, player2: Player) -> any, -- TradeSession

	GetIncomingRequests: (self: TradeManager, player: Player) -> { TradeRequest },
	GetOutgoingRequests: (self: TradeManager, player: Player) -> { TradeRequest },
	GetTradeSession: (self: TradeManager, player: Player) -> any?, -- TradeSession?
	HasTradeSession: (self: TradeManager, player: Player) -> boolean,
	GetTradeSessionById: (self: TradeManager, sessionId: string) -> any?, -- TradeSession?

	--- Call this when a player's profile loads to check for and recover any in-flight
	--- trade from a prior session. Must be called before giving the player control.
	RecoverPlayerAsync: (self: TradeManager, player: Player, profile: any) -> (),
}

export type TradeSession = {
	ClassName: "TradeSession",

	OfferItemAdded: any, -- Signal<(player: Player, offer: TradeOfferEntry) -> ()>
	OfferItemRemoved: any, -- Signal<(player: Player, offer: TradeOfferEntry) -> ()>
	OfferLocked: any, -- Signal<(player: Player) -> ()>
	OfferUnlocked: any, -- Signal<(player: Player) -> ()>
	CountdownStarted: any, -- Signal<(endsAt: number) -> ()>
	CountdownTick: any, -- Signal<(remainingSeconds: number) -> ()>
	CountdownCancelled: any, -- Signal<() -> ()>
	CountdownCompleted: any, -- Signal<() -> ()>
	Completed: any, -- Signal<(player1: Player, player2: Player) -> ()>
	Stopped: any, -- Signal<(reason: TradeStopReason) -> ()>

	Destroy: (self: TradeSession) -> (),

	AddOfferItem: (self: TradeSession, player: Player, identifierData: TradeOfferPayload) -> TradeOfferEntry,
	RemoveOfferItem: (self: TradeSession, player: Player, offerId: string) -> (),
	LockOffers: (self: TradeSession, player: Player) -> (),
	UnlockOffers: (self: TradeSession, player: Player) -> (),

	GetSessionId: (self: TradeSession) -> string,
	GetOffers: (self: TradeSession, player: Player) -> { TradeOfferEntry },
	GetOtherPlayer: (self: TradeSession, player: Player) -> Player,
	GetPlayers: (self: TradeSession) -> (Player, Player),
	GetStatus: (self: TradeSession) -> TradeSessionStatus,
	GetSnapshot: (self: TradeSession) -> TradeSessionSnapshot,

	IsLocked: (self: TradeSession, player: Player) -> boolean,
	IsProcessing: (self: TradeSession) -> boolean,
	IsStopped: (self: TradeSession) -> boolean,
	IsCompleted: (self: TradeSession) -> boolean,
	IsCountdownActive: (self: TradeSession) -> boolean,
}

return nil
