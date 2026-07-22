--!strict
--[[
	Coverage for the shared test helpers themselves (`SpecUtils.deepEqual`,
	`FakeManager`, `FakeIntermediary` edge paths). The helpers underpin every
	other spec's assertions, so their comparison/dispatch edge cases deserve
	direct proof rather than incidental coverage.
]]

return function(t: tiniest)
	local ServerReplicator = require("../Server/ServerReplicator")
	local FakeIntermediary = require("./Helpers/FakeIntermediary")
	local FakeManager = require("./Helpers/FakeManager")
	local SpecUtils = require("./Helpers/SpecUtils")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken
	local deepEqual = SpecUtils.deepEqual

	--------------------------------------------------------------------------------

	describe("SpecUtils.deepEqual", function()
		test("equal scalars and identical tables compare equal", function()
			expect(deepEqual(5, 5)).is(true)
			local shared = { a = 1 }
			expect(deepEqual(shared, shared)).is(true)
		end)

		test("mismatched scalars compare unequal", function()
			expect(deepEqual(1, 2)).is(false)
			expect(deepEqual("a", "b")).is(false)
		end)

		test("a table never equals a scalar (either side)", function()
			expect(deepEqual({}, 5)).is(false)
			expect(deepEqual(5, {})).is(false)
		end)

		test("structurally equal tables compare equal", function()
			expect(deepEqual({ a = 1, b = { c = 2 } }, { a = 1, b = { c = 2 } })).is(true)
		end)

		test("a differing nested value compares unequal", function()
			expect(deepEqual({ a = { b = 1 } }, { a = { b = 2 } })).is(false)
		end)

		test("an extra key on either side compares unequal", function()
			expect(deepEqual({ a = 1 }, { a = 1, b = 2 })).is(false)
			expect(deepEqual({ a = 1, b = 2 }, { a = 1 })).is(false)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FakeManager", function()
		test("satisfies the manager duck-type: Raw, no-op Set, disconnectable listeners", function()
			local manager = FakeManager.new({ Coins = 1 })
			expect(manager.Raw.Coins).is(1)
			expect(function()
				manager:Set("Coins", 2) -- deliberate no-op: FakeManager does no diffing
			end).never_fails()
			expect(manager.Raw.Coins).is(1)

			local disconnectApplied = manager:OnApplied(function() end)
			local disconnectDestroy = manager:OnDestroy(function() end)
			expect(type(disconnectApplied)).is("function")
			expect(type(disconnectDestroy)).is("function")
			disconnectApplied()
			disconnectDestroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("package entry point", function()
		test("resolves the realm-appropriate API surface and forwards statics", function()
			-- String requires cannot address the package root (a bare ".." is
			-- rejected), so resolve it through the instance tree instead.
			local TableReplicator = require(script.Parent.Parent :: any) :: any
			-- Edit-mode datamodels report IsClient() as true, so the package
			-- resolves its Client surface as Current.
			expect(TableReplicator.Current).never_is(nil)
			-- The package table forwards Current's statics through __index.
			expect(TableReplicator.GetAll).never_is(nil)
			expect(TableReplicator.ForEach).never_is(nil)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FakeIntermediary edge paths", function()
		test("FakeClient.Use re-raises an error thrown inside fn and restores the realm", function()
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()
			expect(function()
				client:Use(function()
					error("boom")
				end)
			end).fails()
			-- The realm must be restored even after the throw: a normal Use still works.
			expect(function()
				client:Use(function()
					return nil
				end)
			end).never_fails()
			intermediary:Destroy()
		end)

		test("Destroy is idempotent", function()
			local intermediary = FakeIntermediary.new()
			intermediary:Destroy()
			expect(function()
				intermediary:Destroy()
			end).never_fails()
		end)

		test("a send to a player with no connected FakeClient passes through untouched", function()
			local intermediary = FakeIntermediary.new()
			local outsider = { Name = "NotConnected" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("IntermediaryOutsider"),
				Data = { x = 0 },
				ReplicationTargets = { outsider },
			})
			;(replicator :: any)._Scope:Activate(outsider)

			expect(function()
				replicator.Manager:Set("x", 1)
				;(ServerReplicator :: any)._FrameCoordinator:Flush()
			end).never_fails()

			replicator:Destroy()
			intermediary:Destroy()
		end)
	end)
end
