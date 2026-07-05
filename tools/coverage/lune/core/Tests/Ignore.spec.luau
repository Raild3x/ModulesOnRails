local Ignore = require("../Ignore")

-- The runner executes from the repo root, so fixture paths are repo-relative.
local FIXTURE_DIR = "tools/coverage/lune/core/Tests/fixtures/ignore"
local IGNORE_FILES = { ".coverage-ignore", ".covaudit-ignore" }

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Ignore.empty", function()
		test("is empty and matches nothing", function()
			local rules = Ignore.empty()
			expect(rules.isEmpty).is_true()
			local probe = { site = "stmt:src/a.luau:3:1", line = 3, kind = "stmt" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).never_exists()
		end)
	end)

	describe("Ignore.load", function()
		test("parses bare, quoted and padded names", function()
			local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)
			expect(rules.isEmpty).never_is_true()
			expect(rules.names["M.doThing"]).is_true()
			expect(rules.names["Quoted.Name"]).is_true()
			expect(rules.names["Single.Name"]).is_true()
			expect(rules.names["Padded.Name"]).is_true()
		end)

		test("parses file-line and site rules", function()
			local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)
			expect(rules.fileLines["src/a.luau:12"]).is_true()
			expect(rules.sites["stmt:src/a.luau:3:1"]).is_true()
		end)

		test("a whitespace-only line creates no rule", function()
			local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)
			expect(rules.names[""]).never_exists()
			expect(rules.fileLines[""]).never_exists()
			expect(rules.sites[""]).never_exists()
		end)

		test("skips comment lines", function()
			local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)
			for name in rules.names do
				expect(name:sub(1, 1) == "#").never_is_true()
				expect(name:sub(1, 2) == "--").never_is_true()
			end
		end)

		test("unions rules from every ignore file", function()
			local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)
			expect(rules.names["Legacy.Fn"]).is_true()
		end)

		test("tolerates a missing ignore file", function()
			local rules = Ignore.load(FIXTURE_DIR, { "no-such-file" })
			expect(rules.isEmpty).is_true()
		end)
	end)

	describe("Ignore.matchDirect", function()
		local rules = Ignore.load(FIXTURE_DIR, IGNORE_FILES)

		test("matches an exact site key", function()
			local probe = { site = "stmt:src/a.luau:3:1", line = 3, kind = "stmt" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).is("site rule")
		end)

		test("matches a file-line rule", function()
			local probe = { site = "stmt:src/a.luau:12:2", line = 12, kind = "stmt" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).is("line rule")
		end)

		test("matches fn probes by qualified name", function()
			local probe = { site = "fn:src/a.luau:5:1", line = 5, kind = "fn", name = "M.doThing" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).is("name rule")
		end)

		test("site rules win over line and name rules", function()
			local probe = { site = "stmt:src/a.luau:3:1", line = 12, kind = "fn", name = "M.doThing" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).is("site rule")
		end)

		test("line rules win over name rules", function()
			local probe = { site = "fn:src/a.luau:12:1", line = 12, kind = "fn", name = "M.doThing" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).is("line rule")
		end)

		test("name rules only match fn probes", function()
			local probe = { site = "stmt:src/a.luau:6:2", line = 6, kind = "stmt", name = "M.doThing" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).never_exists()
		end)

		test("name rules never match anonymous fn probes", function()
			local probe = { site = "fn:src/a.luau:9:1", line = 9, kind = "fn" }
			expect(Ignore.matchDirect(rules, "src/a.luau", probe)).never_exists()
		end)

		test("does not match on the wrong file for a line rule", function()
			local probe = { site = "stmt:src/b.luau:12:2", line = 12, kind = "stmt" }
			expect(Ignore.matchDirect(rules, "src/b.luau", probe)).never_exists()
		end)
	end)
end
