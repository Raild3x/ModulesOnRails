--!strict
--[[
	Server-side build coverage: real Comm folders / RemoteFunctions / RemoteEvents
	/ RemoteProperties on real (detached) Instances, driven by calling the extension
	hooks directly on fake component tables. Runs in the Open Cloud server context.

	No real client exists in CI, so the client-side reconstruction is not exercised
	here — see RC.Namespacing.spec for the pure split logic that backs it.
]]

return function(t: tiniest)
	local RemoteComponent = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local suffix = 0
	local function fakeComponent(): any
		suffix += 1
		return { Instance = Instance.new("Folder"), Tag = "RCSpec_Build_" .. suffix }
	end

	local function noop() end

	local function namespaceFolder(c: any): Instance?
		local name = c.RemoteNamespace or c.Tag .. "_RemoteComponent"
		return c.Instance:FindFirstChild(name)
	end

	local function childCount(folder: Instance?, sub: string): number
		if not folder then
			return 0
		end
		local f = folder:FindFirstChild(sub)
		return if f then #f:GetChildren() else 0
	end

	describe("folder and handshake", function()
		test("builds one namespace folder with prefixed internal + flat author/exposed remotes", function()
			local c = fakeComponent()
			c.Client = { AuthorMethod = noop, AuthorEvt = RemoteComponent.createEvent() }
			RemoteComponent.addRemotes(c, "MyExt", { Shoot = noop, Ammo = RemoteComponent.createProperty(10) })
			RemoteComponent.addRemotes(c, "Buffs", { ApplyBuff = noop }, { exposed = true })

			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)

			local folder = namespaceFolder(c)
			expect(folder).exists()

			local rf = (folder :: any):FindFirstChild("RF")
			local re = (folder :: any):FindFirstChild("RE")
			local rp = (folder :: any):FindFirstChild("RP")
			-- Flat author + exposed methods and the prefixed internal method.
			expect((rf :: any):FindFirstChild("AuthorMethod")).exists()
			expect((rf :: any):FindFirstChild("ApplyBuff")).exists()
			expect((rf :: any):FindFirstChild("MyExt/Shoot")).exists()
			expect((re :: any):FindFirstChild("AuthorEvt")).exists()
			expect((rp :: any):FindFirstChild("MyExt/Ammo")).exists()

			-- SRC and the physical child count agree (the client handshake relies on it):
			-- 3 flat (AuthorMethod, AuthorEvt, ApplyBuff) + 2 internal (Shoot, Ammo).
			local src = (folder :: any):GetAttribute("SRC")
			expect(src).is(5)
			expect(childCount(folder, "RF") + childCount(folder, "RE") + childCount(folder, "RP")).is(src)
		end)

		test("honors a RemoteNamespace override", function()
			local c = fakeComponent()
			c.RemoteNamespace = "CustomNS_" .. suffix
			c.Client = { M = noop }
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(c.Instance:FindFirstChild(c.RemoteNamespace)).exists()
		end)
	end)

	describe("getRemotes", function()
		test("returns the internal sub-object with a .Server backref, excluding exposed remotes", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "MyExt", { Shoot = noop, Ammo = RemoteComponent.createProperty(0) })
			RemoteComponent.addRemotes(c, "Buffs", { ApplyBuff = noop }, { exposed = true })
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)

			local remotes = RemoteComponent.getRemotes(c, "MyExt")
			expect(remotes.Server).is(c)
			expect(remotes.Shoot).is(noop) -- functions are kept raw in the sub-object
			expect(remotes.Ammo).is_a("table") -- marker became a RemoteProperty object

			-- Exposed remotes live flat on Client, not under getRemotes.
			expect(c.Client.ApplyBuff).is(noop)
			expect(function()
				RemoteComponent.getRemotes(c, "Buffs")
			end).fails()
		end)

		test("getRemotes before Starting and for an unknown namespace fail", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "MyExt", { Shoot = noop })
			expect(function()
				RemoteComponent.getRemotes(c, "MyExt")
			end).fails_with("not been built")

			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(function()
				RemoteComponent.getRemotes(c, "Nonexistent")
			end).fails_with("no internal remotes")
		end)
	end)

	describe("Client-table behavior", function()
		test("registrations with no Client table still build a folder", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "MyExt", { Shoot = noop })
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(namespaceFolder(c)).exists()
			expect((namespaceFolder(c) :: any):GetAttribute("SRC")).is(1)
		end)

		test("no Client and no registrations builds nothing (back-compat)", function()
			local c = fakeComponent()
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(namespaceFolder(c)).never_exists()
		end)

		test("an author-only component builds exactly its own remotes (back-compat)", function()
			local c = fakeComponent()
			c.Client = { A = noop, B = noop }
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect((namespaceFolder(c) :: any):GetAttribute("SRC")).is(2)
		end)

		test("an author Client key containing the delimiter fails", function()
			local c = fakeComponent()
			c.Client = { ["a/b"] = noop }
			RemoteComponent.Constructing(c)
			expect(function()
				RemoteComponent.Starting(c)
			end).fails_with("may not contain")
		end)
	end)

	describe("teardown and immutability", function()
		test("Stopping destroys the namespace folder", function()
			local c = fakeComponent()
			RemoteComponent.addRemotes(c, "MyExt", { Ammo = RemoteComponent.createProperty(0) })
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(namespaceFolder(c)).exists()
			RemoteComponent.Stopping(c)
			expect(namespaceFolder(c)).never_exists()
		end)

		test("Starting does not mutate the registered defs table", function()
			local c = fakeComponent()
			local marker = RemoteComponent.createProperty(0)
			local defs = { Shoot = noop, Ammo = marker }
			RemoteComponent.addRemotes(c, "MyExt", defs)
			RemoteComponent.Constructing(c)
			RemoteComponent.Starting(c)
			expect(defs.Shoot).is(noop)
			expect(defs.Ammo).is(marker)
		end)
	end)
end
