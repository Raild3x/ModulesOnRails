--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeManager
	@server

	Manages the full trade lifecycle: request routing, session creation, and cleanup.
	Integrates with any persistence system via callbacks.

	Key Features:
	- Trade request system (prompt, accept, deny, cancel)
	- Request expiry and cleanup
	- Session lifecycle management
	- One active session per player enforcement
	- Manager-level signals for trade events
	- Callback-driven persistence integration (works with PPM or custom systems)

	Example:
	```lua
	local callbacks = {
		ValidateOffer = function(context) -- Check if item can be traded
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				return false, "Profile not loaded"
			end
			return profile.Data.Inventory[context.IdentifyingData] ~= nil, "Item not in inventory"
		end,
		MoveOfferToEscrow = function(context) -- Remove from inventory, accumulate into escrow
			local profile = ppm:GetProfile(context.Player)
			profile.Data.Inventory[context.IdentifyingData] = nil
			context.Trade.outgoing = context.IdentifyingData
		end,
		FinalizeOffer = function(context) -- Add the received items to inventory
			local profile = ppm:GetProfile(context.Player)
			if context.Incoming ~= nil then
				profile.Data.Inventory[context.Incoming] = true
			end
		end,
		RollbackOffer = function(context) -- Return escrowed items to inventory
			local profile = ppm:GetProfile(context.Player)
			profile.Data.Inventory[context.Outgoing] = true
		end,
		GetProfile = function(player)
			return ppm:GetProfile(player)
		end,
		CommitProfile = function(player, isPersisted)
			return ppm:PromiseSave(player, isPersisted)
		end,
	}

	local tradeManager = TradeManager.new({
		Callbacks = callbacks,
		CountdownSeconds = 5,
	})
	```

	See TradeManagerExample.luau for a complete PPM integration example.
]=]

--// Services //--
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent
local Signal = require(Packages.Signal)
local Janitor = require(Packages.Janitor)

local Types = require(script.TradeTypes)
local TradeSession = require(script.TradeSession)
local TradeStore = require(script.TradeStore)
local TradeRecovery = require(script.TradeRecovery)
local EscrowLedger = require(script.EscrowLedger)

--// Types //--
type Janitor = Janitor.Janitor
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
export type TradeManager = Types.TradeManager
export type TradeManagerConfig = Types.TradeManagerConfig
export type TradeSession = Types.TradeSession
export type TradeRequest = Types.TradeRequest
export type TradeCallbacks = Types.TradeCallbacks
export type TradeStopReason = Types.TradeStopReason

type TradeManager_Internal = TradeManager & {
	_janitor: Janitor,
	_config: TradeManagerConfig,
	_callbacks: TradeCallbacks,
	_tradeStore: TradeStore.TradeStore, -- TradeStore module's exported type
	_ledger: EscrowLedger.EscrowLedger,
	_requestExpirySeconds: number,
	_countdownSeconds: number,
	_executionTimeoutSeconds: number,
	_requests: { TradeRequest },
	_sessions: { [string]: TradeSession }, -- sessionId -> session
	_playerSessions: { [number]: string }, -- userId -> sessionId

	_cleanupExpiredRequests: (self: TradeManager_Internal) -> (),
	_getRequestKey: (prompter: Player, receiver: Player) -> string,
	_findRequest: (self: TradeManager_Internal, prompter: Player, receiver: Player) -> TradeRequest?,
	_removeRequest: (self: TradeManager_Internal, prompter: Player, receiver: Player) -> (),
	_createSession: (self: TradeManager_Internal, player1: Player, player2: Player) -> TradeSession,
	_setupSessionCleanup: (self: TradeManager_Internal, session: TradeSession) -> (),
	_removeSession: (self: TradeManager_Internal, sessionId: string) -> (),
}

--// Constants //--
local DEFAULT_REQUEST_EXPIRY_SECONDS = 60
local DEFAULT_COUNTDOWN_SECONDS = 5
local DEFAULT_EXECUTION_TIMEOUT_SECONDS = 60
local DEFAULT_TRADE_DATA_KEY = "TRADE_SESSION"
local REQUEST_CLEANUP_INTERVAL = 10 -- How often to check for expired requests (seconds)

--// Class //--
local TradeManager = {}
TradeManager.ClassName = "TradeManager"
TradeManager.__index = TradeManager

--[=[
	Creates a new TradeManager instance.
	@param config TradeManagerConfig -- Configuration including callbacks for persistence integration
	@return TradeManager
]=]
function TradeManager.new(config: TradeManagerConfig): TradeManager
	assert(config.Callbacks, "Callbacks are required")
	assert(config.Callbacks.ValidateOffer, "ValidateOffer callback is required")
	assert(config.Callbacks.MoveOfferToEscrow, "MoveOfferToEscrow callback is required")
	assert(config.Callbacks.FinalizeOffer, "FinalizeOffer callback is required")
	assert(config.Callbacks.RollbackOffer, "RollbackOffer callback is required")
	assert(config.Callbacks.GetProfile, "GetProfile callback is required")
	assert(config.Callbacks.CommitProfile, "CommitProfile callback is required")

	local self = setmetatable({} :: any, TradeManager) :: TradeManager_Internal

	self._janitor = Janitor.new()
	self._config = config
	self._callbacks = config.Callbacks
	self._requestExpirySeconds = config.RequestExpirySeconds or DEFAULT_REQUEST_EXPIRY_SECONDS
	self._countdownSeconds = config.CountdownSeconds or DEFAULT_COUNTDOWN_SECONDS
	self._executionTimeoutSeconds = config.ExecutionTimeoutSeconds or DEFAULT_EXECUTION_TIMEOUT_SECONDS
	self._requests = {}
	self._sessions = {}
	self._playerSessions = {}
	self._tradeStore = TradeStore.new(config.TradeStoreOverride, config.TradeRecordTtlSeconds)
	self._ledger = EscrowLedger.new(config.Callbacks, config.TradeDataKey or DEFAULT_TRADE_DATA_KEY)

	-- Initialize signals
	self.TradeStarted = self._janitor:Add(Signal.new() :: any)
	self.TradeStopped = self._janitor:Add(Signal.new() :: any)
	self.TradePrompted = self._janitor:Add(Signal.new() :: any)
	self.TradePromptCancelled = self._janitor:Add(Signal.new() :: any)

	-- Start periodic request cleanup (threads are task.cancel'd by the janitor)
	self._janitor:Add(task.spawn(function()
		while true do
			task.wait(REQUEST_CLEANUP_INTERVAL)
			self:_cleanupExpiredRequests()
		end
	end))

	-- Listen for player leaving to clean up sessions
	self._janitor:Add(
		Players.PlayerRemoving:Connect(function(player: Player)
			local sessionId = self._playerSessions[player.UserId]
			if sessionId then
				local session = self._sessions[sessionId]
				-- A session mid-execution must not be torn down under the running
				-- saga: the leaver's saves reject, execution rolls back or recovery
				-- resolves it, and the Completed/Stopped signal removes the session.
				if session and not session:IsProcessing() then
					local player1, player2 = session:GetPlayers()
					self:_removeSession(sessionId)
					self.TradeStopped:Fire(player1.UserId, player2.UserId, "PlayerLeft")
				end
			end

			-- Remove any pending requests involving this player
			for i = #self._requests, 1, -1 do
				local request = self._requests[i]
				if request.Prompter == player or request.Receiver == player then
					table.remove(self._requests, i)
					if request.Prompter == player then
						self.TradePromptCancelled:Fire(request.Prompter, request.Receiver)
					end
				end
			end
		end),
		"Disconnect"
	)

	return (self :: any) :: TradeManager
end

--[=[
	Destroys the trade manager and cleans up all sessions and requests.
]=]
function TradeManager.Destroy(self: TradeManager_Internal)
	-- Clean up all active sessions
	for sessionId, session in self._sessions do
		session:Destroy()
	end
	table.clear(self._sessions)
	table.clear(self._playerSessions)
	table.clear(self._requests)

	self._janitor:Destroy()
end

--// Private Methods //--

function TradeManager._cleanupExpiredRequests(self: TradeManager_Internal)
	local now = os.time()
	for i = #self._requests, 1, -1 do
		local request = self._requests[i]
		if request.ExpiresAt and request.ExpiresAt <= now then
			table.remove(self._requests, i)
			self.TradePromptCancelled:Fire(request.Prompter, request.Receiver)
		end
	end
end

function TradeManager._getRequestKey(prompter: Player, receiver: Player): string
	return `{prompter.UserId}_{receiver.UserId}`
end

function TradeManager._findRequest(self: TradeManager_Internal, prompter: Player, receiver: Player): TradeRequest?
	for _, request in self._requests do
		if request.Prompter == prompter and request.Receiver == receiver then
			return request
		end
	end
	return nil
end

function TradeManager._removeRequest(self: TradeManager_Internal, prompter: Player, receiver: Player)
	for i, request in self._requests do
		if request.Prompter == prompter and request.Receiver == receiver then
			table.remove(self._requests, i)
			return
		end
	end
end

function TradeManager._createSession(self: TradeManager_Internal, player1: Player, player2: Player): TradeSession
	local session = TradeSession.new(
		player1,
		player2,
		self._callbacks,
		self._ledger,
		self._tradeStore,
		self._countdownSeconds,
		self._executionTimeoutSeconds
	)

	local sessionId = session:GetSessionId()
	self._sessions[sessionId] = session
	self._playerSessions[player1.UserId] = sessionId
	self._playerSessions[player2.UserId] = sessionId

	self:_setupSessionCleanup(session)
	self.TradeStarted:Fire(player1.UserId, player2.UserId)

	return session
end

function TradeManager._setupSessionCleanup(self: TradeManager_Internal, session: TradeSession)
	local sessionId = session:GetSessionId()

	session.Completed:Connect(function(player1: Player, player2: Player)
		self:_removeSession(sessionId)
		self.TradeStopped:Fire(player1.UserId, player2.UserId, "Completed")
	end)

	session.Stopped:Connect(function(reason: TradeStopReason)
		local player1, player2 = session:GetPlayers()
		self:_removeSession(sessionId)
		self.TradeStopped:Fire(player1.UserId, player2.UserId, reason)
	end)
end

function TradeManager._removeSession(self: TradeManager_Internal, sessionId: string)
	local session = self._sessions[sessionId]
	if not session then
		return
	end

	local player1, player2 = session:GetPlayers()
	self._playerSessions[player1.UserId] = nil
	self._playerSessions[player2.UserId] = nil
	self._sessions[sessionId] = nil
	session:Destroy()
end

--// Public Methods //--

--[=[
	Prompts a trade request from one player to another.
	Errors if either player is already in a session or duplicate request exists.
	@param prompter Player -- The player initiating the trade request
	@param receiver Player -- The player receiving the trade request
]=]
function TradeManager.PromptTradeRequest(self: TradeManager_Internal, prompter: Player, receiver: Player)
	assert(prompter ~= receiver, "Cannot trade with yourself")
	assert(not self:HasTradeSession(prompter), `{prompter.Name} is already in an active trade session`)
	assert(not self:HasTradeSession(receiver), `{receiver.Name} is already in an active trade session`)

	-- Check for duplicate outgoing request
	local existingRequest = self:_findRequest(prompter, receiver)
	assert(not existingRequest, `A trade request from {prompter.Name} to {receiver.Name} already exists`)

	local request: TradeRequest = {
		RequestId = HttpService:GenerateGUID(false),
		Prompter = prompter,
		Receiver = receiver,
		CreatedAt = os.time(),
		ExpiresAt = os.time() + self._requestExpirySeconds,
	}

	table.insert(self._requests, request)
	self.TradePrompted:Fire(prompter, receiver)
end

--[=[
	Accepts a trade request and creates a trade session.
	Consumes the pending request and returns the new session.
	@param receiver Player -- The player accepting the request
	@param prompter Player -- The player who sent the request
	@return TradeSession -- The newly created trade session
]=]
function TradeManager.AcceptTradeRequest(self: TradeManager_Internal, receiver: Player, prompter: Player): TradeSession
	local request = self:_findRequest(prompter, receiver)
	assert(request, `No trade request found from {prompter.Name} to {receiver.Name}`)
	assert(request.Receiver == receiver, "You are not the receiver of this request")
	assert(not self:HasTradeSession(receiver), `{receiver.Name} is already in an active trade session`)
	assert(not self:HasTradeSession(prompter), `{prompter.Name} is already in an active trade session`)

	-- Check expiry
	if request.ExpiresAt and request.ExpiresAt <= os.time() then
		self:_removeRequest(prompter, receiver)
		error("Trade request has expired")
	end

	-- Remove the request
	self:_removeRequest(prompter, receiver)

	-- Create session
	return self:_createSession(prompter, receiver)
end

--[=[
	Denies a trade request, ending the prompt.
	@param receiver Player -- The player denying the request
	@param prompter Player -- The player who sent the request
]=]
function TradeManager.DenyTradeRequest(self: TradeManager_Internal, receiver: Player, prompter: Player)
	local request = self:_findRequest(prompter, receiver)
	assert(request, `No trade request found from {prompter.Name} to {receiver.Name}`)
	assert(request.Receiver == receiver, "You are not the receiver of this request")

	self:_removeRequest(prompter, receiver)
	self.TradeStopped:Fire(prompter.UserId, receiver.UserId, "Denied")
end

--[=[
	Cancels a trade request (only the prompter can cancel their own requests).
	@param prompter Player -- The player who sent the request
	@param receiver Player -- The player who received the request
]=]
function TradeManager.CancelTradeRequest(self: TradeManager_Internal, prompter: Player, receiver: Player)
	local request = self:_findRequest(prompter, receiver)
	assert(request, `No trade request found from {prompter.Name} to {receiver.Name}`)
	assert(request.Prompter == prompter, "Only the prompter can cancel the request")

	self:_removeRequest(prompter, receiver)
	self.TradePromptCancelled:Fire(prompter, receiver)
end

--[=[
	Creates a trade session directly between two players (bypassing request system).
	Useful for admin commands or automated trades.
	@param player1 Player -- First player in the trade
	@param player2 Player -- Second player in the trade
	@return TradeSession -- The newly created trade session
]=]
function TradeManager.CreateTradeSession(self: TradeManager_Internal, player1: Player, player2: Player): TradeSession
	assert(player1 ~= player2, "Cannot trade with yourself")
	assert(not self:HasTradeSession(player1), `{player1.Name} is already in an active trade session`)
	assert(not self:HasTradeSession(player2), `{player2.Name} is already in an active trade session`)

	return self:_createSession(player1, player2)
end

--[=[
	Gets all incoming trade requests for a player.
	@param player Player -- The player to get requests for
	@return { TradeRequest } -- Array of requests where this player is the receiver
]=]
function TradeManager.GetIncomingRequests(self: TradeManager_Internal, player: Player): { TradeRequest }
	local incoming = {}
	for _, request in self._requests do
		if request.Receiver == player then
			table.insert(incoming, request)
		end
	end
	return incoming
end

--[=[
	Gets all outgoing trade requests from a player.
	@param player Player -- The player to get requests for
	@return { TradeRequest } -- Array of requests where this player is the prompter
]=]
function TradeManager.GetOutgoingRequests(self: TradeManager_Internal, player: Player): { TradeRequest }
	local outgoing = {}
	for _, request in self._requests do
		if request.Prompter == player then
			table.insert(outgoing, request)
		end
	end
	return outgoing
end

--[=[
	Gets the active trade session for a player, if any.
	@param player Player -- The player to get the session for
	@return TradeSession? -- The active session, or nil if player is not trading
]=]
function TradeManager.GetTradeSession(self: TradeManager_Internal, player: Player): TradeSession?
	local sessionId = self._playerSessions[player.UserId]
	if sessionId then
		return self._sessions[sessionId]
	end
	return nil
end

--[=[
	Checks if a player has an active trade session.
	@param player Player -- The player to check
	@return boolean -- True if the player is currently in a trade session
]=]
function TradeManager.HasTradeSession(self: TradeManager_Internal, player: Player): boolean
	return self._playerSessions[player.UserId] ~= nil
end

--[=[
	Gets a trade session by its unique session ID.
	@param sessionId string -- The session ID to look up
	@return TradeSession? -- The session, or nil if not found
]=]
function TradeManager.GetTradeSessionById(self: TradeManager_Internal, sessionId: string): TradeSession?
	return self._sessions[sessionId]
end

--[=[
	Call this when a player's profile loads to check for and recover any in-flight
	trade from a prior session. Must be called before giving the player control,
	and after the profile is reachable through the GetProfile callback. Yields
	until recovery resolves.
	@param player Player -- The player whose profile just loaded
	@param profile any -- The loaded profile object
]=]
function TradeManager.RecoverPlayerAsync(self: TradeManager_Internal, player: Player, profile: any)
	if not profile or not profile.Data then
		return
	end
	TradeRecovery.RecoverAsync(player, self._ledger, self._tradeStore)
end

return TradeManager
