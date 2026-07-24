--!nonstrict
--[[
	Sibling binding: WhileHasComponent / WhileHasComponents run their function
	while the sibling component(s) are present on the same instance, and clean up
	their Janitor when a sibling stops or the owning component stops.
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local H = require(script.Parent.Helpers)

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("WhileHasComponent", function()
		test("runs while the sibling exists and cleans up when it stops", function()
			local ran, cleaned = false, false
			local B, bTag = H.makeClass()
			local A, aTag = H.makeClass {
				Start = function(self)
					self:WhileHasComponent(B, function(sibling, jani)
						ran = sibling ~= nil
						jani:Add(function()
							cleaned = true
						end)
					end)
				end,
			}

			local p = Instance.new("Part")
			p.Anchored = true
			CollectionService:AddTag(p, aTag)
			CollectionService:AddTag(p, bTag)
			p.Parent = workspace

			expect(H.waitUntil(function()
				return ran
			end, 3)).is(true)

			CollectionService:RemoveTag(p, bTag)
			expect(H.waitUntil(function()
				return cleaned
			end, 3)).is(true)

			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)

		test("cleans up when the owning component stops", function()
			local cleaned = false
			local B, bTag = H.makeClass()
			local A, aTag = H.makeClass {
				Start = function(self)
					self:WhileHasComponent(B, function(_, jani)
						jani:Add(function()
							cleaned = true
						end)
					end)
				end,
			}

			local p = Instance.new("Part")
			p.Anchored = true
			CollectionService:AddTag(p, aTag)
			CollectionService:AddTag(p, bTag)
			p.Parent = workspace

			expect(H.waitStarted(A, p, 3)).is(true)
			CollectionService:RemoveTag(p, aTag)
			expect(H.waitUntil(function()
				return cleaned
			end, 3)).is(true)

			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)
	end)

	describe("WhileHasComponents", function()
		test("runs only when all sibling classes are present", function()
			local ran = false
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local A, aTag = H.makeClass {
				Start = function(self)
					self:WhileHasComponents({ B, C }, function(components)
						ran = #components == 2
					end)
				end,
			}

			local p = Instance.new("Part")
			p.Anchored = true
			CollectionService:AddTag(p, aTag)
			CollectionService:AddTag(p, bTag)
			p.Parent = workspace

			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(ran).is(false) -- C not present yet

			CollectionService:AddTag(p, cTag)
			expect(H.waitUntil(function()
				return ran
			end, 3)).is(true)

			A:Destroy()
			B:Destroy()
			C:Destroy()
			p:Destroy()
		end)
	end)
end
