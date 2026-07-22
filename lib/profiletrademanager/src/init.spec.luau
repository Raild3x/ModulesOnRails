--!nonstrict
--[[
	Tests for ProfileTradeManager: negotiation security, the full execution
	saga, and the fault-injection matrix — a simulated crash, player leave, or
	save/record error at every phase transition, each asserting that item
	conservation holds after recovery.

	The harness models persistence the way a real profile behaves: profiles
	have live in-memory Data plus a `persisted` snapshot updated only by a
	successful CommitProfile. A "server crash" abandons the live world and
	rebuilds a fresh manager from the persisted snapshots against the same
	trade-record backing store, then runs RecoverPlayerAsync.
]]

return function(t: tiniest)
	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local TradeManager = require(script.Parent)
	local Promise = require(script.Parent.Parent.Promise) :: any

	local KEY = "TRADE_SESSION"

	--------------------------------------------------------------------------
	--// Harness //--
	--------------------------------------------------------------------------

	local function deepCopy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for k, v in value do
			copy[k] = deepCopy(v)
		end
		return copy
	end

	local playerCounter = 0
	local function makePlayer(name: string): Player
		playerCounter += 1
		return { UserId = playerCounter, Name = name } :: any
	end

	-- Shared trade-record backing. `flags.dead` simulates the server losing
	-- DataStore access (crash); `flags.updateFails` injects UpdateAsync errors.
	local function makeFakeDataStore(backing: { [string]: any }, flags: { [string]: any })
		return {
			SetAsync = function(_, key: string, value: any)
				if flags.dead or flags.setFails then
					error("injected SetAsync failure")
				end
				backing[key] = deepCopy(value)
			end,
			GetAsync = function(_, key: string)
				if flags.dead then
					error("injected GetAsync failure")
				end
				return deepCopy(backing[key])
			end,
			UpdateAsync = function(_, key: string, transform: (any) -> any)
				if flags.dead then
					error("injected UpdateAsync failure")
				end
				if (flags.updateFails or 0) > 0 then
					flags.updateFails -= 1
					error("injected UpdateAsync failure")
				end
				local newValue = transform(deepCopy(backing[key]))
				if newValue ~= nil then
					backing[key] = newValue
				end
				return newValue
			end,
		}
	end

	-- A world = one simulated server: two players, their profiles, callbacks
	-- with fault-injection hooks, and a TradeManager.
	local function makeWorld(opts: { [string]: any }?)
		local options: { [string]: any } = opts or {}
		local world: { [string]: any } = {}

		world.p1 = makePlayer("P1")
		world.p2 = makePlayer("P2")
		world.recordBacking = options.recordBacking or {}
		world.storeFlags = options.storeFlags or {}
		world.crashed = false
		world.commitBudget = nil -- number of successful commits before a simulated crash
		world.failCommits = {} -- [player] = remaining injected commit failures
		world.escrowThrows = {} -- [player] = true to make MoveOfferToEscrow error
		world.finalizeThrows = {} -- [player] = remaining FinalizeOffer errors
		world.invalidItems = {} -- [itemId] = true to fail ValidateOffer

		world.profiles = {} -- [player] = profile
		local function addProfile(player: Player, inventory: { string }, persistedData: any?)
			local data = persistedData or { Inventory = {} }
			for _, itemId in inventory do
				data.Inventory[itemId] = true
			end
			world.profiles[player] = {
				Data = deepCopy(data),
				persisted = deepCopy(data),
			}
		end
		world.addProfile = addProfile

		local function crash()
			world.crashed = true
			world.storeFlags.dead = true
		end
		world.crash = crash

		local callbacks = {
			ValidateOffer = function(context)
				local profile = world.profiles[context.Player]
				if not profile then
					return false, "Profile not loaded"
				end
				if world.invalidItems[context.IdentifyingData] then
					return false, "Item is not tradeable"
				end
				if not profile.Data.Inventory[context.IdentifyingData] then
					return false, "Item not in inventory"
				end
				return true
			end,
			MoveOfferToEscrow = function(context)
				if world.escrowThrows[context.Player] then
					error("injected escrow failure")
				end
				local profile = world.profiles[context.Player]
				assert(profile, "Profile not loaded")
				assert(profile.Data.Inventory[context.IdentifyingData], "Item missing at escrow time")
				profile.Data.Inventory[context.IdentifyingData] = nil
				local trade = context.Trade
				trade.outgoing = trade.outgoing or {}
				table.insert(trade.outgoing, context.IdentifyingData)
			end,
			FinalizeOffer = function(context)
				if (world.finalizeThrows[context.Player] or 0) > 0 then
					world.finalizeThrows[context.Player] -= 1
					error("injected finalize failure")
				end
				local profile = world.profiles[context.Player]
				assert(profile, "Profile not loaded")
				if context.Incoming ~= nil then
					for _, itemId in context.Incoming do
						profile.Data.Inventory[itemId] = true
					end
				end
			end,
			RollbackOffer = function(context)
				local profile = world.profiles[context.Player]
				assert(profile, "Profile not loaded")
				if context.Outgoing ~= nil then
					for _, itemId in context.Outgoing do
						profile.Data.Inventory[itemId] = true
					end
				end
			end,
			GetProfile = function(player)
				return world.profiles[player]
			end,
			CommitProfile = function(player, isPersisted)
				if world.crashed then
					return Promise.reject("server crashed")
				end
				if (world.failCommits[player] or 0) > 0 then
					world.failCommits[player] -= 1
					return Promise.reject("injected save failure")
				end
				local profile = world.profiles[player]
				if not profile then
					return Promise.reject("no loaded profile (player left)")
				end
				if world.commitBudget ~= nil then
					if world.commitBudget <= 0 then
						crash()
						return Promise.reject("server crashed")
					end
					world.commitBudget -= 1
				end
				profile.persisted = deepCopy(profile.Data)
				profile.LastSavedData = profile.persisted
				if isPersisted and not isPersisted(profile.persisted) then
					return Promise.reject("persistence predicate unsatisfied")
				end
				return Promise.resolve()
			end,
		}
		world.callbacks = callbacks

		world.manager = TradeManager.new {
			Callbacks = callbacks :: any,
			CountdownSeconds = 0,
			ExecutionTimeoutSeconds = options.executionTimeoutSeconds or 30,
			TradeStoreOverride = makeFakeDataStore(world.recordBacking, world.storeFlags),
		}

		return world
	end

	-- Simulates both players rejoining after a crash: a fresh world whose
	-- profiles start from the old world's persisted snapshots, sharing the
	-- same record backing. Runs recovery for both players.
	local function rejoinAndRecover(world)
		local fresh = makeWorld { recordBacking = world.recordBacking }
		-- Keep player identities (UserIds) so the TradeRecord matches.
		fresh.p1 = world.p1
		fresh.p2 = world.p2
		fresh.profiles = {}
		for _, player in { world.p1, world.p2 } do
			local old = world.profiles[player]
			if old then
				fresh.profiles[player] = {
					Data = deepCopy(old.persisted),
					persisted = deepCopy(old.persisted),
				}
			end
		end
		for _, player in { fresh.p1, fresh.p2 } do
			local profile = fresh.profiles[player]
			if profile then
				fresh.manager:RecoverPlayerAsync(player, profile)
			end
		end
		return fresh
	end

	local function runTrade(world, offers1: { string }, offers2: { string })
		local session = world.manager:CreateTradeSession(world.p1, world.p2)
		for _, itemId in offers1 do
			session:AddOfferItem(world.p1, itemId)
		end
		for _, itemId in offers2 do
			session:AddOfferItem(world.p2, itemId)
		end
		session:LockOffers(world.p1)
		session:LockOffers(world.p2)

		local deadline = os.clock() + 5
		while os.clock() < deadline do
			local status = session:GetStatus()
			if status == "Completed" or status == "Stopped" then
				break
			end
			task.wait()
		end
		return session
	end

	-- Asserts a fully-resolved terminal state: no escrow leftovers, and each
	-- player's inventory is exactly the expected item set.
	local function expectResolved(world, expected1: { string }, expected2: { string })
		for _, pair in { { world.p1, expected1 }, { world.p2, expected2 } } do
			local player, expectedItems = pair[1], pair[2]
			local profile = world.profiles[player]
			expect(profile).exists()
			expect(profile.Data[KEY]).never_exists()
			local count = 0
			for _ in profile.Data.Inventory do
				count += 1
			end
			expect(count).is(#expectedItems)
			for _, itemId in expectedItems do
				expect(profile.Data.Inventory[itemId]).is_true()
			end
		end
	end

	--------------------------------------------------------------------------
	--// Negotiation & security //--
	--------------------------------------------------------------------------

	describe("negotiation security", function()
		test("AcceptTradeRequest refuses players already in a session", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			local p3 = makePlayer("P3")
			world.addProfile(p3, {})

			world.manager:PromptTradeRequest(world.p1, world.p2)
			-- Prompter enters another session before the receiver accepts.
			world.manager:CreateTradeSession(world.p1, p3)

			expect(function()
				world.manager:AcceptTradeRequest(world.p2, world.p1)
			end).fails_with("already in an active trade session")
			world.manager:Destroy()
		end)

		test("adding an offer resets both players' locks", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield", "bow" })

			local session = world.manager:CreateTradeSession(world.p1, world.p2)
			session:AddOfferItem(world.p1, "sword")
			session:LockOffers(world.p1)
			expect(session:IsLocked(world.p1)).is_true()

			session:AddOfferItem(world.p2, "shield")
			expect(session:IsLocked(world.p1)).never_is_true()
			expect(session:IsLocked(world.p2)).never_is_true()
			world.manager:Destroy()
		end)

		test("removing an offer resets both players' locks", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })

			local session = world.manager:CreateTradeSession(world.p1, world.p2)
			local offer = session:AddOfferItem(world.p2, "shield")
			session:LockOffers(world.p1)
			expect(session:IsLocked(world.p1)).is_true()

			session:RemoveOfferItem(world.p2, offer.OfferId)
			expect(session:IsLocked(world.p1)).never_is_true()
			world.manager:Destroy()
		end)

		test("offers cannot be changed during the countdown", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword", "gem" })
			world.addProfile(world.p2, { "shield" })

			local session = world.manager:CreateTradeSession(world.p1, world.p2)
			local sessionAny: any = session
			-- Long countdown so it can't fire (and execute) mid-test.
			sessionAny._countdownSeconds = 60
			session:AddOfferItem(world.p1, "sword")
			session:LockOffers(world.p1)
			session:LockOffers(world.p2)
			expect(session:GetStatus()).is("Countdown")
			expect(function()
				session:AddOfferItem(world.p1, "gem")
			end).fails_with("Cannot add items")
			session:UnlockOffers(world.p1) -- cancel countdown before cleanup
			world.manager:Destroy()
		end)
	end)

	--------------------------------------------------------------------------
	--// Happy path //--
	--------------------------------------------------------------------------

	describe("trade execution", function()
		test("successful trade swaps items, clears escrow, completes the record", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Completed")
			expectResolved(world, { "shield" }, { "sword" })

			local record = world.recordBacking[session:GetSessionId()]
			expect(record).exists()
			expect(record.status).is("completed")
			world.manager:Destroy()
		end)

		test("multi-item offers accumulate and transfer", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword", "gem" })
			world.addProfile(world.p2, { "shield" })

			local session = runTrade(world, { "sword", "gem" }, { "shield" })

			expect(session:GetStatus()).is("Completed")
			expectResolved(world, { "shield" }, { "sword", "gem" })
			world.manager:Destroy()
		end)

		test("record write failure aborts before any escrow", function()
			local world = makeWorld { storeFlags = { setFails = true } }
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			world.manager:Destroy()
		end)
	end)

	--------------------------------------------------------------------------
	--// Fault injection: live-failure rollbacks //--
	--------------------------------------------------------------------------

	describe("live failure rollback", function()
		test("pre-flight validation failure stops the trade untouched", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })

			local session = world.manager:CreateTradeSession(world.p1, world.p2)
			session:AddOfferItem(world.p1, "sword")
			session:AddOfferItem(world.p2, "shield")
			world.invalidItems["shield"] = true -- becomes invalid after being offered
			session:LockOffers(world.p1)
			session:LockOffers(world.p2)

			local deadline = os.clock() + 5
			while session:GetStatus() ~= "Stopped" and os.clock() < deadline do
				task.wait()
			end
			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			world.manager:Destroy()
		end)

		test("escrow failure for one player refunds the other", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			world.escrowThrows[world.p2] = true

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			expect(world.profiles[world.p1].persisted[KEY]).never_exists()
			world.manager:Destroy()
		end)

		test("commit save failure rolls back both, including in-memory escrow", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			world.failCommits[world.p2] = 99

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			world.manager:Destroy()
		end)

		test("copy-incoming save failure rolls back both", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			-- Let both Phase 1 commits through, then fail P2's Phase 2 copy.
			local commits = 0
			local realCommit = world.callbacks.CommitProfile
			world.callbacks.CommitProfile = function(player, isPersisted)
				commits += 1
				if commits == 3 then
					return Promise.reject("injected save failure")
				end
				return realCommit(player, isPersisted)
			end

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			world.manager:Destroy()
		end)

		test("failure to record phase 3 rolls back even after P1's received flag persisted", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })

			local store = (world.manager :: any)._tradeStore
			local realUpdate = store.UpdatePhaseAsync
			store.UpdatePhaseAsync = function(s, tradeId, playerIndex, phase)
				if playerIndex == 1 and phase == 3 then
					return Promise.resolve(false)
				end
				return realUpdate(s, tradeId, playerIndex, phase)
			end

			local session = runTrade(world, { "sword" }, { "shield" })

			expect(session:GetStatus()).is("Stopped")
			expectResolved(world, { "sword" }, { "shield" })
			world.manager:Destroy()
		end)

		test("player leaving mid-execution fails their saves and rolls back both", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			-- P2 "leaves": profile released right after both Phase 1 commits land.
			local commits = 0
			local leftProfile: any = nil
			local realCommit = world.callbacks.CommitProfile
			world.callbacks.CommitProfile = function(player, isPersisted)
				commits += 1
				local result = realCommit(player, isPersisted)
				if commits == 2 then
					leftProfile = world.profiles[world.p2]
					world.profiles[world.p2] = nil -- released; Phase 2 will find no profile
				end
				return result
			end

			local session = runTrade(world, { "sword" }, { "shield" })
			expect(session:GetStatus()).is("Stopped")
			world.profiles[world.p2] = leftProfile -- back for the rejoin snapshot

			-- P1 was refunded live; P2's profile is gone from this server but its
			-- escrow state persisted, so recovery on rejoin refunds it.
			local recovered = rejoinAndRecover(world)
			-- P2's persisted state at "leave" time had the item escrowed.
			expectResolved(recovered, { "sword" }, { "shield" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)
	end)

	--------------------------------------------------------------------------
	--// Fault injection: crash + recovery at every phase //--
	--------------------------------------------------------------------------

	describe("crash recovery", function()
		-- Commit order in a successful trade (synchronous fakes):
		-- 1: P1 BeginCommit   2: P2 BeginCommit   3: P2 CopyIncoming
		-- 4: P1 CopyIncoming  5: P1 MarkReceived  6: P2 MarkReceived
		-- 7: P1 Claim         8: P1 cleanup       9: P2 Claim   10: P2 cleanup
		local function crashAfter(commits: number)
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			world.commitBudget = commits
			runTrade(world, { "sword" }, { "shield" })
			return world
		end

		test("crash before any commit: nothing persisted, nothing to recover", function()
			local world = crashAfter(0)
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "sword" }, { "shield" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("crash after one commit: committed player refunded on recovery", function()
			local world = crashAfter(1)
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "sword" }, { "shield" })
			-- The rollback must finalize the record so the partner cannot claim.
			for _, record in recovered.recordBacking do
				expect(record.status).is("rolledback")
			end
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("crash after both commits: both refunded on recovery", function()
			local world = crashAfter(2)
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "sword" }, { "shield" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("crash after both copies, before received: both refunded", function()
			local world = crashAfter(4)
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "sword" }, { "shield" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("crash after point of no return: both claim on recovery", function()
			local world = crashAfter(5) -- P1 received persisted + record phase 3 landed
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "shield" }, { "sword" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("crash mid-claim: claimed player cleans up, other claims", function()
			local world = crashAfter(7) -- P1 claim persisted, cleanup + P2 claim lost
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "shield" }, { "sword" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)
	end)

	--------------------------------------------------------------------------
	--// Recovery decision table (synthetic states) //--
	--------------------------------------------------------------------------

	describe("recovery decision table", function()
		local function makeRecoveryWorld(tradeFields: { [string]: any }?, record: { [string]: any }?)
			local backing = {}
			local world = makeWorld { recordBacking = backing }
			local data = { Inventory = {} }
			if tradeFields then
				data[KEY] = tradeFields
			end
			world.addProfile(world.p1, {}, data)
			if record then
				backing[record.tradeId] = deepCopy(record)
			end
			return world
		end

		test("FinalizeOffer failure keeps escrow state for a retry, which succeeds", function()
			local world = makeWorld()
			world.addProfile(world.p1, { "sword" })
			world.addProfile(world.p2, { "shield" })
			world.finalizeThrows[world.p2] = 1

			local session = runTrade(world, { "sword" }, { "shield" })
			expect(session:GetStatus()).is("Completed")
			-- P1 claimed; P2's claim failed and kept received + incoming.
			expect(world.profiles[world.p1].Data.Inventory["shield"]).is_true()
			expect(world.profiles[world.p2].persisted[KEY]).exists()
			expect(world.profiles[world.p2].persisted[KEY].received).is_true()

			-- Rejoin: recovery retries the claim (record is completed).
			local recovered = rejoinAndRecover(world)
			expectResolved(recovered, { "shield" }, { "sword" })
			world.manager:Destroy()
			recovered.manager:Destroy()
		end)

		test("rolledback record forces rollback even when own received is set", function()
			local world = makeRecoveryWorld({
				tradeId = "t1",
				jobId = "j1",
				outgoing = { "sword" },
				incoming = { "shield" },
				received = true,
				phase = 3,
			}, {
				tradeId = "t1",
				jobId = "j1",
				player1Id = 0, -- patched below
				player2Id = 99999,
				player1Phase = 3,
				player2Phase = 0,
				executionStart = os.time(),
				status = "rolledback",
			})
			world.recordBacking["t1"].player1Id = world.p1.UserId

			world.manager:RecoverPlayerAsync(world.p1, world.profiles[world.p1])

			local profile = world.profiles[world.p1]
			expect(profile.Data[KEY]).never_exists()
			expect(profile.Data.Inventory["sword"]).is_true() -- refunded
			expect(profile.Data.Inventory["shield"]).never_exists() -- NOT claimed
			world.manager:Destroy()
		end)

		test("partner phase >= 3 forces claim even without own received flag", function()
			local world = makeRecoveryWorld({
				tradeId = "t2",
				jobId = "j1",
				outgoing = { "sword" },
				incoming = { "shield" },
				phase = 2,
			}, {
				tradeId = "t2",
				jobId = "j1",
				player1Id = 99999,
				player2Id = 0, -- patched below
				player1Phase = 3,
				player2Phase = 2,
				executionStart = os.time(),
				status = "active",
			})
			world.recordBacking["t2"].player2Id = world.p1.UserId

			world.manager:RecoverPlayerAsync(world.p1, world.profiles[world.p1])

			local profile = world.profiles[world.p1]
			expect(profile.Data[KEY]).never_exists()
			expect(profile.Data.Inventory["shield"]).is_true() -- claimed
			expect(profile.Data.Inventory["sword"]).never_exists() -- given away
			world.manager:Destroy()
		end)

		test("claimed leftovers are cleaned up without item movement", function()
			local world = makeRecoveryWorld { claimed = true }
			world.manager:RecoverPlayerAsync(world.p1, world.profiles[world.p1])
			local profile = world.profiles[world.p1]
			expect(profile.Data[KEY]).never_exists()
			local count = 0
			for _ in profile.Data.Inventory do
				count += 1
			end
			expect(count).is(0)
			world.manager:Destroy()
		end)

		test("outgoing without a tradeId is refunded", function()
			local world = makeRecoveryWorld { outgoing = { "sword" } }
			world.manager:RecoverPlayerAsync(world.p1, world.profiles[world.p1])
			local profile = world.profiles[world.p1]
			expect(profile.Data[KEY]).never_exists()
			expect(profile.Data.Inventory["sword"]).is_true()
			world.manager:Destroy()
		end)

		test("active record with own phase <= 2 rolls back and finalizes the record", function()
			local world = makeRecoveryWorld({
				tradeId = "t3",
				jobId = "j1",
				outgoing = { "sword" },
				phase = 1,
			}, {
				tradeId = "t3",
				jobId = "j1",
				player1Id = 0, -- patched below
				player2Id = 99999,
				player1Phase = 1,
				player2Phase = 1,
				executionStart = os.time(),
				status = "active",
			})
			world.recordBacking["t3"].player1Id = world.p1.UserId

			world.manager:RecoverPlayerAsync(world.p1, world.profiles[world.p1])

			local profile = world.profiles[world.p1]
			expect(profile.Data[KEY]).never_exists()
			expect(profile.Data.Inventory["sword"]).is_true()
			expect(world.recordBacking["t3"].status).is("rolledback")
			world.manager:Destroy()
		end)
	end)
end
