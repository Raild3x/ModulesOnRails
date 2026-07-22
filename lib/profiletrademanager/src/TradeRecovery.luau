--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeRecovery
	@private

	Recovery logic for in-flight trades after a server crash or player disconnect.

	Called by TradeManager:RecoverPlayerAsync() when a player's profile loads with
	escrow state present. Must be called before giving the player control. Yields.

	Recovery is a pure per-player decision table over the player's own escrow
	fields (read through the EscrowLedger) plus the shared TradeRecord. There is
	no cross-player coordination and no resume: by the time recovery runs there
	is no live session anywhere, so every path resolves to Claim, Rollback, or
	cleanup. All item movement goes through the ledger, so recovery and live
	execution share one implementation of each procedure.

	## Decision Table

	Evaluated top to bottom; first match wins:

	| Condition                                          | Action              |
	| -------------------------------------------------- | ------------------- |
	| claimed = true                                      | cleanup leftovers   |
	| no tradeId                                          | rollback if outgoing, else cleanup |
	| player not in the TradeRecord                       | cleanup (stale)     |
	| record status = "rolledback"                        | Rollback            |
	| record "completed", own received, or partner ≥ 3    | Claim               |
	| otherwise (active/missing record, not received)     | Rollback + finalize record "rolledback" |

	The "partner phase ≥ 3" claim condition covers the crash window between the
	partner crossing the point of no return and this player's own received flag
	persisting. The record-status checks are what keep the two players consistent
	when they recover independently, possibly on different servers, hours apart:
	a rollback finalizes the record so the partner's recovery also rolls back;
	a completed record makes the partner's recovery claim.

	Failed Claims and Rollbacks (consumer callback threw, save never confirmed)
	leave the escrow fields untouched, so the next rejoin retries the same path.
]=]

--// Imports //--
const Types = require(script.Parent.TradeTypes)
const TradeStore = require(script.Parent.TradeStore)
const EscrowLedger = require(script.Parent.EscrowLedger)

--// Types //--
export type TradeCallbacks = Types.TradeCallbacks
export type TradeRecord = Types.TradeRecord

type TradeStore = TradeStore.TradeStore
type EscrowLedger = EscrowLedger.EscrowLedger

--// Module //--
local TradeRecovery = {}

-- Awaits a ledger promise; warns with context if it fails. Returns success.
local function awaitLedgerOp(op: any, player: Player, what: string): boolean
	const ok, err = op:await()
	if not ok then
		warn(`[TradeRecovery] {what} failed for {player.Name}: {err}. Escrow state kept; will retry on next rejoin.`)
	end
	return ok
end

--[=[
	Entry point. Called by TradeManager:RecoverPlayerAsync after a profile loads
	with escrow state present. Yields until recovery resolves.

	@param player Player -- The player being recovered
	@param ledger EscrowLedger -- Sole owner of the profile escrow fields
	@param tradeStore TradeStore -- The shared DataStore wrapper
]=]
function TradeRecovery.RecoverAsync(player: Player, ledger: EscrowLedger, tradeStore: TradeStore)
	const trade = ledger:Read(player)
	if not trade then
		return
	end

	-- Already claimed from a prior attempt — just clean up lingering fields.
	if trade.claimed == true then
		awaitLedgerOp(ledger:Clear(player), player, "Cleanup (claimed)")
		return
	end

	const tradeId: string? = trade.tradeId
	if not tradeId then
		-- Cannot match a record. Refund anything escrowed, else just clean up.
		if trade.outgoing ~= nil then
			warn(`[TradeRecovery] Profile for {player.Name} has outgoing data but no tradeId. Rolling back.`)
			awaitLedgerOp(ledger:Rollback(player, "RecoveredRollback"), player, "Rollback (no tradeId)")
		else
			awaitLedgerOp(ledger:Clear(player), player, "Cleanup (no tradeId)")
		end
		return
	end

	const record: TradeRecord? = tradeStore:ReadAsync(tradeId)

	local myIndex = 0
	local otherPhase = 0
	if record then
		if record.player1Id == player.UserId then
			myIndex = 1
			otherPhase = record.player2Phase
		elseif record.player2Id == player.UserId then
			myIndex = 2
			otherPhase = record.player1Phase
		else
			-- This player isn't in the record — stale/mismatched data. Clear it.
			warn(
				`[TradeRecovery] {player.Name} (userId={player.UserId}) not found in`
					.. ` TradeRecord {tradeId}. Clearing escrow fields.`
			)
			awaitLedgerOp(ledger:Clear(player), player, "Cleanup (not in record)")
			return
		end
	end

	-- Partner (or a prior recovery of this player) already rolled the trade
	-- back. Roll back too — even if our own received flag is set, the partner
	-- has been refunded, so claiming would duplicate items.
	if record and record.status == "rolledback" then
		awaitLedgerOp(ledger:Rollback(player, "RecoveredRollback"), player, "Rollback (record rolledback)")
		return
	end

	-- Past the point of no return: the trade must complete for this player.
	--   - record "completed": partner finished Phase 4 (crash mid-claim).
	--   - own received flag: our incoming is confirmed persisted.
	--   - partner phase >= 3: partner crossed received; both copies are durable.
	const pastPointOfNoReturn = (record ~= nil and record.status == "completed")
		or trade.received == true
		or otherPhase >= 3
	if pastPointOfNoReturn then
		if awaitLedgerOp(ledger:Claim(player), player, "Claim") and record then
			tradeStore:UpdatePhaseAsync(tradeId, myIndex, 4)
		end
		return
	end

	-- Everything else — record active or missing, own received not set — rolls
	-- back. Finalizing the record as rolledback is what tells the partner's own
	-- recovery (wherever and whenever it runs) to roll back instead of claim.
	if awaitLedgerOp(ledger:Rollback(player, "RecoveredRollback"), player, "Rollback") then
		tradeStore:FinalizeAsync(tradeId, "rolledback")
	end
end

return TradeRecovery
