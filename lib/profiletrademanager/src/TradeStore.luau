--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeStore
	@private

	Internal DataStore wrapper for trade record persistence and phase tracking.

	Trade records are stored under a single DataStore key per trade (the tradeId).
	The record tracks phase progress for both players and is the cross-server
	source of truth for recovery.

	Completed and rolled-back records are retained with a configurable TTL so they
	can be inspected for auditing. Expired records are treated as not found.
]=]

--// Services //--
const DataStoreService = game:GetService("DataStoreService")

--// Imports //--
const Types = require(script.Parent.TradeTypes)

--// Types //--
export type TradeRecord = Types.TradeRecord
export type TradePhase = Types.TradePhase

export type TradeStore = {
	WriteAsync: (self: TradeStore, record: TradeRecord) -> (),
	ReadAsync: (self: TradeStore, tradeId: string) -> TradeRecord?,
	UpdatePhaseAsync: (self: TradeStore, tradeId: string, playerIndex: number, phase: TradePhase) -> (),
	FinalizeAsync: (self: TradeStore, tradeId: string, status: "completed" | "rolledback") -> (),
	FinalizeWithPhasesAsync: (
		self: TradeStore,
		tradeId: string,
		p1Phase: TradePhase,
		p2Phase: TradePhase,
		status: "completed" | "rolledback"
	) -> (),
}

type TradeStore_Internal = TradeStore & { -- luau: internal type extends the exported public type
	_dataStore: any,
	_ttlSeconds: number,
}

--// Constants //--
local DEFAULT_DATASTORE_NAME = "_PTM_TradeRecords"
local DEFAULT_TTL_SECONDS = 86400 -- 24 hours

--// Class //--
local TradeStore = {}
TradeStore.__index = TradeStore

--[=[
	Creates a new TradeStore.
	@param dataStoreOverride any? -- Optional DataStore override. If nil, uses _PTM_TradeRecords.
	@param ttlSeconds number? -- TTL in seconds for completed records. Default: 86400 (24h).
	@return TradeStore
]=]
function TradeStore.new(dataStoreOverride: any?, ttlSeconds: number?): TradeStore
	local self = setmetatable({} :: any, TradeStore) :: TradeStore_Internal
	self._dataStore = dataStoreOverride or DataStoreService:GetDataStore(DEFAULT_DATASTORE_NAME)
	self._ttlSeconds = ttlSeconds or DEFAULT_TTL_SECONDS
	return (self :: any) :: TradeStore
end

--[=[
	Writes a new trade record. Used at the start of Phase 1.
	Overwrites any existing record with the same tradeId.
]=]
function TradeStore.WriteAsync(self: TradeStore_Internal, record: TradeRecord)
	local ok, err = pcall(function()
		self._dataStore:SetAsync(record.tradeId, record)
	end)
	if not ok then
		warn(`[TradeStore] WriteAsync failed for trade {record.tradeId}: {err}`)
	end
end

--[=[
	Reads a trade record by tradeId.
	Returns nil if not found or if the record's TTL has expired.
]=]
function TradeStore.ReadAsync(self: TradeStore_Internal, tradeId: string): TradeRecord?
	local ok, result = pcall(function()
		return self._dataStore:GetAsync(tradeId)
	end)
	if not ok or result == nil then
		return nil
	end
	-- Treat expired records as not found
	if result.expiresAt and os.time() > result.expiresAt then
		return nil
	end
	return result :: TradeRecord
end

--[=[
	Updates a single player's phase in the trade record.
	playerIndex must be 1 or 2.
]=]
function TradeStore.UpdatePhaseAsync(self: TradeStore_Internal, tradeId: string, playerIndex: number, phase: TradePhase)
	local ok, err = pcall(function()
		self._dataStore:UpdateAsync(tradeId, function(record: TradeRecord?)
			if not record then
				return nil
			end
			if playerIndex == 1 then
				record.player1Phase = phase
			else
				record.player2Phase = phase
			end
			return record
		end)
	end)
	if not ok then
		warn(
			`[TradeStore] UpdatePhaseAsync failed for trade {tradeId}`
				.. ` (player {playerIndex} → phase {phase}): {err}`
		)
	end
end

--[=[
	Marks a trade record as completed or rolled back and sets its TTL fields.
	Safe to call multiple times — will not overwrite an already-finalized record.
]=]
function TradeStore.FinalizeAsync(self: TradeStore_Internal, tradeId: string, status: "completed" | "rolledback")
	const now = os.time()
	const ttl = self._ttlSeconds
	local ok, err = pcall(function()
		self._dataStore:UpdateAsync(tradeId, function(record: TradeRecord?)
			if not record then
				return nil
			end
			-- Idempotent: do not overwrite an already-finalized record
			if record.status ~= "active" then
				return record
			end
			record.status = status
			record.completedAt = now
			record.expiresAt = now + ttl
			return record
		end)
	end)
	if not ok then
		warn(`[TradeStore] FinalizeAsync failed for trade {tradeId}: {err}`)
	end
end

--[=[
	Updates both player phases and finalizes the record in a single DataStore write.
	Use this instead of chaining UpdatePhaseAsync + UpdatePhaseAsync + FinalizeAsync.
]=]
function TradeStore.FinalizeWithPhasesAsync(
	self: TradeStore_Internal,
	tradeId: string,
	p1Phase: TradePhase,
	p2Phase: TradePhase,
	status: "completed" | "rolledback"
)
	const now = os.time()
	const ttl = self._ttlSeconds
	local ok, err = pcall(function()
		self._dataStore:UpdateAsync(tradeId, function(record: TradeRecord?)
			if not record then
				return nil
			end
			record.player1Phase = p1Phase
			record.player2Phase = p2Phase
			if record.status == "active" then
				record.status = status
				record.completedAt = now
				record.expiresAt = now + ttl
			end
			return record
		end)
	end)
	if not ok then
		warn(`[TradeStore] FinalizeWithPhasesAsync failed for trade {tradeId}: {err}`)
	end
end

return TradeStore
