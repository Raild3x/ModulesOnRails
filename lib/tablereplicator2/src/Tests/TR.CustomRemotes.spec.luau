--!strict
--[[
	Coverage for custom remotes: RegisterRemoteSignal, RegisterRemoteUnreliableSignal,
	RegisterRemoteFunction, RegisterOrderedRemoteSignal, RegisterOrderedRemoteFunction,
	and both directions of fire (server→client and client→server), including ordering
	guarantees for the ordered variants.
]]

return function(t: tiniest)
	local ServerReplicator = require("../Server/ServerReplicator")
	local FakeIntermediary = require("./Helpers/FakeIntermediary")
	local SpecUtils = require("./Helpers/SpecUtils")
	local ClientCustomRemote = require("../Client/ClientCustomRemote")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken

	-- Sentinel constant (mirrors ServerReplicator's module-level local).
	-- Defined here to avoid a \0 escape sequence inside multi-line call args,
	-- which the Luau LSP misparses as a string terminator.
	local OFNCALL = "\0ofn"

	local function flush()
		local fc: any = (ServerReplicator :: any)._FrameCoordinator
		fc:Flush()
	end

	-- Bootstraps `player` into the global `hasBootstrapped` table and activates
	-- them in any scope they are already targeting. Mirrors `FakeClient.RequestData`
	-- but without requiring a FakeIntermediary.
	local function bootstrap(player: any)
		local t: any = (ServerReplicator :: any)._Transport
		t.PlayerRequestedData:Fire(player)
	end

	-- Spy helper: captures every call to `transport.FireSignal` for the duration
	-- of one test. Returns the captured-calls list and a restore function.
	local function spyOnFireSignal()
		local calls: { any } = {}
		local t: any = (ServerReplicator :: any)._Transport
		t.FireSignal = function(_self, player, id, name, unreliable, ...)
			table.insert(calls, {
				Player = player,
				Id = id,
				Name = name,
				Unreliable = unreliable,
				Args = { ... },
			})
		end
		return calls, function()
			local t2: any = (ServerReplicator :: any)._Transport
			t2.FireSignal = function() end
		end
	end

	--------------------------------------------------------------------------------
	--// Unordered signals: registration //--
	--------------------------------------------------------------------------------

	describe("RegisterRemoteSignal / RegisterRemoteUnreliableSignal", function()
		test("registered signal is accessible via replicator.Client.Name", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Access"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterRemoteSignal("Hit")
			expect(remote).never_is(nil)
			expect((replicator :: any).Client.Hit).is(remote)
			replicator:Destroy()
		end)

		test("registering the same name twice errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Dup"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteSignal("Hit")
			expect(function()
				replicator:RegisterRemoteSignal("Hit")
			end).fails()
			replicator:Destroy()
		end)

		test("IsUnreliable() is false for a reliable signal", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Reliable"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterRemoteSignal("Hit") :: any
			expect(remote:IsUnreliable()).is(false)
			replicator:Destroy()
		end)

		test("IsUnreliable() is true for an unreliable signal", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Unreliable"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterRemoteUnreliableSignal("Hit") :: any
			expect(remote:IsUnreliable()).is(true)
			replicator:Destroy()
		end)

		test("config.Client shorthand registers signals via sentinels", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Shorthand"),
				Data = {},
				ReplicationTargets = {},
				Client = {
					OnCoin = ServerReplicator.createRemoteEvent(),
					OnHit = ServerReplicator.createUnreliableEvent(),
				},
			})
			local client = (replicator :: any).Client
			expect(client.OnCoin).never_is(nil)
			expect((client.OnCoin :: any):IsUnreliable()).is(false)
			expect(client.OnHit).never_is(nil)
			expect((client.OnHit :: any):IsUnreliable()).is(true)
			replicator:Destroy()
		end)

		test("GetRemoteSignal returns the registered signal", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.GetRemote"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterRemoteSignal("Hit")
			expect(replicator:GetRemoteSignal("Hit")).is(remote)
			replicator:Destroy()
		end)

		test("GetRemoteSignal errors for an unregistered name", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.GetRemoteMissing"),
				Data = {},
				ReplicationTargets = {},
			})
			expect(function()
				replicator:GetRemoteSignal("NeverRegistered")
			end).fails()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Unordered signals: server→client fires //--
	--------------------------------------------------------------------------------

	describe("Unordered signal server→client (FireAll / FireExcept / FirePredicate)", function()
		test("FireAll calls transport.FireSignal for each active player", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.FireAll"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(playerA)
			;(replicator :: any)._Scope:Activate(playerB)
			replicator:RegisterRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FireAll("payload")
			restore()

			expect(#calls).is(2)
			local players: { any } = {}
			for _, c in calls do
				table.insert(players, c.Player)
				expect(c.Id).is(replicator.Id)
				expect(c.Name).is("Hit")
				expect(c.Unreliable).is(false)
				expect(c.Args[1]).is("payload")
			end
			expect(table.find(players, playerA) ~= nil).is_true()
			expect(table.find(players, playerB) ~= nil).is_true()
			replicator:Destroy()
		end)

		test("FireAll with no active players sends nothing", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.FireAllEmpty"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FireAll()
			restore()

			expect(#calls).is(0)
			replicator:Destroy()
		end)

		test("FireExcept skips the ignored player", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.FireExcept"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(playerA)
			;(replicator :: any)._Scope:Activate(playerB)
			replicator:RegisterRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			-- Fake players are plain tables, not Instances; FireExcept checks
			-- `typeof() == "Instance"` to detect single vs list, so wrap in {}.
			;(replicator :: any).Client.Hit:FireExcept({ playerA })
			restore()

			expect(#calls).is(1)
			expect(calls[1].Player).is(playerB)
			replicator:Destroy()
		end)

		test("FireExcept with a list of ignored players skips all of them", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local playerC = { Name = "C" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.FireExceptList"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(playerA)
			;(replicator :: any)._Scope:Activate(playerB)
			;(replicator :: any)._Scope:Activate(playerC)
			replicator:RegisterRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FireExcept({ playerA, playerB })
			restore()

			expect(#calls).is(1)
			expect(calls[1].Player).is(playerC)
			replicator:Destroy()
		end)

		test("FirePredicate sends only to matching players", function()
			local playerA = { Name = "A", Admin = true } :: any
			local playerB = { Name = "B", Admin = false } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.FirePredicate"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(playerA)
			;(replicator :: any)._Scope:Activate(playerB)
			replicator:RegisterRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FirePredicate(function(player)
				return (player :: any).Admin == true
			end)
			restore()

			expect(#calls).is(1)
			expect(calls[1].Player).is(playerA)
			replicator:Destroy()
		end)

		test("unreliable FireAll passes Unreliable=true to FireSignal", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.UnreliableFireAll"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(player)
			replicator:RegisterRemoteUnreliableSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FireAll()
			restore()

			expect(#calls).is(1)
			expect(calls[1].Unreliable).is(true)
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Unordered signals: client→server (Connect / Once) //--
	--------------------------------------------------------------------------------

	describe("Unordered signal client→server (Connect / Once)", function()
		test("Connect callback fires when SignalReceived fires for an active player", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.C2S.Connect"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			local remote = replicator:RegisterRemoteSignal("Hit") :: any

			local fired: { { Player: any, Args: { any } } } = {}
			remote:Connect(function(p, ...)
				table.insert(fired, { Player = p, Args = { ... } })
			end)

			local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
			signal:Fire(player, replicator.Id, "Hit", "damage", 10)

			expect(#fired).is(1)
			expect(fired[1].Player).is(player)
			expect(fired[1].Args[1]).is("damage")
			expect(fired[1].Args[2]).is(10)
			replicator:Destroy()
		end)

		test("SignalReceived is ignored when the player is not active in scope", function()
			local player = { Name = "P" } :: any
			local outsider = { Name = "Outsider" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.C2S.NotActive"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			bootstrap(outsider) -- bootstrapped but NOT a target of this replicator
			local remote = replicator:RegisterRemoteSignal("Hit") :: any

			local fired = false
			remote:Connect(function()
				fired = true
			end)

			-- outsider fires; they're not active in this replicator's scope
			;(ServerReplicator :: any)._Transport.SignalReceived:Fire(outsider, replicator.Id, "Hit")

			expect(fired).is(false)
			replicator:Destroy()
		end)

		test("Once disconnects after the first fire", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.C2S.Once"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			local remote = replicator:RegisterRemoteSignal("Hit") :: any

			local count = 0
			remote:Once(function()
				count += 1
			end)

			;(ServerReplicator :: any)._Transport.SignalReceived:Fire(player, replicator.Id, "Hit")
			;(ServerReplicator :: any)._Transport.SignalReceived:Fire(player, replicator.Id, "Hit")

			expect(count).is(1)
			replicator:Destroy()
		end)

		test("multiple Connect callbacks all fire for the same inbound signal", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.C2S.Multi"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			local remote = replicator:RegisterRemoteSignal("Hit") :: any

			local countA, countB = 0, 0
			remote:Connect(function()
				countA += 1
			end)
			remote:Connect(function()
				countB += 1
			end)

			;(ServerReplicator :: any)._Transport.SignalReceived:Fire(player, replicator.Id, "Hit")

			expect(countA).is(1)
			expect(countB).is(1)
			replicator:Destroy()
		end)

		test("Disconnect stops the callback from firing", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.C2S.Disconnect"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			local remote = replicator:RegisterRemoteSignal("Hit") :: any

			local count = 0
			local conn = remote:Connect(function()
				count += 1
			end)
			conn:Disconnect()

			;(ServerReplicator :: any)._Transport.SignalReceived:Fire(player, replicator.Id, "Hit")

			expect(count).is(0)
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Unordered functions //--
	--------------------------------------------------------------------------------

	describe("RegisterRemoteFunction (unordered)", function()
		test("fn is stored in _RemoteFunctions and is NOT marked ordered", function()
			local fn = function(_self: any, _player: any)
				return 42
			end
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Fn.Store"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteFunction("GetScore", fn)
			expect((replicator :: any)._RemoteFunctions.GetScore).is(fn)
			expect((replicator :: any)._OrderedFunctions.GetScore).is(nil)
			replicator:Destroy()
		end)

		test("config.Client function shorthand registers the function", function()
			local fn = function(_self: any, _player: any)
				return 0
			end
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Fn.Shorthand"),
				Data = {},
				ReplicationTargets = {},
				Client = { GetScore = fn },
			})
			expect((replicator :: any)._RemoteFunctions.GetScore).is(fn)
			replicator:Destroy()
		end)

		test("duplicate RegisterRemoteFunction errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Fn.Dup"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteFunction("GetScore", function()
				return 0
			end)
			expect(function()
				replicator:RegisterRemoteFunction("GetScore", function()
					return 1
				end)
			end).fails()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Cross-type name collisions //--
	--------------------------------------------------------------------------------

	describe("cross-type name collisions", function()
		test("registering a function after a signal with the same name errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Cross.SigThenFn"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteSignal("Hit")
			expect(function()
				replicator:RegisterRemoteFunction("Hit", function() end)
			end).fails()
			replicator:Destroy()
		end)

		test("registering a signal after a function with the same name errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Cross.FnThenSig"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterRemoteFunction("GetScore", function() return 0 end)
			expect(function()
				replicator:RegisterRemoteSignal("GetScore")
			end).fails()
			replicator:Destroy()
		end)

		test("registering an ordered function after an ordered signal with the same name errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Cross.OrdSigThenFn"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			expect(function()
				replicator:RegisterOrderedRemoteFunction("Hit", function() end)
			end).fails()
			replicator:Destroy()
		end)

		test("registering an ordered signal after an ordered function with the same name errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CR.Cross.OrdFnThenSig"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterOrderedRemoteFunction("GetScore", function() return 0 end)
			expect(function()
				replicator:RegisterOrderedRemoteSignal("GetScore")
			end).fails()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Ordered signals: registration //--
	--------------------------------------------------------------------------------

	describe("RegisterOrderedRemoteSignal", function()
		test("registered ordered signal is accessible via replicator.Client.Name", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdSig.Access"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterOrderedRemoteSignal("Hit")
			expect(remote).never_is(nil)
			expect((replicator :: any).Client.Hit).is(remote)
			replicator:Destroy()
		end)

		test("ordered signal GetRemoteSignal returns the same object", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdSig.GetRemote"),
				Data = {},
				ReplicationTargets = {},
			})
			local remote = replicator:RegisterOrderedRemoteSignal("Hit")
			expect(replicator:GetRemoteSignal("Hit")).is(remote)
			replicator:Destroy()
		end)

		test("FireAll does NOT call transport.FireSignal (routes to coordinator)", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdSig.NoFireSignal"),
				Data = {},
				ReplicationTargets = {},
			})
			;(replicator :: any)._Scope:Activate(player)
			replicator:RegisterOrderedRemoteSignal("Hit")

			local calls, restore = spyOnFireSignal()
			;(replicator :: any).Client.Hit:FireAll("payload")
			restore()

			expect(#calls).is(0)
			flush() -- clear the queued signal entry
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Ordered signals: E2E delivery //--
	--------------------------------------------------------------------------------

	describe("Ordered signal delivery (server→client, via FrameCoordinator)", function()
		test("FireAll after Flush delivers the signal to the connected client", function()
			local token = uniqueToken("OrdSig.E2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			local received: { { any } } = {}
			mirrored.Server.Hit:Connect(function(...)
				table.insert(received, { ... })
			end)

			;(replicator :: any).Client.Hit:FireAll("damage", 10)
			flush()

			expect(#received).is(1)
			expect(received[1][1]).is("damage")
			expect(received[1][2]).is(10)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("FireAll reaches both clients when two are active", function()
			local token = uniqueToken("OrdSig.FireAllTwo")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { clientA.Player, clientB.Player },
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			clientA:RequestData()
			clientB:RequestData()

			local mirroredA = clientA:GetFromId(replicator.Id) :: any
			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			local firedA, firedB = false, false
			mirroredA.Server.Hit:Connect(function()
				firedA = true
			end)
			mirroredB.Server.Hit:Connect(function()
				firedB = true
			end)

			;(replicator :: any).Client.Hit:FireAll()
			flush()

			expect(firedA).is_true()
			expect(firedB).is_true()

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("FireExcept after Flush reaches only the non-excluded client", function()
			local token = uniqueToken("OrdSig.FireExceptE2E")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { clientA.Player, clientB.Player },
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			clientA:RequestData()
			clientB:RequestData()

			local mirroredA = clientA:GetFromId(replicator.Id) :: any
			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			local firedA, firedB = false, false
			mirroredA.Server.Hit:Connect(function()
				firedA = true
			end)
			mirroredB.Server.Hit:Connect(function()
				firedB = true
			end)

			;(replicator :: any).Client.Hit:FireExcept({ clientA.Player })
			flush()

			expect(firedA).is(false)
			expect(firedB).is_true()

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("a player removed from scope before Flush does not receive the signal", function()
			local token = uniqueToken("OrdSig.RemovedBeforeFlush")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { clientA.Player, clientB.Player },
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			clientA:RequestData()
			clientB:RequestData()

			local mirroredA = clientA:GetFromId(replicator.Id) :: any
			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			local firedA, firedB = false, false
			mirroredA.Server.Hit:Connect(function()
				firedA = true
			end)
			mirroredB.Server.Hit:Connect(function()
				firedB = true
			end)

			;(replicator :: any).Client.Hit:FireAll()
			-- Remove clientA from scope before flush
			;(replicator :: any)._Scope:RemoveActive(clientA.Player)
			flush()

			expect(firedA).is(false)
			expect(firedB).is_true()

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("ordered signal arrives AFTER a data op queued in the same frame", function()
			local token = uniqueToken("OrdSig.Ordering")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = { Coins = 0 },
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteSignal("Hit")
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			local coinsAtFire: number? = nil
			mirrored.Server.Hit:Connect(function()
				coinsAtFire = mirrored.Manager.Raw.Coins
			end)

			-- Enqueue a data op then an ordered signal in the same logical frame.
			replicator.Manager:Set("Coins", 99)
			;(replicator :: any).Client.Hit:FireAll()
			flush()

			-- The signal must fire after the Set op was applied.
			expect(coinsAtFire).is(99)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("multiple signals in the same frame each fire once in enqueue order", function()
			local token = uniqueToken("OrdSig.MultiSameFrame")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteSignal("A")
			replicator:RegisterOrderedRemoteSignal("B")
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			local order: { string } = {}
			mirrored.Server.A:Connect(function()
				table.insert(order, "A")
			end)
			mirrored.Server.B:Connect(function()
				table.insert(order, "B")
			end)

			;(replicator :: any).Client.A:FireAll()
			;(replicator :: any).Client.B:FireAll()
			flush()

			expect(#order).is(2)
			expect(order[1]).is("A")
			expect(order[2]).is("B")

			replicator:Destroy()
			intermediary:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------
	--// Ordered functions //--
	--------------------------------------------------------------------------------

	describe("RegisterOrderedRemoteFunction", function()
		test("fn is stored in _RemoteFunctions and marked in _OrderedFunctions", function()
			local fn = function(_self: any, _player: any)
				return "ordered"
			end
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdFn.Store"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterOrderedRemoteFunction("GetScore", fn)
			expect((replicator :: any)._RemoteFunctions.GetScore).is(fn)
			expect((replicator :: any)._OrderedFunctions.GetScore).is(true)
			replicator:Destroy()
		end)

		test("duplicate RegisterOrderedRemoteFunction errors", function()
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdFn.Dup"),
				Data = {},
				ReplicationTargets = {},
			})
			replicator:RegisterOrderedRemoteFunction("GetScore", function()
				return 0
			end)
			expect(function()
				replicator:RegisterOrderedRemoteFunction("GetScore", function()
					return 1
				end)
			end).fails()
			replicator:Destroy()
		end)

		test("ORDERED_FN_CALL sentinel calls the registered fn with the correct args", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdFn.CallArgs"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)

			local receivedArgs: { any } = {}
			replicator:RegisterOrderedRemoteFunction("Compute", function(_self, _player, ...)
				receivedArgs = { ... }
				return "ok"
			end)

			local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
			signal:Fire(player, replicator.Id, "Compute", OFNCALL, 1, "alpha", 42)

			expect(receivedArgs[1]).is("alpha")
			expect(receivedArgs[2]).is(42)

			flush()
			replicator:Destroy()
		end)

		test("unknown function name is silently dropped without error or response", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("OrdFn.Unknown"),
				Data = {},
				ReplicationTargets = { player },
			})
			bootstrap(player)
			-- No functions registered; the sentinel fire must not error.
			expect(function()
				local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
				signal:Fire(player, replicator.Id, "NonExistent", OFNCALL, 5)
			end).never_fails()
			flush()
			replicator:Destroy()
		end)

		test("response Signal op is delivered to the client after Flush (E2E)", function()
			local token = uniqueToken("OrdFn.ResponseE2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteFunction("GetScore", function(_self, _player)
				return 99
			end)
			client:RequestData()

			-- Spy on the static _ResolveInvocation to capture what the client receives.
			local resolvedCorr: number? = nil
			local resolvedResults: { any }? = nil
			local origResolve = ClientCustomRemote._ResolveInvocation
			ClientCustomRemote._ResolveInvocation = function(corrId: number, results: { any })
				resolvedCorr = corrId
				resolvedResults = results
				origResolve(corrId, results)
			end

			local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
			signal:Fire(client.Player, replicator.Id, "GetScore", OFNCALL, 1)
			flush()

			ClientCustomRemote._ResolveInvocation = origResolve

			expect(resolvedCorr).is(1)
			expect(resolvedResults).never_is(nil)
			expect((resolvedResults :: any)[1]).is(99)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("multiple in-flight invocations resolve independently by corrId", function()
			local token = uniqueToken("OrdFn.MultiInFlight")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = {},
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteFunction("GetData", function(_self, _player, key: any)
				return key .. "_result"
			end)
			client:RequestData()

			local resolved: { [number]: { any } } = {}
			local origResolve = ClientCustomRemote._ResolveInvocation
			ClientCustomRemote._ResolveInvocation = function(corrId: number, results: { any })
				resolved[corrId] = results
				origResolve(corrId, results)
			end

			-- Two in-flight calls, different corrIds, different args.
			local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
			signal:Fire(client.Player, replicator.Id, "GetData", OFNCALL, 10, "alpha")
			signal:Fire(client.Player, replicator.Id, "GetData", OFNCALL, 20, "beta")
			flush()

			ClientCustomRemote._ResolveInvocation = origResolve

			expect(resolved[10]).never_is(nil)
			expect(resolved[20]).never_is(nil)
			expect(resolved[10][1]).is("alpha_result")
			expect(resolved[20][1]).is("beta_result")

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("response arrives after data ops queued in the same frame (ordering)", function()
			local token = uniqueToken("OrdFn.Ordering")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = { Coins = 0 },
				ReplicationTargets = { client.Player },
			})
			replicator:RegisterOrderedRemoteFunction("BuyCoins", function(_self, _player)
				-- Side-effect: queues a Set BEFORE the response signal is queued.
				replicator.Manager:Set("Coins", 77)
				return 77
			end)
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			local coinsAtResolve: number? = nil
			local origResolve = ClientCustomRemote._ResolveInvocation
			ClientCustomRemote._ResolveInvocation = function(corrId: number, results: { any })
				coinsAtResolve = mirrored.Manager.Raw.Coins
				origResolve(corrId, results)
			end

			local signal: any = (ServerReplicator :: any)._Transport.SignalReceived
			signal:Fire(client.Player, replicator.Id, "BuyCoins", OFNCALL, 1)
			flush()

			ClientCustomRemote._ResolveInvocation = origResolve

			-- Set("Coins", 77) has a lower Seq than the response signal, so the
			-- client applies the Set first, then resolves the invocation.
			expect(coinsAtResolve).is(77)

			replicator:Destroy()
			intermediary:Destroy()
		end)
	end)
end
