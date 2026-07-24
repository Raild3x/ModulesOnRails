--!nonstrict
--[[
	Config `Methods` / `Fields` / `InitFields`: methods are bound onto the class
	before setup (collisions fail loudly), fields are copied onto every component
	instance before it constructs.
]]

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("Component.new with a Methods table", function()
		test("methods are bound and callable, including lifecycle overrides", function()
			local constructed = false
			local class = Component.new {
				Tag = H.uniqueTag(),
				Ancestors = { workspace },
				Methods = {
					Construct = function()
						constructed = true
					end,
					Greet = function(_self, msg: string)
						return "hello " .. msg
					end,
				},
			}
			local part = H.taggedPart(class.Tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(constructed).is(true)
			local comp = class:FromInstance(part)
			expect(comp:Greet("world")).is("hello world")
			class:Destroy()
			part:Destroy()
		end)

		test("a method colliding with an own class field errors", function()
			expect(function()
				Component.new {
					Tag = H.uniqueTag(),
					Ancestors = { workspace },
					Methods = { Started = function() end },
				}
			end).fails()
		end)

		test("an extension method colliding with a user method errors", function()
			local ext = { Methods = { Foo = function() end } }
			expect(function()
				Component.new {
					Tag = H.uniqueTag(),
					Ancestors = { workspace },
					Extensions = { ext },
					Methods = { Foo = function() end },
				}
			end).fails()
		end)
	end)

	describe("Component.new with Fields / InitFields", function()
		test("fields are present before Construct and are per-instance copies", function()
			local seenDuringConstruct
			local class = Component.new {
				Tag = H.uniqueTag(),
				Ancestors = { workspace },
				Fields = { Count = 0, Nested = { list = { 1, 2 } } },
				InitFields = function()
					return { Built = {} }
				end,
				Methods = {
					Construct = function(self)
						seenDuringConstruct = self.Count
					end,
				},
			}

			local partA = H.taggedPart(class.Tag)
			local partB = H.taggedPart(class.Tag)
			expect(H.waitStarted(class, partA, 3)).is(true)
			expect(H.waitStarted(class, partB, 3)).is(true)

			local a, b = class:FromInstance(partA), class:FromInstance(partB)
			expect(seenDuringConstruct).is(0)
			expect(a.Instance).is(partA)

			-- Fields are deep-copied, so mutating one instance never touches the
			-- other (or the config table).
			a.Count = 5
			table.insert(a.Nested.list, 3)
			expect(b.Count).is(0)
			expect(#b.Nested.list).is(2)
			expect(a.Nested == b.Nested).is(false)

			-- InitFields runs once per instance.
			expect(a.Built == b.Built).is(false)

			class:Destroy()
			partA:Destroy()
			partB:Destroy()
		end)

		test("fields cannot clobber the bound Instance", function()
			local class = Component.new {
				Tag = H.uniqueTag(),
				Ancestors = { workspace },
				Fields = { Instance = "nope" },
			}
			local part = H.taggedPart(class.Tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(class:FromInstance(part).Instance).is(part)
			class:Destroy()
			part:Destroy()
		end)
	end)
end
