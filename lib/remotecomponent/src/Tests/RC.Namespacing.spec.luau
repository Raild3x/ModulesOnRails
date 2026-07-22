--!strict
--[[
	Pure unit coverage for the Namespacing helpers. These back the client-side
	reconstruction of extension remotes (which has no registration data and must
	recover structure from the flat built object's names alone). There is no real
	client in the Open Cloud CI server context, so this is the ONLY place the
	client-side split logic is exercised.
]]

return function(t: tiniest)
	local Namespacing = require("../Namespacing")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("join / isNamespaced", function()
		test("join prefixes with the delimiter and isNamespaced detects it", function()
			expect(Namespacing.join("MyExt", "Shoot")).is("MyExt/Shoot")
			expect(Namespacing.isNamespaced("MyExt/Shoot")).is(true)
			expect(Namespacing.isNamespaced("Shoot")).is(false)
		end)
	end)

	describe("splitBuiltObject", function()
		test("flat entries stay flat, prefixed entries nest under their namespace", function()
			local flat, byNamespace = Namespacing.splitBuiltObject {
				AuthorMethod = "a",
				["MyExt/Event"] = "b",
				["MyExt/Prop"] = "c",
				["Other/Thing"] = "d",
			}
			expect(flat.AuthorMethod).is("a")
			expect(flat["MyExt/Event"]).never_exists()
			expect(byNamespace.MyExt.Event).is("b")
			expect(byNamespace.MyExt.Prop).is("c")
			expect(byNamespace.Other.Thing).is("d")
		end)

		test("splits at the first delimiter only", function()
			local _, byNamespace = Namespacing.splitBuiltObject { ["Ns/deep/key"] = "v" }
			expect(byNamespace.Ns["deep/key"]).is("v")
		end)

		test("an empty object yields two empty tables", function()
			local flat, byNamespace = Namespacing.splitBuiltObject {}
			expect((next(flat))).never_exists()
			expect((next(byNamespace))).never_exists()
		end)

		test("does not mutate the input", function()
			local input = { A = "1", ["Ns/B"] = "2" }
			Namespacing.splitBuiltObject(input)
			expect(input.A).is("1")
			expect(input["Ns/B"]).is("2")
			local count = 0
			for _ in input do
				count += 1
			end
			expect(count).is(2)
		end)
	end)
end
