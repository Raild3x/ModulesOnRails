--!strict
--[[
	Unit tests for Mutator's proxy-reparenting rollback helpers
	(reparentWithRollback / restoreReparent), driven against a real
	ProxyManager. These back MoveTo/CopyTo/Swap rollback; restoreReparent in
	particular is only reached on a batch abort, so it is covered here directly.
]]

return function(t: tiniest)
	local Mutator = require("../Mutator")
	local ProxyManager = require("../ProxyManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("restoreReparent", function()
		test("no-ops when proxyManager is nil", function()
			Mutator.restoreReparent(nil, { Proxy = {} :: any, Parent = nil, Key = nil })
			expect(true).is_true()
		end)

		test("no-ops when the rollback handle is nil", function()
			local manager = ProxyManager.new({})
			Mutator.restoreReparent(manager, nil)
			expect(true).is_true()
			manager:Destroy()
		end)

		test("restores a reparented proxy to its original parent/key", function()
			local data = { child = { x = 1 }, other = {} }
			local manager = ProxyManager.new(data)
			local rootProxy = manager:CreateProxy(data)
			local childProxy = rootProxy.child -- registers a proxy for data.child

			-- Move the proxy, capturing the rollback handle.
			local rollback = Mutator.reparentWithRollback(manager, data.child, data.other, "moved")
			expect(rollback).exists()
			expect(manager:GetMetadata(childProxy).Key).is("moved")
			expect(manager:GetMetadata(childProxy).Parent).is(data.other)

			-- Roll the move back.
			Mutator.restoreReparent(manager, rollback)
			expect(manager:GetMetadata(childProxy).Key).is("child")
			expect(manager:GetMetadata(childProxy).Parent).is(data)

			manager:Destroy()
		end)
	end)

	describe("reparentWithRollback", function()
		test("returns nil when proxies are disabled (nil manager)", function()
			expect(Mutator.reparentWithRollback(nil, { x = 1 }, {}, "k")).is(nil)
		end)

		test("returns nil for a non-table value", function()
			local manager = ProxyManager.new({})
			expect(Mutator.reparentWithRollback(manager, 5, {}, "k")).is(nil)
			manager:Destroy()
		end)

		test("returns nil when the value has no live proxy", function()
			local data = { child = { x = 1 } }
			local manager = ProxyManager.new(data)
			manager:CreateProxy(data)
			-- data.child was never accessed, so it has no proxy yet.
			expect(Mutator.reparentWithRollback(manager, data.child, {}, "k")).is(nil)
			manager:Destroy()
		end)
	end)
end
