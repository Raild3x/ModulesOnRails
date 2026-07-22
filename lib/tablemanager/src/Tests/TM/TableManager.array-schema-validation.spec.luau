--!strict
--[[
	Schema validation on ArrayInsert (Mutator.validateArrayInsert). The existing
	schema suite only covers construction-time validation and the
	failure-with-callback path; this covers:
	  * a valid element passing the array's element check (the success path),
	  * an invalid element throwing when no OnValidationFailed handler is set,
	  * an array path the schema does not describe (unconstrained -> no check).
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local T = require("../../../T")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("ArrayInsert schema validation", function()
		test("a valid element passes the array element check", function()
			local manager = TableManager.new({ nums = { 1, 2 } }, {
				Schema = T.interface { nums = T.array(T.number) },
			})

			manager:ArrayInsert("nums", 3)

			local nums = manager:Get("nums")
			expect(#nums).is(3)
			expect(nums[3]).is(3)

			manager:Destroy()
		end)

		test("an invalid element invokes OnValidationFailed and is not inserted", function()
			local failedPath = ""
			local manager = TableManager.new({ nums = { 1 } }, {
				Schema = T.interface { nums = T.array(T.number) },
				OnValidationFailed = function(path)
					failedPath = table.concat(path, ".")
				end,
			})

			manager:ArrayInsert("nums", "not a number")

			expect(failedPath).is("nums")
			expect(#manager:Get("nums")).is(1) -- rejected, nothing appended

			manager:Destroy()
		end)

		test("an invalid element throws when no OnValidationFailed handler is set", function()
			local manager = TableManager.new({ nums = { 1 } }, {
				Schema = T.interface { nums = T.array(T.number) },
			})

			expect(function()
				manager:ArrayInsert("nums", "not a number")
			end).fails()

			manager:Destroy()
		end)

		test("an array path unconstrained by the schema skips element validation", function()
			-- The schema describes `other` but not `nums`, so ArrayInsert into
			-- `nums` bypasses the element check entirely.
			local manager = TableManager.new({ other = 1, nums = { 1 } }, {
				Schema = T.interface { other = T.number },
			})

			manager:ArrayInsert("nums", "anything goes")

			local nums = manager:Get("nums")
			expect(#nums).is(2)
			expect(nums[2]).is("anything goes")

			manager:Destroy()
		end)
	end)
end
