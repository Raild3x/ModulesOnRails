return function(tiniest)
	print("Running t.spec.luau - tests for the t type checking library")
	local T = require(script.Parent)

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function expectPass(check, value)
		local ok, err = check(value)
		expect(ok).is(true)
		expect(err).is(nil)
	end

	local function expectPassArgs(check, ...)
		local ok, err = check(...)
		expect(ok).is(true)
		expect(err).is(nil)
	end

	local function expectFail(check, value, expectedMessage)
		local ok, err = check(value)
		expect(ok).is(false)
		expect(type(err)).is("string")
		if expectedMessage ~= nil then
			expect(err).is(expectedMessage)
		end
	end

	local function expectFailArgs(check, expectedMessage, ...)
		local ok, err = check(...)
		expect(ok).is(false)
		expect(type(err)).is("string")
		if expectedMessage ~= nil then
			expect(err).is(expectedMessage)
		end
	end

	describe("Primitive Validators", function()
		test("type and typeof create validators", function()
			expectPass(T.type("table"), {})
			expectFail(T.type("table"), "nope", "table expected, got string")

			expectPass(T.typeof("string"), "hello")
			expectFail(T.typeof("string"), 10, "string expected, got number")
		end)

		test("primitive aliases validate expected values", function()
			expectPass(T.boolean, true)
			expectPass(T.callback, function() end)
			expectPass(T.none, nil)
			expectPass(T.string, "abc")
			expectPass(T.table, {})

			expect(T["function"]).is(T.callback)
			expect(T["nil"]).is(T.none)
		end)

		test("any, number, nan, and integer behave correctly", function()
			expectPass(T.any, false)
			expectFail(T.any, nil, "any expected, got nil")

			expectPass(T.number, 42)
			expectFail(T.number, 0 / 0, "unexpected NaN value")

			expectPass(T.nan, 0 / 0)
			expectFail(T.nan, 42, "unexpected non-NaN value")

			expectPass(T.integer, 12)
			expectFail(T.integer, 12.5, "integer expected, got 12.5")
		end)
	end)

	describe("Literals and Constraints", function()
		test("literal accepts one or many allowed values", function()
			expectPass(T.literal("ready"), "ready")
			expectFail(T.literal("ready"), "waiting", "expected ready, got waiting")

			local colorCheck = T.literal("red", "green", "blue")
			expectPass(colorCheck, "green")
			expectFail(colorCheck, "yellow")
		end)

		test("keyOf and valueOf derive literals from tables", function()
			local keys = T.keyOf { Alpha = true, Beta = true }
			expectPass(keys, "Alpha")
			expectFail(keys, "Gamma")

			local values = T.valueOf { first = 1, second = 2 }
			expectPass(values, 2)
			expectFail(values, 3)
		end)

		test("numeric constraint helpers validate ranges", function()
			expectPass(T.numberMin(10), 10)
			expectFail(T.numberMin(10), 9, "number >= 10 expected, got 9")

			expectPass(T.numberMax(10), 10)
			expectFail(T.numberMax(10), 11, "number <= 10 expected, got 11")

			expectPass(T.numberConstrained(10, 20), 15)
			expectFail(T.numberConstrained(10, 20), 25, "number <= 20 expected, got 25")

			expectPass(T.numberConstrainedExclusive(10, 20), 15)
			expectFail(T.numberConstrainedExclusive(10, 20), 10, "number > 10 expected, got 10")

			expectPass(T.numberPositive, 1)
			expectPass(T.numberNegative, -1)

			expectPass(T.integerMin(10), 10)
			expectFail(T.integerMin(10), 9, "integer >= 10 expected, got 9")
			expectFail(T.integerMin(10), 10.5, "integer expected, got 10.5")

			expectPass(T.integerMax(10), 10)
			expectFail(T.integerMax(10), 11, "integer <= 10 expected, got 11")

			expectPass(T.integerConstrained(10, 20), 15)
			expectFail(T.integerConstrained(10, 20), 25, "integer <= 20 expected, got 25")

			expectPass(T.integerConstrainedExclusive(10, 20), 15)
			expectFail(T.integerConstrainedExclusive(10, 20), 10, "integer > 10 expected, got 10")

			expectPass(T.integerPositive, 1)
			expectPass(T.integerNegative, -1)
		end)

		test("match validates strings against patterns", function()
			local slug = T.match("^[a-z]+%-%d+$")
			expectPass(slug, "entry-42")
			expectFail(slug, "Entry42", '"Entry42" failed to match pattern "^[a-z]+%-%d+$"')
		end)
	end)

	describe("Composition", function()
		test("optional and tuple compose validators", function()
			local optionalString = T.optional(T.string)
			expectPass(optionalString, nil)
			expectPass(optionalString, "value")
			expectFail(optionalString, 5, "(optional) string expected, got number")

			local tupleCheck = T.tuple(T.string, T.number)
			expectPassArgs(tupleCheck, "score", 50)
			expectFailArgs(tupleCheck, "Bad tuple index #2:\n\tnumber expected, got string", "score", "oops")

			-- Edge behavior: tuple validates declared positions and allows extra arguments.
			local singleValueTuple = T.tuple(T.string)
			expectPassArgs(singleValueTuple, "hello")
			expectPassArgs(singleValueTuple, "hello", 123)

			local strictTupleCheck = T.strictTuple(T.string, T.number)
			expectPassArgs(strictTupleCheck, "score", 50)
			expectFailArgs(strictTupleCheck, "Bad tuple index #2:\n\tnumber expected, got nil", "score")
			expectFailArgs(strictTupleCheck, "Bad tuple length: expected 2 arguments, got 3", "score", 50, true)
		end)

		test("where refines a validator with custom predicates", function()
			local nonEmptyString = T.where(T.string, function(value)
				return #value > 0, "string must not be empty"
			end)
			expectPass(nonEmptyString, "hello")
			expectFail(nonEmptyString, "", "string must not be empty")
			expectFail(nonEmptyString, 10, "string expected, got number")

			local evenNumber = T.where(T.number, function(value)
				return value % 2 == 0
			end, "number must be even")
			expectPass(evenNumber, 12)
			expectFail(evenNumber, 11, "number must be even")

			local positiveNumber = T.where(T.number, function(value)
				return value > 0
			end, "number must be positive")
			expectFail(positiveNumber, -3, "number must be positive")

			local explicitPredicateMessage = T.where(T.number, function(value)
				if value > 0 then
					return true
				end
				return false, "predicate message wins"
			end, "fallback message")
			expectFail(explicitPredicateMessage, -1, "predicate message wins")
		end)

		test("keys, values, map, and set validate table shapes", function()
			expectPass(T.keys(T.string), { a = 1, b = 2 })
			expectFail(T.keys(T.string), { [1] = true }, "bad key 1:\n\tstring expected, got number")

			expectPass(T.values(T.number), { a = 1, b = 2 })
			expectFail(T.values(T.number), { a = "x" }, "bad value for key a:\n\tnumber expected, got string")

			local scoreMap = T.map(T.string, T.number)
			expectPass(scoreMap, { Alpha = 10, Beta = 20 })
			expectFail(scoreMap, { Alpha = "oops" }, "bad value for key Alpha:\n\tnumber expected, got string")

			local tags = T.set(T.string)
			expectPass(tags, { fast = true, active = true })
			expectFail(tags, { fast = false }, "bad value for key fast:\n\texpected true, got false")
		end)

		test("array and strictArray validate ordered collections", function()
			local stringArray = T.array(T.string)
			expectPass(stringArray, { "a", "b", "c" })
			expectFail(stringArray, { [1] = "a", [3] = "c" }, "[array] key 3 must be sequential")

			local strict = T.strictArray(T.string, T.number, T.boolean)
			expectPass(strict, { "item", 1, true })
			expectFail(strict, { "item", 1, true, "extra" }, "[strictArray] Array size exceeds limit of 3")
			expectFail(strict, { "item", "wrong" }, "[strictArray] Array index #2 - number expected, got string")

			local strictPair = T.strictArray(T.string, T.number)
			expectFail(strictPair, { "name" }, "[strictArray] Array index #2 - number expected, got nil")
		end)

		test("union and intersection combine validators", function()
			local stringOrNumber = T.union(T.string, T.number)
			expectPass(stringOrNumber, "ready")
			expectPass(stringOrNumber, 10)
			expectFail(
				stringOrNumber,
				true,
				"bad type for union:\n\t[1] string expected, got boolean\n\t[2] number expected, got boolean"
			)

			local positiveInt = T.intersection(T.integer, T.numberPositive)
			expectPass(positiveInt, 5)
			expectFail(positiveInt, -1, "number > 0 expected, got -1")
		end)

		test("interface and strictInterface validate table contracts", function()
			local playerCheck = T.interface {
				Name = T.string,
				Health = T.numberConstrained(0, 100),
			}
			expectPass(playerCheck, {
				Name = "Builderman",
				Health = 100,
				Team = "Red",
			})
			expectFail(
				playerCheck,
				{ Name = "Builderman", Health = 150 },
				"[interface] bad value for Health:\n\tnumber <= 100 expected, got 150"
			)

			local exactPlayerCheck = T.strictInterface {
				Name = T.string,
				Health = T.number,
			}
			expectPass(exactPlayerCheck, { Name = "Builderman", Health = 50 })
			expectFail(
				exactPlayerCheck,
				{ Name = "Builderman", Health = 50, Team = "Red" },
				'[interface] unexpected field "Team"'
			)
		end)

		test("partialInterface validates known fields only when present", function()
			local playerPatchCheck = T.partialInterface {
				Name = T.string,
				Health = T.numberConstrained(0, 100),
			}

			expectPass(playerPatchCheck, {})
			expectPass(playerPatchCheck, { Name = "Builderman" })
			expectPass(playerPatchCheck, { Team = "Red" })
			expectPass(playerPatchCheck, { Name = "Builderman", Health = 75 })
			expectFail(
				playerPatchCheck,
				{ Health = 150 },
				"[partialInterface] bad value for Health:\n\tnumber <= 100 expected, got 150"
			)

			expectPass(playerPatchCheck, { Name = nil })
		end)

		test("complex nested schemas validate deeply nested structures", function()
			local itemCheck = T.interface {
				Id = T.integerPositive,
				Tags = T.array(T.string),
				Meta = T.partialInterface {
					Rarity = T.union(T.literal("Common"), T.literal("Rare")),
					Weight = T.numberPositive,
				},
			}

			local profileCheck = T.strictInterface {
				Name = T.string,
				Level = T.integerConstrained(1, 60),
				Items = T.array(itemCheck),
				Flags = T.map(T.string, T.boolean),
			}

			expectPass(profileCheck, {
				Name = "Builderman",
				Level = 10,
				Items = {
					{ Id = 1, Tags = { "starter" }, Meta = { Rarity = "Common", Weight = 2 } },
				},
				Flags = { Active = true },
			})

			expectFail(profileCheck, {
				Name = "Builderman",
				Level = 0,
				Items = {},
				Flags = {},
			}, "[interface] bad value for Level:\n\tinteger >= 1 expected, got 0")

			expectFail(profileCheck, {
				Name = "Builderman",
				Level = 10,
				Items = {},
				Flags = {},
				Unexpected = true,
			}, '[interface] unexpected field "Unexpected"')
		end)

		test("complex union failures include branch details", function()
			local payloadCheck = T.interface {
				Mode = T.union(T.literal("A"), T.integerPositive),
			}

			expectFail(
				payloadCheck,
				{ Mode = false },
				"[interface] bad value for Mode:\n\tbad type for union:\n\t[1] expected A, got false\n\t[2] number expected, got boolean"
			)
		end)
	end)

	describe("Roblox Specific Validators", function()
		test("enum validates EnumItems when available", function()
			local ok, item = pcall(function()
				return Enum.Material.Slate
			end)
			if not ok then
				expect(true).is(true)
				return
			end

			local materialCheck = T.enum(Enum.Material)
			expectPass(materialCheck, item)
			expectFail(materialCheck, Enum.KeyCode.A, "enum of Material expected, got enum of KeyCode")
		end)

		test("instanceOf, instanceIsA, and children validate instance trees when available", function()
			local ok, folder = pcall(function()
				return Instance.new("Folder")
			end)
			if not ok then
				expect(true).is(true)
				return
			end

			folder.Name = "Root"
			local value = Instance.new("StringValue")
			value.Name = "Config"
			value.Parent = folder

			expectPass(T.instanceOf("Folder"), folder)
			expectFail(T.instanceOf("Part"), folder, "Part expected, got Folder")

			expectPass(T.instanceIsA("Instance"), folder)

			local childrenCheck = T.children {
				Config = T.instanceOf("StringValue"),
			}
			expectPass(childrenCheck, folder)

			local extra = Instance.new("Folder")
			extra.Name = "Config"
			extra.Parent = folder
			expectFail(childrenCheck, folder, 'Cannot process multiple children with the same name "Config"')
		end)
	end)

	describe("Function Helpers", function()
		test("wrap enforces argument validation", function()
			local wrapped = T.wrap(function(a, b)
				return a + b
			end, T.tuple(T.number, T.number))

			expect(wrapped(2, 3)).is(5)

			local ok, err = pcall(function()
				wrapped("2", 3)
			end)
			expect(ok).is(false)
			expect(type(err)).is("string")
		end)

		test("strict converts a validator into an asserting function", function()
			local assertString = T.strict(T.tuple(T.string))

			local ok = pcall(function()
				assertString("hello")
			end)
			expect(ok).is(true)

			ok = pcall(function()
				assertString(123)
			end)
			expect(ok).is(false)
		end)
	end)
end
