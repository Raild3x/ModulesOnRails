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

	-- In-repo siblings ([custom] siblings): materialize must copy each sibling's CURRENT src
	-- over the vendored copy on every run, so tests never see a stale sibling (F10(b)).
	describe("modules_on_rails.materialize sibling freshness", function()
		local fs = require("@lune/fs")
		local SANDBOX = ".coverage/adapter-spec-siblings"

		local function write(path: string, contents: string)
			local dir = path:match("^(.*)/[^/]+$") :: string
			fs.writeDir(dir)
			fs.writeFile(path, contents)
		end

		local function setUp(vendored: boolean)
			if fs.isDir(SANDBOX) then
				fs.removeDir(SANDBOX)
			end
			write(`{SANDBOX}/lib/dep/wally.toml`, '[package]\nname = "x/dep"\n\n[custom]\nsiblings = "sib"\n')
			write(`{SANDBOX}/lib/dep/src/Dep.luau`, "return 1\n")
			write(`{SANDBOX}/lib/sib/wally.toml`, '[package]\nname = "x/sib"\n')
			write(`{SANDBOX}/lib/sib/src/Current.luau`, "return 'current'\n")
			if vendored then
				-- a stale vendored copy, as setup left it before the sibling was edited
				write(`{SANDBOX}/lib/dep/_Index/raild3x_sib@local/sib/src/Stale.luau`, "return 'stale'\n")
			end
		end

		test("the build copy holds the sibling's current src, not the stale vendored one", function()
			setUp(true)
			local build = `{SANDBOX}/build`
			modules_on_rails.materialize({ root = `{SANDBOX}/lib/dep` } :: any, build)
			local copied = `{build}/_Index/raild3x_sib@local/sib/src`
			expect(fs.isFile(`{copied}/Current.luau`)).is_true()
			expect(fs.isFile(`{copied}/Stale.luau`)).never_is_true()
			fs.removeDir(SANDBOX)
		end)

		test("a sibling that was never vendored is a loud error (negative control)", function()
			setUp(false)
			expect(function()
				modules_on_rails.materialize({ root = `{SANDBOX}/lib/dep` } :: any, `{SANDBOX}/build`)
			end).fails()
			fs.removeDir(SANDBOX)
		end)
	end)
end
