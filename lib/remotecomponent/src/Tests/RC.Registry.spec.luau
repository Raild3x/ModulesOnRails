--!strict
--[[
	Coverage for the addRemotes registration API: validation, exposed-remote
	collisions, and the registration window (sealed once Starting runs). Drives the
	extension hooks directly on fake component tables (no real Component package in
	CI). These paths need no Comm/network, so they run without building remotes;
	the real server build lives in RC.ServerBuild.spec.
]]

return function(t: tiniest)
	local RemoteComponent = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local function fakeComponent(): any
		return { Instance = Instance.new("Folder"), Tag = "RCSpec_Registry" }
	end

	local function noop() end

	describe("addRemotes validation", function()
		test("empty or delimiter-containing namespace fails", function()
			local c = fakeComponent()
			expect(function()
				RemoteComponent.addRemotes(c, "", { A = noop })
			end).fails()
			expect(function()
				RemoteComponent.addRemotes(c, "Bad/Ns", { A = noop })
			end).fails_with("may not contain")
		end)

		test("duplicate namespace fails", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "Ns", { A = noop })
			expect(function()
				RemoteComponent.addRemotes(c, "Ns", { B = noop })
			end).fails_with("already registered")
		end)

		test("a remote key containing the delimiter fails", function()
			local c = fakeComponent()
			expect(function()
				RemoteComponent.addRemotes(c, "Ns", { ["a/b"] = noop })
			end).fails_with("may not contain")
		end)

		test("the reserved 'Server' key fails", function()
			local c = fakeComponent()
			expect(function()
				RemoteComponent.addRemotes(c, "Ns", { Server = noop })
			end).fails_with("reserved")
		end)

		test("a non-function, non-marker value fails", function()
			local c = fakeComponent()
			expect(function()
				RemoteComponent.addRemotes(c, "Ns", { A = 5 })
			end).fails_with("function or a marker")
		end)
	end)

	describe("exposed collisions", function()
		test("an exposed remote colliding with a Client key fails", function()
			local c = fakeComponent()
			c.Client = { Existing = noop }
			expect(function()
				RemoteComponent.addRemotes(c, "Ns", { Existing = noop }, { exposed = true })
			end).fails_with("Client")
		end)

		test("two exposed namespaces sharing a key fail, naming both", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "A", { Shared = noop }, { exposed = true })
			expect(function()
				RemoteComponent.addRemotes(c, "B", { Shared = noop }, { exposed = true })
			end).fails_with("'A'")
		end)

		test("the same key under two internal namespaces is fine", function()
			local c = fakeComponent()
			expect(function()
				RemoteComponent.addRemotes(c, "A", { Shoot = noop })
				RemoteComponent.addRemotes(c, "B", { Shoot = noop })
			end).never_fails()
		end)
	end)

	describe("registration window", function()
		test("registering after Starting seals the registry fails, even with no prior registrations", function()
			local c = fakeComponent()
			-- No Client, no registrations: Starting warns, builds nothing, but still seals.
			RemoteComponent.Starting(c)
			expect(function()
				RemoteComponent.addRemotes(c, "TooLate", { A = noop })
			end).fails_with("already built")
		end)
	end)
end
