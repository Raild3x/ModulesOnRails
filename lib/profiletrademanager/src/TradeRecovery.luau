--!strict
-- Authors: Logan Hunt (Raildex)
-- June 02, 2026
--[=[
	@class TradeRecovery
	@private

	Recovery logic for in-flight trades after a server crash or player disconnect.

	Called by TradeManager:RecoverPlayerAsync() when a player's profile loads with
	a non-nil Data.Trade table. Must be called before giving the player control.

	## Decision Tree

	The recovery path is determined by reading:
	  1. The player's own profile fields (claimed, received, incoming, outgoing, jobId)
	  2. The shared TradeRecord from the DataStore (phase tracking for both players)

	```
	claimed = true              → clean up lingering fields only
	record nil + received=true  → Claim (point-of-no-return, no record needed)
	record nil + received=false → Rollback
	myPhase = 4                 → clean up only
	myPhase = 3, otherPhase ≥ 3 → Claim
	myPhase = 3, otherPhase < 3 → Claim (other will claim independently)
	myPhase = 2, otherPhase ≥ 2 → same-server check → Resume Phase 3 or Rollback
	myPhase = 2, otherPhase < 2 → Rollback
	myPhase = 1, otherPhase = 1 → same-server check → Resume Phase 2 or Rollback
	myPhase = 1, otherPhase = 0 → Rollback
	myPhase = 0                 → no-op
	```

	## Same-Server Resume Check

	When the decision tree says "same-server check":
	  - jobId must match game.JobId (else different server → Rollback)
	  - Both players must rejoin this server within RESUME_WAIT_SECONDS of each other
	  - If the other player doesn't arrive in time → Rollback for both
	  - If both arrive → signal the coordinator to resume from the appropriate phase

	## Claim Procedure (in recovery)

	Calls FinalizeOffer with Player = this player, Incoming = profile.Data.Trade.incoming.
	Sets claimed = true, clears trade fields, forces save, updates TradeRecord.

	## Rollback Procedure (in recovery)

	Calls RollbackOffer with Player = this player, Outgoing = profile.Data.Trade.outgoing.
	Clears all trade fields, forces save, calls FinalizeAsync("rolledback") (idempotent).
]=]

--// Imports //--
const Types = require(script.Parent.TradeTypes)

--// Types //--
export type TradeCallbacks = Types.TradeCallbacks
export type TradeRecord = Types.TradeRecord
export type TradeStopReason = Types.TradeStopReason

type TradeStore = {
	ReadAsync: (self: TradeStore, tradeId: string) -> TradeRecord?,
	UpdatePhaseAsync: (self: TradeStore, tradeId: string, playerIndex: number, phase: number) -> (),
	FinalizeAsync: (self: TradeStore, tradeId: string, status: "completed" | "rolledback") -> (),
}

--- An entry in the pending-recovery coordinator held by TradeManager.
--- When a player arrives for recovery, they register here. When both players
--- for the same trade arrive, both are signaled to resume.
export type PendingRecoveryEntry = {
	player: Player,
	resolve: () -> (), -- call to signal: other player arrived, proceed
	reject: () -> (), -- call to signal: timeout expired, roll back
	timeoutThread: thread,
}

--// Constants //--
local RESUME_WAIT_SECONDS = 15 -- Max seconds to wait for the other player to rejoin before rollback

--// Module //--
local TradeRecovery = {}

-- Clears all trade fields from a profile and triggers a save.
local function clearTradeFields(profile: any, callbacks: TradeCallbacks, player: Player)
	if profile.Data.Trade then
		profile.Data.Trade.tradeId = nil
		profile.Data.Trade.jobId = nil
		profile.Data.Trade.outgoing = nil
		profile.Data.Trade.incoming = nil
		profile.Data.Trade.received = nil
		profile.Data.Trade.claimed = nil
		profile.Data.Trade.executionStart = nil
	end
	callbacks.TriggerSave(player)
end

-- Performs the Claim procedure for a single player during recovery.
-- Calls FinalizeOffer, marks claimed, clears fields, saves, updates DataStore.
local function claimForPlayer(
	player: Player,
	profile: any,
	tradeId: string,
	myIndex: number,
	tradeStore: TradeStore,
	callbacks: TradeCallbacks
)
	const incoming = profile.Data.Trade and profile.Data.Trade.incoming
	const finalizeOk, finalizeErr = pcall(function()
		callbacks.FinalizeOffer {
			Session = nil,
			Player = player,
			Incoming = incoming,
		}
	end)
	if not finalizeOk then
		warn(
			`[TradeRecovery] FinalizeOffer failed for {player.Name}: {finalizeErr}.`
				.. ` claimed=true will remain so recovery can retry on next rejoin.`
		)
	end
	-- Mark claimed and clear fields. If FinalizeOffer failed, leave claimed=true
	-- in the profile so the next recovery attempt can retry.
	if profile.Data.Trade then
		profile.Data.Trade.claimed = true
		profile.Data.Trade.incoming = nil
		profile.Data.Trade.outgoing = nil
		profile.Data.Trade.received = nil
		profile.Data.Trade.tradeId = nil
		profile.Data.Trade.jobId = nil
		profile.Data.Trade.executionStart = nil
	end
	callbacks.TriggerSave(player)
	if finalizeOk then
		-- Safe to fully clear the trade table on the next tick.
		task.defer(function()
			if profile.Data.Trade then
				profile.Data.Trade.claimed = nil
				profile.Data.Trade = nil
				callbacks.TriggerSave(player)
			end
		end)
	end
	task.spawn(function()
		tradeStore:UpdatePhaseAsync(tradeId, myIndex, 4)
	end)
end

-- Performs the Rollback procedure for a single player during recovery.
-- Calls RollbackOffer, clears fields, saves, finalizes DataStore record.
local function rollbackForPlayer(
	player: Player,
	profile: any,
	tradeId: string,
	myIndex: number,
	reason: TradeStopReason,
	tradeStore: TradeStore,
	callbacks: TradeCallbacks
)
	const outgoing = profile.Data.Trade and profile.Data.Trade.outgoing
	if outgoing ~= nil then
		const rollbackOk, rollbackErr = pcall(function()
			callbacks.RollbackOffer {
				Session = nil,
				Player = player,
				Outgoing = outgoing,
				Reason = reason,
			}
		end)
		if not rollbackOk then
			warn(
				`[TradeRecovery] RollbackOffer failed for {player.Name}: {rollbackErr}.`
					.. ` tradeId={tradeId} myIndex={myIndex} reason={reason}`
			)
		end
	end
	clearTradeFields(profile, callbacks, player)
	task.spawn(function()
		tradeStore:FinalizeAsync(tradeId, "rolledback")
	end)
end

--[=[
	Entry point. Called by TradeManager:RecoverPlayerAsync after a profile loads
	with a non-nil Data.Trade table.

	@param player Player -- The player being recovered
	@param profile any -- The loaded profile with Data.Trade fields
	@param tradeStore TradeStore -- The shared DataStore wrapper
	@param callbacks TradeCallbacks -- Consumer callbacks (FinalizeOffer, RollbackOffer, etc.)
	@param pendingRecovery { [string]: PendingRecoveryEntry } -- Cross-player coordinator held by TradeManager
]=]
function TradeRecovery.RecoverAsync(
	player: Player,
	profile: any,
	tradeStore: TradeStore,
	callbacks: TradeCallbacks,
	pendingRecovery: { [string]: PendingRecoveryEntry }
)
	const tradeData = profile.Data.Trade
	if not tradeData then
		return
	end

	const tradeId: string? = tradeData.tradeId
	const jobId: string? = tradeData.jobId
	const outgoing: any = tradeData.outgoing
	const incoming: any = tradeData.incoming
	const received: boolean = tradeData.received == true
	const claimed: boolean = tradeData.claimed == true

	-- Step 1: Already claimed — just clean up any lingering fields.
	if claimed then
		clearTradeFields(profile, callbacks, player)
		if profile.Data.Trade then
			profile.Data.Trade.claimed = nil
			profile.Data.Trade = nil
			callbacks.TriggerSave(player)
		end
		return
	end

	-- If there's no tradeId we can't match against a record. Rollback if we have outgoing.
	if not tradeId then
		if outgoing ~= nil then
			warn(
				`[TradeRecovery] Profile for {player.Name} has outgoing data but no tradeId.`
					.. ` Clearing trade fields.`
			)
			clearTradeFields(profile, callbacks, player)
		end
		return
	end

	-- Step 2: If received = true we are past the point of no return.
	-- Complete the claim regardless of whether we can find the TradeRecord.
	if received then
		claimForPlayer(player, profile, tradeId, 0 :: number, tradeStore, callbacks)
		-- myIndex = 0 here because we'll update it properly if we can read the record.
		-- This is a best-effort update; the important thing is the claim happens.
		return
	end

	-- Step 3: Fetch the TradeRecord to determine phase context.
	const record: TradeRecord? = tradeStore:ReadAsync(tradeId)

	-- Record expired or not found.
	if not record then
		if outgoing ~= nil then
			-- Had committed items but no record — roll back.
			warn(
				`[TradeRecovery] TradeRecord for {tradeId} not found (expired or missing).`
					.. ` Rolling back outgoing items for {player.Name}.`
			)
			rollbackForPlayer(player, profile, tradeId, 1, "RecoveredRollback", tradeStore, callbacks)
		else
			clearTradeFields(profile, callbacks, player)
		end
		return
	end

	-- Determine which player index this player is.
	local myIndex: number
	local otherIndex: number
	if record.player1Id == player.UserId then
		myIndex = 1
		otherIndex = 2
	elseif record.player2Id == player.UserId then
		myIndex = 2
		otherIndex = 1
	else
		-- This player isn't in the record — stale/mismatched data. Clear it.
		warn(
			`[TradeRecovery] {player.Name} (userId={player.UserId}) not found in`
				.. ` TradeRecord {tradeId}. Clearing trade fields.`
		)
		clearTradeFields(profile, callbacks, player)
		return
	end

	const myPhase: number = if myIndex == 1 then record.player1Phase else record.player2Phase
	const otherPhase: number = if otherIndex == 1 then record.player1Phase else record.player2Phase

	-- Step 4: Decision tree.

	-- Phase 4 — already claimed from a prior attempt.
	if myPhase >= 4 then
		clearTradeFields(profile, callbacks, player)
		return
	end

	-- Phase 3 — received is set, incoming is saved. Must claim.
	if myPhase >= 3 then
		claimForPlayer(player, profile, tradeId, myIndex, tradeStore, callbacks)
		return
	end

	-- Phase 2 — incoming was copied and saved, but not yet received.
	-- Phase 1 — committed and saved, but incoming not yet copied.
	-- Both require the other player to also be on this server (same jobId).
	if myPhase >= 1 then
		-- JobId mismatch means we're on a different server from when execution started.
		-- Recovery from a different server cannot resume; rollback is the only safe option.
		if jobId ~= game.JobId then
			warn(
				`[TradeRecovery] JobId mismatch for trade {tradeId} (stored={jobId}, current={game.JobId}).`
					.. ` Rolling back {player.Name}.`
			)
			rollbackForPlayer(player, profile, tradeId, myIndex, "RecoveredRollback", tradeStore, callbacks)
			return
		end

		-- Other player hasn't committed yet — we can't resume, roll back.
		if otherPhase == 0 then
			warn(
				`[TradeRecovery] Other player has not committed for trade {tradeId}.` .. ` Rolling back {player.Name}.`
			)
			rollbackForPlayer(player, profile, tradeId, myIndex, "RecoveredRollback", tradeStore, callbacks)
			return
		end

		-- Both players committed and this is the same server. Check if the other
		-- player is also recovering right now (pending coordinator).
		const existing: PendingRecoveryEntry? = pendingRecovery[tradeId]
		if existing and existing.player ~= player then
			-- Other player is already waiting. Cancel their timeout, signal both to proceed.
			task.cancel(existing.timeoutThread)
			pendingRecovery[tradeId] = nil
			existing.resolve()
			-- This player can now proceed to re-run from the appropriate phase.
			-- Since both are on-server with matching jobId, continue from max(myPhase, otherPhase).
			const resumeFromPhase = math.max(myPhase, otherPhase)
			if resumeFromPhase >= 2 then
				-- Both have incoming saved; proceed to mark received.
				claimForPlayer(player, profile, tradeId, myIndex, tradeStore, callbacks)
			else
				-- Both committed but incoming not copied; rollback is safest since we
				-- can't re-run Phase 2 without the live session context.
				warn(
					`[TradeRecovery] Both players on-server for trade {tradeId} at phase {resumeFromPhase},`
						.. ` but no live session. Rolling back both.`
				)
				rollbackForPlayer(player, profile, tradeId, myIndex, "RecoveredRollback", tradeStore, callbacks)
			end
		else
			-- Register this player and wait for the other to arrive.
			local resolveCoord: () -> () = nil :: any
			local rejectCoord: () -> () = nil :: any
			local coordDone = false

			resolveCoord = function()
				if coordDone then
					return
				end
				coordDone = true
				-- Both players are on-server. Proceed from max phase.
				const resumeFromPhase = math.max(myPhase, otherPhase)
				if resumeFromPhase >= 2 then
					claimForPlayer(player, profile, tradeId, myIndex, tradeStore, callbacks)
				else
					rollbackForPlayer(player, profile, tradeId, myIndex, "RecoveredRollback", tradeStore, callbacks)
				end
			end

			rejectCoord = function()
				if coordDone then
					return
				end
				coordDone = true
				-- Timeout: other player never arrived. Roll back this player.
				pendingRecovery[tradeId] = nil
				warn(
					`[TradeRecovery] Other player did not rejoin within {RESUME_WAIT_SECONDS}s`
						.. ` for trade {tradeId}. Rolling back {player.Name}.`
				)
				rollbackForPlayer(player, profile, tradeId, myIndex, "RecoveredRollback", tradeStore, callbacks)
			end

			const timeoutThread = task.delay(RESUME_WAIT_SECONDS, rejectCoord)

			pendingRecovery[tradeId] = {
				player = player,
				resolve = resolveCoord,
				reject = rejectCoord,
				timeoutThread = timeoutThread,
			}
		end
		return
	end

	-- Phase 0 — nothing was committed. Clear any stale fields.
	clearTradeFields(profile, callbacks, player)
end

return TradeRecovery
