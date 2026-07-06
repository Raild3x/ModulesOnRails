--!strict
--[[
	Schema validation on the scalar/dict `Set` path (Mutator.applyWrite +
	applyRootSet). The existing schema suites cover construction-time validation,
	ArrayInsert element checks, and the root-Set *raise* path. This covers the
	two directions the report flagged as one-sided:
	  * a `Set` that violates the schema with NO OnValidationFailed handler must
	    `error` (Mutator.luau:365 raise path, previously never taken for Set),
	  * a `Set` / root-`Set` that violates the schema WITH an OnValidationFailed
	    handler must swallow the write and invoke the handler instead of erroring
	    (Mutator.luau:605 root-Set swallow path, previously never taken).
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local T = require("../../../T")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Set schema validation", function()
		test("a Set that violates the schema throws when no OnValidationFailed handler is set", function()
			local manager = TableManager.new({ count = 1 }, {
				Schema = T.interface { count = T.number },
			})

			expect(function()
				manager:Set("count", "not a number")
			end).fails()

			-- The rejected write must not have mutated the value.
			expect(manager:Get("count")).is(1)

			manager:Destroy()
		end)

		test("a valid Set passes the schema check", function()
			local manager = TableManager.new({ count = 1 }, {
				Schema = T.interface { count = T.number },
			})

			manager:Set("count", 42)
			expect(manager:Get("count")).is(42)

			manager:Destroy()
		end)

		test("a failing Set invokes OnValidationFailed and is swallowed (no error, no mutation)", function()
			local failedPath = ""
			local failedValue: any = nil
			local manager = TableManager.new({ count = 1 }, {
				Schema = T.interface { count = T.number },
				OnValidationFailed = function(path, value)
					failedPath = table.concat(path, ".")
					failedValue = value
				end,
			})

			-- No error is raised because the handler swallows the failure.
			manager:Set("count", "bad")

			expect(failedPath).is("count")
			expect(failedValue).is("bad")
			expect(manager:Get("count")).is(1) -- rejected, unchanged

			manager:Destroy()
		end)

		test("a failing root Set invokes OnValidationFailed and is swallowed", function()
			local failures = 0
			local manager = TableManager.new({ count = 1 }, {
				Schema = T.strictInterface { count = T.number },
				OnValidationFailed = function()
					failures += 1
				end,
			})

			-- Root replacement whose new root violates the schema: the handler
			-- swallows it, so no error and the root is left intact.
			manager:Set({}, { count = "nope" })

			expect(failures).is(1)
			expect(manager:Get("count")).is(1)

			-- A valid root replacement still applies normally afterwards.
			manager:Set({}, { count = 7 })
			expect(manager:Get("count")).is(7)

			manager:Destroy()
		end)
	end)
end
