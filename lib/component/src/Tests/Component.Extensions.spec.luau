--!nonstrict
--[[
	Extension system: ShouldConstruct veto, ShouldExtend, topological ordering of
	dependencies, Method binding + collision detection, and the phase barrier
	(hooks run concurrently within a phase; a Promise-returning hook gates the
	component's own method).
]]

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("ShouldConstruct", function()
		test("a vetoing extension prevents construction entirely", function()
			local constructed = false
			local ext = {
				ShouldConstruct = function()
					return false
				end,
			}
			local class, tag = H.makeClass({
				Construct = function()
					constructed = true
				end,
			}, { Extensions = { ext } })
			local part = H.taggedPart(tag)
			task.wait(0.1)
			expect(constructed).is(false)
			expect(class:Has(part)).is(false)
			class:Destroy()
			part:Destroy()
		end)
	end)

	describe("ShouldExtend", function()
		test("hooks of a non-extending extension do not run", function()
			local ran = false
			local ext = {
				ShouldExtend = function()
					return false
				end,
				Constructing = function()
					ran = true
				end,
			}
			local class, tag = H.makeClass({}, { Extensions = { ext } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(ran).is(false)
			class:Destroy()
			part:Destroy()
		end)
	end)

	describe("topological ordering", function()
		test("a dependency's hook runs before the extension that depends on it", function()
			local order = {}
			local depExt = {
				Constructing = function()
					table.insert(order, "dep")
				end,
			}
			local mainExt = {
				Extensions = { depExt },
				Constructing = function()
					table.insert(order, "main")
				end,
			}
			local class, tag = H.makeClass({}, { Extensions = { mainExt } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(order[1]).is("dep")
			expect(order[2]).is("main")
			class:Destroy()
			part:Destroy()
		end)

		test("a dependent hook waits for a yielding dependency to finish", function()
			local order = {}
			local depExt = {
				Starting = function()
					table.insert(order, "dep:begin")
					task.wait(0.05)
					table.insert(order, "dep:end")
				end,
			}
			local mainExt = {
				Extensions = { depExt },
				Starting = function()
					table.insert(order, "main")
				end,
			}
			local class, tag = H.makeClass({}, { Extensions = { mainExt } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(table.concat(order, ",")).is("dep:begin,dep:end,main")
			class:Destroy()
			part:Destroy()
		end)

		test("stop hooks run in reverse dependency order", function()
			local order = {}
			local depExt = {
				Stopping = function()
					table.insert(order, "dep")
				end,
			}
			local mainExt = {
				Extensions = { depExt },
				Stopping = function()
					task.wait(0.05)
					table.insert(order, "main")
				end,
			}
			local class, tag = H.makeClass({}, { Extensions = { mainExt } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			part:Destroy()
			expect(H.waitUntil(function()
				return #order == 2
			end, 3)).is(true)
			expect(order[1]).is("main")
			expect(order[2]).is("dep")
			class:Destroy()
		end)
	end)

	describe("Methods", function()
		test("extension methods are available on the component", function()
			local ext = {
				Methods = {
					Greet = function(self)
						return "hi:" .. self.Instance.Name
					end,
				},
			}
			local class, tag = H.makeClass({}, { Extensions = { ext } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(class:FromInstance(part):Greet()).is("hi:" .. part.Name)
			class:Destroy()
			part:Destroy()
		end)

		test("colliding method names across extensions error at setup", function()
			local e1 = { Methods = { Foo = function() end } }
			local e2 = { Methods = { Foo = function() end } }
			expect(function()
				Component.new { Tag = H.uniqueTag(), Extensions = { e1, e2 } }
			end).fails()
		end)
	end)

	describe("phase barrier", function()
		test("extension hooks within a phase run concurrently", function()
			local active, maxActive = 0, 0
			local function slow()
				active += 1
				maxActive = math.max(maxActive, active)
				task.wait(0.05)
				active -= 1
			end
			local e1 = { Constructing = slow }
			local e2 = { Constructing = slow }
			local class, tag = H.makeClass({}, { Extensions = { e1, e2 } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(maxActive).is(2)
			class:Destroy()
			part:Destroy()
		end)

		test("a Promise-returning hook gates the next phase", function()
			local Promise = require(script.Parent.Parent.Parent.Promise :: any) :: any
			local resolved = false
			local ext = {
				Constructing = function()
					return Promise.new(function(resolve)
						task.delay(0.05, function()
							resolved = true
							resolve()
						end)
					end)
				end,
			}
			local sawResolvedInConstruct = nil
			local class, tag = H.makeClass({
				Construct = function()
					sawResolvedInConstruct = resolved
				end,
			}, { Extensions = { ext } })
			local part = H.taggedPart(tag)
			expect(H.waitStarted(class, part, 3)).is(true)
			expect(sawResolvedInConstruct).is(true)
			class:Destroy()
			part:Destroy()
		end)
	end)
end
