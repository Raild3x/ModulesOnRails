--!strict

return function(tiniest: tiniest)
	print("Running t.spec.luau - tests for the t type checking library")
	local T = require(script.Parent)
	type Check<T> = T.Check<T>
	type CheckTuple<T...> = T.CheckTuple<T...>

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function expectPass(ok: boolean, err: string?)
		expect(ok).is(true)
		expect(err).is(nil)
	end

	local function expectFail(ok: boolean, err: string?): (string?) -> ()
		return function(expectedMessage: string?)
			expect(ok).is(false)
			expect(type(err)).is("string")
			if expectedMessage ~= nil then
				expect(err).is(expectedMessage)
			end
		end
	end

	describe("Primitive Validators", function()
		test("type and typeof create validators", function()
			expectPass(T.type("table") {})
			expectFail(T.type("table")("nope"))("table expected, got string")

			expectPass(T.typeof("string")("hello"))
			expectFail(T.typeof("string")(10))("string expected, got number")
		end)

		test("type validates all Lua primitive types", function()
			-- nil, boolean, string, number, table, function, thread
			expectPass(T.type("nil")(nil))
			expectPass(T.type("boolean")(true))
			expectPass(T.type("boolean")(false))
			expectPass(T.type("string")("foo"))
			expectPass(T.type("number")(123))
			expectPass(T.type("table") {})
			expectPass(T.type("function")(function() end))
			expectPass(T.type("thread")(coroutine.create(function() end)))

			-- All should fail with wrong types
			expectFail(T.type("nil")(true))("nil expected, got boolean")
			expectFail(T.type("boolean")("true"))("boolean expected, got string")
			expectFail(T.type("string")(123))("string expected, got number")
			expectFail(T.type("number")("123"))("number expected, got string")
			expectFail(T.type("table")("{}"))("table expected, got string")
			expectFail(T.type("function")("function"))("function expected, got string")
			expectFail(T.type("thread")("thread"))("thread expected, got string")
		end)

		test("primitive aliases validate expected values", function()
			expectPass(T.boolean(true))
			expectPass(T.callback(function() end))
			expectPass(T.none(nil))
			expectPass(T.string("abc"))
			expectPass(T.table {})

			expect(T["function"]).is(T.callback)
			expect(T["nil"]).is(T.none)
		end)

		test("any, number, nan, and integer behave correctly", function()
			expectPass(T.any(false))
			expectFail(T.any(nil))("any expected, got nil")

			expectPass(T.number(42))
			expectFail(T.number(0 / 0))("unexpected NaN value")

			expectPass(T.nan(0 / 0))
			expectFail(T.nan(42))("unexpected non-NaN value")

			expectPass(T.integer(12))
			expectFail(T.integer(12.5))("integer expected, got 12.5")
		end)
	end)

	describe("Literals and Constraints", function()
		test("literal accepts one or many allowed values", function()
			expectPass(T.literal("ready")("ready"))
			expectFail(T.literal("ready")("waiting"))("expected ready, got waiting")

			local colorCheck = T.literal("red", "green", "blue")
			expectPass(colorCheck("green"))
			expectFail(colorCheck("yellow"))()
		end)

		test("keyOf and valueOf derive literals from tables", function()
			local keys = T.keyOf { Alpha = true, Beta = true }
			expectPass(keys("Alpha"))
			expectFail(keys("Gamma"))()

			local values = T.valueOf { first = 1, second = 2 }
			expectPass(values(2))
			expectFail(values(3))()
		end)

		test("numeric constraint helpers validate ranges", function()
			expectPass(T.numberMin(10)(10))
			expectFail(T.numberMin(10)(9))("number >= 10 expected, got 9")

			expectPass(T.numberMax(10)(10))
			expectFail(T.numberMax(10)(11))("number <= 10 expected, got 11")

			expectPass(T.numberConstrained(10, 20)(15))
			expectFail(T.numberConstrained(10, 20)(25))("number <= 20 expected, got 25")

			expectPass(T.numberConstrainedExclusive(10, 20)(15))
			expectFail(T.numberConstrainedExclusive(10, 20)(10))("number > 10 expected, got 10")

			expectPass(T.numberPositive(1))
			expectPass(T.numberNegative(-1))

			expectPass(T.integerMin(10)(10))
			expectFail(T.integerMin(10)(9))("integer >= 10 expected, got 9")
			expectFail(T.integerMin(10)(10.5))("integer expected, got 10.5")

			expectPass(T.integerMax(10)(10))
			expectFail(T.integerMax(10)(11))("integer <= 10 expected, got 11")

			expectPass(T.integerConstrained(10, 20)(15))
			expectFail(T.integerConstrained(10, 20)(25))("integer <= 20 expected, got 25")

			expectPass(T.integerConstrainedExclusive(10, 20)(15))
			expectFail(T.integerConstrainedExclusive(10, 20)(10))("integer > 10 expected, got 10")

			expectPass(T.integerPositive(1))
			expectPass(T.integerNegative(-1))
		end)

		test("match validates strings against patterns", function()
			local slug = T.match("^[a-z]+%-%d+$")
			expectPass(slug("entry-42"))
			expectFail(slug("Entry42"))('"Entry42" failed to match pattern "^[a-z]+%-%d+$"')
		end)
	end)

	describe("Composition", function()
		test("optional and tuple compose validators", function()
			local optionalString = T.optional(T.string)
			expectPass(optionalString(nil))
			expectPass(optionalString("value"))
			expectFail(optionalString(5))("(optional) string expected, got number")

			local tupleCheck = T.tuple(T.string, T.number)
			expectPass(tupleCheck("score", 50))
			expectFail(tupleCheck("score", "oops"))("Bad tuple index #2:\n\tnumber expected, got string")

			-- Edge behavior: tuple validates declared positions and allows extra arguments.
			local singleValueTuple = T.tuple(T.string)
			expectPass(singleValueTuple("hello"))
			expectPass(singleValueTuple("hello", 123))

			local strictTupleCheck = T.strictTuple(T.string, T.number)
			expectPass(strictTupleCheck("score", 50))
			expectFail(strictTupleCheck("score"))("Bad tuple index #2:\n\tnumber expected, got nil")
			expectFail(strictTupleCheck("score", 50, true))("Bad tuple length: expected 2 arguments, got 3")
		end)

		test("where refines a validator with custom predicates", function()
			local nonEmptyString = T.where(T.string, function(value: any)
				return #value > 0, "string must not be empty"
			end)
			expectPass(nonEmptyString("hello"))
			expectFail(nonEmptyString(""))("string must not be empty")
			expectFail(nonEmptyString(10))("string expected, got number")
			local evenNumber = T.where(T.number, function(value: any)
				return value % 2 == 0, "number must be even"
			end)
			expectPass(evenNumber(12))
			expectFail(evenNumber(11))("number must be even")

			local positiveNumber = T.where(T.number, function(value: any)
				return value > 0, "number must be positive"
			end)
			expectFail(positiveNumber(-3))("number must be positive")

			-- Deprecated due to Luau being unable to properly type this.
			-- local explicitPredicateMessage = T.where(T.number, function(value)
			-- 	if value > 0 then
			-- 		return true :: any
			-- 	end
			-- 	return false, "predicate message wins"
			-- end, "fallback message")
			-- expectFail(explicitPredicateMessage(-1)("predicate message wins")
		end)

		test("keys, values, map, and set validate table shapes", function()
			expectPass(T.keys(T.string) { a = 1, b = 2 })
			expectFail(T.keys(T.string) { [1] = true })("bad key 1:\n\tstring expected, got number")

			local stringValues = T.values(T.string)
			expectPass(stringValues { a = "x", b = "y" })
			expectFail(stringValues { a = 1 })("bad value for key a:\n\tstring expected, got number")

			local scoreMap = T.map(T.string, T.number)
			expectPass(scoreMap { Alpha = 10, Beta = 20 })
			expectFail(scoreMap { Alpha = "oops" })("bad value for key Alpha:\n\tnumber expected, got string")

			local tags = T.set(T.string)
			expectPass(tags { fast = true, active = true })
			expectFail(tags { fast = false })("bad value for key fast:\n\texpected true, got false")

			local taggedSet = T.set(T.literal("red", "green", 5))
			expectPass(taggedSet { red = true, green = true })
		end)

		test("array and strictArray validate ordered collections", function()
			local stringArray = T.array(T.string)
			expectPass(stringArray { "a", "b", "c" })
			expectFail(stringArray { [1] = "a", [3] = "c" })("[array] key 3 must be sequential")

			local strict = T.strictArray(T.string, T.number, T.boolean)
			expectPass(strict { "item", 1, true })
			expectFail(strict { "item", 1, true, "extra" })("[strictArray] Array size exceeds limit of 3")
			expectFail(strict { "item", "wrong" })("[strictArray] Array index #2 - number expected, got string")

			local strictPair = T.strictArray(T.string, T.number)
			expectFail(strictPair { "name" })("[strictArray] Array index #2 - number expected, got nil")
		end)

		test("union and intersection combine validators", function()
			local stringOrNumber = T.union(T.string, T.number)
			expectPass(stringOrNumber("ready"))
			expectPass(stringOrNumber(10))
			expectFail(stringOrNumber(true))(
				"bad type for union:\n\t[1] string expected, got boolean\n\t[2] number expected, got boolean"
			)

			local positiveInt = T.intersection(T.integer, T.numberPositive)
			expectPass(positiveInt(5))
			expectFail(positiveInt(-1))("number > 0 expected, got -1")
		end)

		test("interface and strictInterface validate table contracts", function()
			local playerCheck = T.interface {
				Name = T.string,
				Health = T.numberConstrained(0, 100),
			}
			expectPass(playerCheck {
				Name = "Builderman",
				Health = 100,
				Team = "Red",
			})
			expectFail(playerCheck { Name = "Builderman", Health = 150 })(
				"[interface] bad value for Health:\n\tnumber <= 100 expected, got 150"
			)

			local exactPlayerCheck = T.strictInterface {
				Name = T.string,
				Health = T.number,
			}
			expectPass(exactPlayerCheck { Name = "Builderman", Health = 50 })
			expectFail(exactPlayerCheck { Name = "Builderman", Health = 50, Team = "Red" })(
				'[interface] unexpected field "Team"'
			)
		end)

		test("interfaces support non-string keys", function()
			local key = {}
			local myInterface = T.interface { [key] = T.number }
			expectPass(myInterface { [key] = 1 })
			expectFail(myInterface { [key] = "1" })("[interface] bad value for <table>:\n\tnumber expected, got string")
		end)

		test("strict interfaces reject non-string keys", function()
			local myInterface = T.strictInterface { a = T.number }
			expectFail(myInterface { a = 1, [{}] = 2 })("[interface] unexpected field")
		end)

		test("partialInterface validates known fields only when present", function()
			local playerPatchCheck = T.partialInterface {
				Name = T.string,
				Health = T.numberConstrained(0, 100),
			}

			expectPass(playerPatchCheck {})
			expectPass(playerPatchCheck { Name = "Builderman" })
			expectPass(playerPatchCheck { Team = "Red" })
			expectPass(playerPatchCheck { Name = "Builderman", Health = 75 })
			expectFail(playerPatchCheck { Health = 150 })(
				"[partialInterface] bad value for Health:\n\tnumber <= 100 expected, got 150"
			)

			expectPass(playerPatchCheck { Name = nil })
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

			expectPass(profileCheck {
				Name = "Builderman",
				Level = 10,
				Items = {
					{ Id = 1, Tags = { "starter" }, Meta = { Rarity = "Common", Weight = 2 } },
				},
				Flags = { Active = true },
			})

			expectFail(profileCheck {
				Name = "Builderman",
				Level = 0,
				Items = {},
				Flags = {},
			})("[interface] bad value for Level:\n\tinteger >= 1 expected, got 0")

			expectFail(profileCheck {
				Name = "Builderman",
				Level = 10,
				Items = {},
				Flags = {},
				Unexpected = true,
			})('[interface] unexpected field "Unexpected"')
		end)

		test("complex union failures include branch details", function()
			local payloadCheck = T.interface {
				Mode = T.union(T.literal("A"), T.integerPositive),
			}

			expectFail(payloadCheck { Mode = false })(
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
			expectPass(materialCheck(item))
			expectFail(materialCheck(Enum.KeyCode.A))("enum of Material expected, got enum of KeyCode")
		end)

		test("RBXScriptSignal validates signal objects when available", function()
			local ok = pcall(function()
				return game.ChildAdded
			end)
			if not ok then
				expect(true).is(true)
				return
			end

			expectPass(T.RBXScriptSignal(game.ChildAdded))
			expectFail(T.RBXScriptSignal(nil))("RBXScriptSignal expected, got nil")

			-- Try with a Vector3 to ensure type checking works
			local hasVector3 = pcall(function()
				return Vector3.new()
			end)
			if hasVector3 then
				expectFail(T.RBXScriptSignal(Vector3.new()))("RBXScriptSignal expected, got Vector3")
			end
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

			expectPass(T.instanceOf("Folder")(folder))
			expectFail(T.instanceOf("Part")(folder))("Part expected, got Folder")

			expectPass(T.instanceIsA("Instance")(folder))

			local childrenCheck = T.children {
				Config = T.instanceOf("StringValue"),
			}
			expectPass(childrenCheck(folder))

			folder:SetAttribute("Enabled", true)
			value:SetAttribute("Loaded", true)

			expectPass(T.attributes { Enabled = T.boolean }(folder))
			expectPass(T.properties { Name = T.string }(folder))

			local richChildrenCheck = T.intersection(
				T.instanceOf("Folder"),
				T.attributes { Enabled = T.boolean },
				T.properties { Name = T.string },
				T.children {
					Config = T.intersection(
						T.instanceOf("StringValue"),
						T.attributes { Loaded = T.boolean },
						T.properties { Name = T.string }
					),
				}
			)
			expectPass(richChildrenCheck(folder))

			expectFail(T.attributes { Missing = T.boolean }(folder))(
				'[attributes] bad value for "Missing":\n\tboolean expected, got nil'
			)

			local extra = Instance.new("Folder")
			extra.Name = "Config"
			extra.Parent = folder
			expectFail(childrenCheck(folder))('Cannot process multiple children with the same name "Config"')
		end)

		test("attributes and properties support composed validators", function()
			local ok, folder = pcall(function()
				return Instance.new("Folder")
			end)
			if not ok then
				expect(true).is(true)
				return
			end

			folder.Name = "InventoryRoot"
			folder.Archivable = true
			folder:SetAttribute("Mode", "Auto")
			folder:SetAttribute("Health", 80)
			folder:SetAttribute("Enabled", true)

			local config = Instance.new("StringValue")
			config.Name = "ConfigState"
			config.Value = "Ready"
			config.Parent = folder

			local attributeCheck = T.attributes {
				Mode = T.anyOf(T.literal("Auto"), T.literal("Manual")),
				Health = T.allOf(T.integer, T.integerConstrained(0, 100)),
				Enabled = T.boolean,
			}
			expectPass(attributeCheck(folder))

			local propertyCheck = T.properties {
				Name = T.match("^Inventory"),
				Archivable = T.boolean,
			}
			expectPass(propertyCheck(folder))

			local nestedPropertyCheck = T.properties {
				Name = T.match("^Config"),
				Value = T.anyOf(T.literal("Ready"), T.literal("Idle")),
				Parent = T.instanceOf("Folder"),
			}
			expectPass(nestedPropertyCheck(config))

			folder:SetAttribute("Health", 150)
			expectFail(attributeCheck(folder))(
				'[attributes] bad value for "Health":\n\tinteger <= 100 expected, got 150'
			)
			folder:SetAttribute("Health", 80)

			config.Value = "Broken"
			expectFail(nestedPropertyCheck(config))(
				'[properties] bad value for "Value":\n\tbad type for union:\n\t[1] expected Ready, got Broken\n\t[2] expected Idle, got Broken'
			)

			expectFail(T.properties { MissingProperty = T.string }(folder))(
				'[properties] could not read property "MissingProperty"'
			)
		end)

		test("anyOf and allOf alias union and intersection behavior", function()
			local stringOrNumber = T.anyOf(T.string, T.number)
			expectPass(stringOrNumber("hello"))
			expectPass(stringOrNumber(5))
			expectFail(stringOrNumber(true))(
				"bad type for union:\n\t[1] string expected, got boolean\n\t[2] number expected, got boolean"
			)

			local positiveInteger = T.allOf(T.integer, T.numberPositive)
			expectPass(positiveInteger(4))
			expectFail(positiveInteger(-1))("number > 0 expected, got -1")
		end)
	end)

	describe("Function Helpers", function()
		test("wrap enforces argument validation", function()
			local wrapped = T.wrap(function(a: any, b: any)
				return a + b
			end, T.tuple(T.number, T.number))

			expect(wrapped(2, 3)).is(5)

			local ok, err = pcall(function()
				wrapped("2", 3) -- This type error is expected to be caught by the wrapper
			end)
			expect(ok).is(false)
			expect(type(err)).is("string")
		end)

		test("wrapArgs composes variadic checks into tuple validation", function()
			local wrapped = T.wrapArgs(function(a: any, b: any)
				return a + b
			end, T.number, T.number)

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

		test("custom OOP class type checking pattern", function()
			local MyClass = {}
			MyClass.__index = MyClass

			function MyClass.new()
				local self = setmetatable({}, MyClass)
				return self
			end

			-- Create a custom type checker for the class
			local function instanceOfClass(class)
				return function(value: unknown)
					local tableSuccess, tableErrMsg = T.table(value)
					if not tableSuccess then
						return false, tableErrMsg or ""
					end

					assert(type(value) == "table", "value must be a table")

					local mt = getmetatable(value)
					if not mt or mt.__index ~= class then
						return false, "bad member of class"
					end

					return true :: any
				end
			end

			local instanceOfMyClass = instanceOfClass(MyClass)
			local myObject = MyClass.new()

			expectPass(instanceOfMyClass(myObject))
			expectFail(instanceOfMyClass {})("bad member of class")
			expectFail(instanceOfMyClass(nil))("table expected, got nil")
		end)
	end)
end
