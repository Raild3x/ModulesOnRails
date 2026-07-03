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
	end)
end
