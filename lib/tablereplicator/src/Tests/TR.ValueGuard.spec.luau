--!strict
--[[
	Unit coverage for `ValueGuard`: the shallow top-level type check and the deep
	recursive scan (path building, array indexing, cycle safety, bad keys) that
	back both the BufferCodec encode guard and the server's write-time value
	diagnostics. Pure logic -- no replicators, no transport.
]]

return function(t: tiniest)
	local ValueGuard = require("../Shared/Serialization/ValueGuard")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	--------------------------------------------------------------------------------

	describe("ValueGuard.BadTopLevelType", function()
		test("returns the type name for a non-serializable value", function()
			local badType, path = ValueGuard.BadTopLevelType(function() end)
			expect(badType).is("function")
			expect(#(path :: { any })).is(0)
		end)

		test("returns nil for a serializable scalar", function()
			expect((ValueGuard.BadTopLevelType(42))).is(nil)
			expect((ValueGuard.BadTopLevelType("hello"))).is(nil)
		end)

		test("does not descend into a table (shallow only)", function()
			-- A table that merely CONTAINS a function is fine at the top level.
			expect((ValueGuard.BadTopLevelType({ cb = function() end }))).is(nil)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ValueGuard.FindNonReplicable", function()
		test("returns nil for a fully clean graph", function()
			local badType, path = ValueGuard.FindNonReplicable({ a = 1, b = { c = "x", d = { 1, 2, 3 } } })
			expect(badType).is(nil)
			expect(path).is(nil)
		end)

		test("returns nil for a clean scalar", function()
			expect((ValueGuard.FindNonReplicable(42))).is(nil)
		end)

		test("flags a non-serializable top-level value with an empty path", function()
			local badType, path = ValueGuard.FindNonReplicable(coroutine.create(function() end))
			expect(badType).is("thread")
			expect(#(path :: { any })).is(0)
		end)

		test("returns the key-path to a nested offender, outermost first", function()
			local badType, path = ValueGuard.FindNonReplicable({
				Stats = { Inventory = { OnEquip = function() end } },
			})
			expect(badType).is("function")
			local p = path :: { any }
			expect(p[1]).is("Stats")
			expect(p[2]).is("Inventory")
			expect(p[3]).is("OnEquip")
		end)

		test("flags an offender inside an array, pathed by index", function()
			local badType, path = ValueGuard.FindNonReplicable({ 1, 2, function() end })
			expect(badType).is("function")
			expect((path :: { any })[1]).is(3)
		end)

		test("flags a non-serializable table key at its parent's path", function()
			local badType, path = ValueGuard.FindNonReplicable({ Nested = { [function() end] = true } })
			expect(badType).is("function")
			expect((path :: { any })[1]).is("Nested")
		end)

		test("is cycle-safe: a clean self-referential table terminates as clean", function()
			local node: any = { name = "root" }
			node.self = node
			expect((ValueGuard.FindNonReplicable(node))).is(nil)
		end)

		test("still finds an offender reachable through a cycle", function()
			local node: any = { bad = function() end }
			node.self = node
			expect((ValueGuard.FindNonReplicable(node))).is("function")
		end)

		test("covers non-serializable userdata (RBXScriptSignal)", function()
			local folder = Instance.new("Folder")
			local badType = ValueGuard.FindNonReplicable({ sig = folder.ChildAdded })
			expect(badType).is("RBXScriptSignal")
			folder:Destroy()
		end)
	end)
end
