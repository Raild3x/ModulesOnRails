--!strict
--[[
	Unit tests for PathHelpers — the pure, stateless path utilities used across
	TableManager. Covers parsing/caching, equality, prefix checks, string
	rendering, parent/key extraction, append, resolution, and array
	classification (including the edge branches unreached by the integration
	suites).
]]

return function(t: tiniest)
	local PathHelpers = require("../PathHelpers")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("ParsePath", function()
		test("returns a table path unchanged", function()
			local path = { "player", "level" }
			expect(PathHelpers.ParsePath(path)).is(path)
		end)

		test("splits a dotted string into segments", function()
			local parsed = PathHelpers.ParsePath("player.stats.health")
			expect(#parsed).is(3)
			expect(parsed[1]).is("player")
			expect(parsed[2]).is("stats")
			expect(parsed[3]).is("health")
		end)

		test("caches and returns the same frozen array for a repeated string", function()
			local first = PathHelpers.ParsePath("a.b.c")
			local second = PathHelpers.ParsePath("a.b.c")
			expect(first).is(second)
			expect(table.isfrozen(first :: any)).is_true()
		end)

		test("a single segment string yields a one-element path", function()
			local parsed = PathHelpers.ParsePath("solo")
			expect(#parsed).is(1)
			expect(parsed[1]).is("solo")
		end)
	end)

	describe("ArePathsEqual", function()
		test("identical references are equal (fast path)", function()
			local path = { "a", "b" }
			expect(PathHelpers.ArePathsEqual(path, path)).is_true()
		end)

		test("equal string paths compare equal", function()
			expect(PathHelpers.ArePathsEqual("a.b.c", "a.b.c")).is_true()
		end)

		test("equal array paths of the same length compare equal", function()
			expect(PathHelpers.ArePathsEqual({ "a", 1, true }, { "a", 1, true })).is_true()
		end)

		test("different lengths are not equal", function()
			expect(PathHelpers.ArePathsEqual({ "a" }, { "a", "b" })).is(false)
		end)

		test("same length, differing segment is not equal", function()
			expect(PathHelpers.ArePathsEqual({ "a", "b" }, { "a", "c" })).is(false)
		end)
	end)

	describe("PathToString", function()
		test("empty path renders as <root>", function()
			expect(PathHelpers.PathToString({})).is("<root>")
		end)

		test("single segment renders without a separator", function()
			expect(PathHelpers.PathToString({ "player" })).is("player")
		end)

		test("multi-segment path is dot-joined", function()
			expect(PathHelpers.PathToString({ "player", "stats", "health" })).is("player.stats.health")
		end)

		test("non-string segments are stringified", function()
			expect(PathHelpers.PathToString({ "items", 3, true })).is("items.3.true")
		end)
	end)

	describe("IsPrefixPath", function()
		test("a shorter matching prefix returns true", function()
			expect(PathHelpers.IsPrefixPath({ "a", "b" }, { "a", "b", "c" })).is_true()
		end)

		test("an equal path is its own prefix", function()
			expect(PathHelpers.IsPrefixPath({ "a", "b" }, { "a", "b" })).is_true()
		end)

		test("the empty path is a prefix of everything", function()
			expect(PathHelpers.IsPrefixPath({}, { "a" })).is_true()
		end)

		test("a longer candidate is never a prefix", function()
			expect(PathHelpers.IsPrefixPath({ "a", "b", "c" }, { "a", "b" })).is(false)
		end)

		test("a diverging segment breaks the prefix", function()
			expect(PathHelpers.IsPrefixPath({ "a", "x" }, { "a", "b", "c" })).is(false)
		end)
	end)

	describe("GetPathParentAndKey", function()
		test("splits the last segment off as the key", function()
			local parent, key = PathHelpers.GetPathParentAndKey({ "player", "stats", "health" })
			expect(#parent).is(2)
			expect(parent[1]).is("player")
			expect(parent[2]).is("stats")
			expect(key).is("health")
		end)

		test("a single-segment path yields an empty parent", function()
			local parent, key = PathHelpers.GetPathParentAndKey({ "root" })
			expect(#parent).is(0)
			expect(key).is("root")
		end)

		test("does not mutate the input path", function()
			local input = { "a", "b" }
			PathHelpers.GetPathParentAndKey(input)
			expect(#input).is(2)
		end)

		test("asserts on an empty path", function()
			expect(function()
				PathHelpers.GetPathParentAndKey({})
			end).fails()
		end)
	end)

	describe("Append", function()
		test("returns a new path with the key appended", function()
			local base = { "a", "b" }
			local result = PathHelpers.Append(base, "c")
			expect(#result).is(3)
			expect(result[3]).is("c")
		end)

		test("does not mutate the base path", function()
			local base = { "a" }
			PathHelpers.Append(base, "b")
			expect(#base).is(1)
		end)

		test("appends onto an empty path", function()
			local result = PathHelpers.Append({}, "only")
			expect(#result).is(1)
			expect(result[1]).is("only")
		end)
	end)

	describe("ResolveAtPath", function()
		test("walks nested tables to the leaf value", function()
			local root = { player = { stats = { health = 42 } } }
			expect(PathHelpers.ResolveAtPath(root, { "player", "stats", "health" })).is(42)
		end)

		test("an empty path resolves to the root itself", function()
			local root = { x = 1 }
			expect(PathHelpers.ResolveAtPath(root, {})).is(root)
		end)

		test("returns nil when an intermediate segment is not a table", function()
			local root = { player = 5 }
			expect(PathHelpers.ResolveAtPath(root, { "player", "health" })).is(nil)
		end)

		test("returns nil for a missing key", function()
			local root = { player = {} }
			expect(PathHelpers.ResolveAtPath(root, { "player", "missing" })).is(nil)
		end)
	end)

	describe("ClassifyArray", function()
		test("a dense array reports its length", function()
			local isArray, length = PathHelpers.ClassifyArray({ "a", "b", "c" })
			expect(isArray).is_true()
			expect(length).is(3)
		end)

		test("an empty table is a length-0 array", function()
			local isArray, length = PathHelpers.ClassifyArray({})
			expect(isArray).is_true()
			expect(length).is(0)
		end)

		test("a map with string keys is not an array", function()
			local isArray, length = PathHelpers.ClassifyArray({ a = 1 })
			expect(isArray).is(false)
			expect(length).is(0)
		end)

		test("a sparse array (gap) is not an array", function()
			local isArray = PathHelpers.ClassifyArray({ [1] = "a", [3] = "c" })
			expect(isArray).is(false)
		end)

		test("a non-integer numeric key is not an array", function()
			local isArray = PathHelpers.ClassifyArray({ [1.5] = "x" })
			expect(isArray).is(false)
		end)

		test("a zero/negative index is not an array", function()
			local isArray = PathHelpers.ClassifyArray({ [0] = "x" })
			expect(isArray).is(false)
		end)

		test("a non-table argument returns false", function()
			local isArray, length = PathHelpers.ClassifyArray(42 :: any)
			expect(isArray).is(false)
			expect(length).is(0)
		end)
	end)
end
