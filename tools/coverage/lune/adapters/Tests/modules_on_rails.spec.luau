local modules_on_rails = require("../modules_on_rails")

-- robloxScaffold only reads `spec.name`; the rest is inert for this check.
local function fakeSpec(): any
	return { name = "tablemanager" }
end

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("modules_on_rails.robloxScaffold per-test gating", function()
		-- Per-test attribution multiplies the Studio payload by the test count, and
		-- run-in-roblox caps the stdout post it ships back (~1 MB). Emitting it
		-- unconditionally silently dropped the whole payload for large suites
		-- ("no coverage output captured"). The runner must only turn it on when the
		-- caller asked for it.
		test("defaults to enable_per_test = false when no run options are given", function()
			local scaffold = modules_on_rails.robloxScaffold(fakeSpec(), "build")
			expect(scaffold.runnerSource:find("enable_per_test = false", 1, true)).exists()
			expect(scaffold.runnerSource:find("enable_per_test = true", 1, true)).never_exists()
		end)

		test("defaults to false when perTest is omitted from run options", function()
			local scaffold = modules_on_rails.robloxScaffold(fakeSpec(), "build", {})
			expect(scaffold.runnerSource:find("enable_per_test = false", 1, true)).exists()
		end)

		test("emits enable_per_test = true only when perTest is requested", function()
			local scaffold = modules_on_rails.robloxScaffold(fakeSpec(), "build", { perTest = true })
			expect(scaffold.runnerSource:find("enable_per_test = true", 1, true)).exists()
			expect(scaffold.runnerSource:find("enable_per_test = false", 1, true)).never_exists()
		end)

		test("leaves no unsubstituted placeholder in the generated runner", function()
			local scaffold = modules_on_rails.robloxScaffold(fakeSpec(), "build", { perTest = false })
			expect(scaffold.runnerSource:find("__PER_TEST__", 1, true)).never_exists()
			expect(scaffold.runnerSource:find("__PKG__", 1, true)).never_exists()
		end)
	end)
end
