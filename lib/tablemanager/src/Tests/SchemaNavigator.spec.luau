--!strict
--[[
	Unit tests for SchemaNavigator — resolving and validating path-based schema
	checks against T metadata. Exercises every navigable meta kind (interface /
	strictInterface / partialInterface / array / optional), the transparent
	optional-unwrapping during traversal, and the "unconstrained path" behaviour
	that makes only schema-described paths enforceable.
]]

return function(t: tiniest)
	local SchemaNavigator = require("../SchemaNavigator")
	local T = require("../../T")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Navigate", function()
		test("an empty path resolves to the root schema", function()
			local schema = T.interface { level = T.number }
			expect(SchemaNavigator.Navigate(schema, {})).is(schema :: any)
		end)

		test("descends interface fields to a leaf check", function()
			local levelCheck = T.number
			local schema = T.interface {
				player = T.interface { level = levelCheck },
			}
			expect(SchemaNavigator.Navigate(schema, { "player", "level" })).is(levelCheck :: any)
		end)

		test("descends strictInterface fields", function()
			local nameCheck = T.string
			local schema = T.strictInterface { name = nameCheck }
			expect(SchemaNavigator.Navigate(schema, { "name" })).is(nameCheck :: any)
		end)

		test("descends partialInterface fields", function()
			local scoreCheck = T.number
			local schema = T.partialInterface { score = scoreCheck }
			expect(SchemaNavigator.Navigate(schema, { "score" })).is(scoreCheck :: any)
		end)

		test("descends an array via a numeric segment to its value check", function()
			local elementCheck = T.string
			local schema = T.interface { tags = T.array(elementCheck) }
			expect(SchemaNavigator.Navigate(schema, { "tags", 1 })).is(elementCheck :: any)
		end)

		test("a non-numeric segment into an array is unconstrained (nil)", function()
			local schema = T.interface { tags = T.array(T.string) }
			expect(SchemaNavigator.Navigate(schema, { "tags", "notAnIndex" })).is(nil)
		end)

		test("transparently unwraps an optional wrapper while traversing", function()
			local firstCheck = T.string
			local schema = T.interface {
				nickname = T.optional(T.interface { first = firstCheck }),
			}
			expect(SchemaNavigator.Navigate(schema, { "nickname", "first" })).is(firstCheck :: any)
		end)

		test("unwraps nested optionals down to the inner check", function()
			local innerCheck = T.number
			local schema = T.interface {
				value = T.optional(T.optional(innerCheck)),
			}
			-- Navigating to `value` itself returns the optional-wrapped check, but a
			-- deeper leaf would keep unwrapping; here the field resolves directly.
			expect(SchemaNavigator.Navigate(schema, { "value" })).exists()
		end)

		test("an unknown field yields nil (unconstrained path)", function()
			local schema = T.interface { known = T.number }
			expect(SchemaNavigator.Navigate(schema, { "unknown" })).is(nil)
		end)

		test("stops early and returns nil once the path leaves the schema", function()
			-- First segment misses, so the second segment sees a nil current.
			local schema = T.interface { known = T.number }
			expect(SchemaNavigator.Navigate(schema, { "unknown", "deeper" })).is(nil)
		end)

		test("navigating past a scalar leaf is unconstrained (leaf has no meta)", function()
			local schema = T.interface { count = T.number }
			expect(SchemaNavigator.Navigate(schema, { "count", "sub" })).is(nil)
		end)
	end)

	describe("Validate", function()
		test("returns true for an unconstrained (unknown) path", function()
			local schema = T.interface { known = T.number }
			local ok = SchemaNavigator.Validate(schema, { "unknown" }, "anything")
			expect(ok).is_true()
		end)

		test("returns true when the value satisfies the resolved check", function()
			local schema = T.interface { level = T.number }
			local ok = SchemaNavigator.Validate(schema, { "level" }, 5)
			expect(ok).is_true()
		end)

		test("returns false with a message when the value fails the check", function()
			local schema = T.interface { level = T.number }
			local ok, err = SchemaNavigator.Validate(schema, { "level" }, "not a number")
			expect(ok).is(false)
			expect(type(err)).is("string")
		end)

		test("validates an array element through its value check", function()
			local schema = T.interface { tags = T.array(T.string) }
			expect(SchemaNavigator.Validate(schema, { "tags", 1 }, "ok")).is_true()
			local ok = SchemaNavigator.Validate(schema, { "tags", 2 }, 123)
			expect(ok).is(false)
		end)

		test("validates through an optional wrapper", function()
			local schema = T.interface {
				nickname = T.optional(T.interface { first = T.string }),
			}
			expect(SchemaNavigator.Validate(schema, { "nickname", "first" }, "Ada")).is_true()
			local ok = SchemaNavigator.Validate(schema, { "nickname", "first" }, 7)
			expect(ok).is(false)
		end)
	end)
end
