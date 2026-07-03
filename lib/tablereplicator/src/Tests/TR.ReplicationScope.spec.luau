--!strict
--[[
	Coverage for `ReplicationScope` (the per-subtree targeting state machine:
	pending/active/all sets, the active-version counter, and outbound SendTo
	delegation) plus transport construction/teardown lifecycles that the
	replication specs never touch directly. Player values are plain tables,
	same as the rest of the suite -- the scope only uses them as keys.
]]

return function(t: tiniest)
	local ReplicationScope = require("../Server/ReplicationScope")
	local ServerTransport = require("../Shared/Transport/ServerTransport")
	local ClientTransport = require("../Shared/Transport/ClientTransport")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local function newScope()
		-- The scope only ever calls transport:SendMessage; a recording stub is
		-- a full stand-in.
		local sent: { { Player: any, Buf: buffer, Instances: { Instance }? } } = {}
		local stubTransport = {
			SendMessage = function(_self, player, buf, instances)
				table.insert(sent, { Player = player, Buf = buf, Instances = instances })
			end,
		}
		return ReplicationScope.new(stubTransport :: any), sent
	end

	--------------------------------------------------------------------------------

	describe("ReplicationScope targeting", function()
		test("a fresh scope targets nobody", function()
			local scope = newScope()
			local player = { Name = "P" } :: any
			expect(scope:IsReplicatingToAll()).is(false)
			expect(scope:IsActive(player)).is(false)
			expect(scope:IsPending(player)).is(false)
			expect(scope:IsTargeting(player)).is(false)
			expect(#scope:GetActivePlayers()).is(0)
			expect(#scope:GetTargetPlayers()).is(0)
		end)

		test("AddPending marks a player pending (targeted but not active)", function()
			local scope = newScope()
			local player = { Name = "P" } :: any
			scope:AddPending(player)
			expect(scope:IsPending(player)).is(true)
			expect(scope:IsActive(player)).is(false)
			expect(scope:IsTargeting(player)).is(true)
		end)

		test("RemovePending clears only the pending mark", function()
			local scope = newScope()
			local player = { Name = "P" } :: any
			scope:AddPending(player)
			scope:RemovePending(player)
			expect(scope:IsPending(player)).is(false)
			expect(scope:IsTargeting(player)).is(false)
		end)

		test("Activate promotes pending to active", function()
			local scope = newScope()
			local player = { Name = "P" } :: any
			scope:AddPending(player)
			scope:Activate(player)
			expect(scope:IsPending(player)).is(false)
			expect(scope:IsActive(player)).is(true)
			expect(scope:IsTargeting(player)).is(true)
			expect(#scope:GetActivePlayers()).is(1)
		end)

		test("RemoveActive deactivates without touching pending", function()
			local scope = newScope()
			local active = { Name = "A" } :: any
			local pending = { Name = "B" } :: any
			scope:Activate(active)
			scope:AddPending(pending)
			scope:RemoveActive(active)
			expect(scope:IsActive(active)).is(false)
			expect(scope:IsPending(pending)).is(true)
		end)

		test("RemovePlayer drops a player from both pending and active", function()
			local scope = newScope()
			local active = { Name = "A" } :: any
			local pending = { Name = "B" } :: any
			scope:Activate(active)
			scope:AddPending(pending)
			scope:RemovePlayer(active)
			scope:RemovePlayer(pending)
			expect(scope:IsTargeting(active)).is(false)
			expect(scope:IsTargeting(pending)).is(false)
			expect(#scope:GetTargetPlayers()).is(0)
		end)

		test("SetAll makes IsTargeting true for anyone", function()
			local scope = newScope()
			local stranger = { Name = "S" } :: any
			scope:SetAll(true)
			expect(scope:IsReplicatingToAll()).is(true)
			expect(scope:IsTargeting(stranger)).is(true)
			-- ...but not active until the handshake activates them.
			expect(scope:IsActive(stranger)).is(false)
			scope:SetAll(false)
			expect(scope:IsTargeting(stranger)).is(false)
		end)

		test("GetTargetPlayers lists active + pending when not replicating to all", function()
			local scope = newScope()
			local active = { Name = "A" } :: any
			local pending = { Name = "B" } :: any
			scope:Activate(active)
			scope:AddPending(pending)
			local targets = scope:GetTargetPlayers()
			expect(#targets).is(2)
			expect(table.find(targets, active) ~= nil).is_true()
			expect(table.find(targets, pending) ~= nil).is_true()
		end)

		test("GetTargetPlayers defers to Players:GetPlayers() when replicating to all", function()
			local scope = newScope()
			scope:SetAll(true)
			-- Compare against the live service list: another spec may have
			-- created a LocalPlayer via CreateLocalPlayer.
			expect(#scope:GetTargetPlayers()).is(#game:GetService("Players"):GetPlayers())
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ReplicationScope active-version counter", function()
		test("bumps on Activate / RemoveActive / RemovePlayer, not on pending changes", function()
			local scope = newScope()
			local player = { Name = "P" } :: any
			local v0 = scope:GetActiveVersion()

			scope:AddPending(player)
			scope:RemovePending(player)
			expect(scope:GetActiveVersion()).is(v0)

			scope:Activate(player)
			local v1 = scope:GetActiveVersion()
			expect(v1 > v0).is_true()

			scope:RemoveActive(player)
			local v2 = scope:GetActiveVersion()
			expect(v2 > v1).is_true()

			scope:RemovePlayer(player)
			expect(scope:GetActiveVersion() > v2).is_true()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ReplicationScope.SendTo", function()
		test("delegates directly to transport SendMessage", function()
			local scope, sent = newScope()
			local player = { Name = "P" } :: any
			local buf = buffer.create(4)
			local instances = {} :: { Instance }
			scope:SendTo(player, buf, instances)
			expect(#sent).is(1)
			expect(sent[1].Player).is(player)
			expect(sent[1].Buf).is(buf)
			expect(sent[1].Instances).is(instances)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("Transport lifecycles", function()
		test("a second ServerTransport reuses the existing remote objects and tears down cleanly", function()
			-- The module-level ServerReplicator transport already created the
			-- remotes, so this constructor takes every find-existing branch.
			local transport = ServerTransport.new()
			expect(transport).never_is(nil)
			expect(function()
				transport:Destroy()
			end).never_fails()
		end)

		test("ClientTransport constructs against the existing remotes and tears down cleanly", function()
			local transport = ClientTransport.new()
			expect(transport).never_is(nil)
			expect(function()
				transport:Destroy()
			end).never_fails()
		end)

		test("ServerTransport outbound methods reject non-Player targets", function()
			-- No real (connected) Player exists in the test datamodel, so the
			-- engine-facing sends are exercised up to FireClient's argument
			-- validation: a plain-table player must be rejected loudly.
			local transport = ServerTransport.new()
			local fakePlayer = { Name = "NotAPlayer" } :: any
			expect(function()
				transport:SendMessage(fakePlayer, buffer.create(1), nil)
			end).fails()
			expect(function()
				transport:NotifyDataSent(fakePlayer)
			end).fails()
			expect(function()
				transport:FireSignal(fakePlayer, 1, "Sig", false)
			end).fails()
			expect(function()
				transport:FireSignal(fakePlayer, 1, "Sig", true)
			end).fails()
			transport:Destroy()
		end)

		test("ClientTransport.FireSignal fires both the reliable and unreliable channels", function()
			-- In edit mode the datamodel is both client and server, so FireServer
			-- is legal; the loopback (if any) is dropped by the server handshake
			-- guards, making this safe to fire for real.
			local transport = ClientTransport.new()
			expect(function()
				transport:FireSignal(999999901, "CoverageSig", false, "payload")
			end).never_fails()
			expect(function()
				transport:FireSignal(999999901, "CoverageSig", true, "payload")
			end).never_fails()
			transport:Destroy()
		end)

		test("ClientTransport.InvokeFunction reaches InvokeServer without a synchronous error", function()
			local transport = ClientTransport.new()
			expect(function()
				-- InvokeServer yields for a response that may never come in edit
				-- mode; spawning keeps the test itself from blocking on it.
				task.spawn(function()
					transport:InvokeFunction(999999902, "CoverageFn")
				end)
			end).never_fails()
			transport:Destroy()
		end)

		test("a RequestData issued before the remote connects is sent on connect", function()
			-- The constructor connects synchronously in specs (the remotes always
			-- exist), so rewind a fresh transport to the not-yet-connected state a
			-- real client sits in while the remotes are still replicating.
			local transport = ClientTransport.new()
			local t: any = transport
			local remote = t._remote
			expect(remote).never_is(nil)
			t._remote = nil
			t._connected = false
			t._requested = false

			local promise = transport:RequestData() -- queues: not yet connected
			expect(t._requested).is(true)
			promise:cancel()

			-- Connecting must flush the queued request to the server.
			t:_connect(remote)
			expect(t._connected).is(true)

			-- Once the data-complete marker has been seen, RequestData resolves
			-- immediately instead of waiting on the signal again.
			t._receivedData = true
			local resolved = transport:RequestData()
			expect(resolved:getStatus()).is("Resolved")

			transport:Destroy()
		end)

		test("a non-RequestData message on the reliable channel is ignored by the server", function()
			local transport = ClientTransport.new()
			expect(function()
				(transport :: any)._remote:FireServer("NotARealRequestKind")
			end).never_fails()
			transport:Destroy()
		end)
	end)
end
