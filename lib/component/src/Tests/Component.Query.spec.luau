--!nonstrict
--[[
	World-level query engine: joins, exclusion, any-of, tag-string and attribute
	requirements, `where` predicates with a recheck signal, sub-query composition,
	observe/GetMatches, plus GetOrCreateFromInstance and the validation errors.
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- Part carrying an arbitrary set of raw tags, under workspace.
	local function part(tags): Instance
		local p = Instance.new("Part")
		p.Anchored = true
		for _, tg in tags do
			CollectionService:AddTag(p, tg)
		end
		p.Parent = workspace
		return p
	end

	describe("joins and exclusion", function()
		test("observe fires while all required components are started, cleans on unmatch", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local cleaned = false
			local seen = {}

			local obs = Component.query(A, B):observe(function(instance, jani)
				seen[instance] = true
				jani:Add(function()
					cleaned = true
				end)
			end)

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return seen[p] == true
			end, 3)).is(true)

			-- Remove B -> match breaks -> janitor cleans.
			CollectionService:RemoveTag(p, bTag)
			expect(H.waitUntil(function()
				return cleaned
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)

		test("without excludes instances that have the excluded component", function()
			local A, aTag = H.makeClass()
			local Bad, badTag = H.makeClass()
			local live = {} -- live membership: set on match, cleared on unmatch
			local obs = Component.query(A):without(Bad):observe(function(instance, jani)
				live[instance] = true
				jani:Add(function()
					live[instance] = nil
				end)
			end)

			local clean = part { aTag }
			local excluded = part { aTag, badTag }
			-- Wait until Bad has actually started on the excluded part, so any
			-- transient pre-Bad match has resolved to an unmatch.
			expect(H.waitUntil(function()
				return live[clean] == true and Bad:Has(excluded)
			end, 3)).is(true)
			task.wait(0.05)
			expect(live[excluded]).never_exists()
			expect(live[clean]).is(true)

			obs:Disconnect()
			A:Destroy()
			Bad:Destroy()
			clean:Destroy()
			excluded:Destroy()
		end)
	end)

	describe("requirement kinds", function()
		test("a raw tag string is a valid requirement", function()
			local A, aTag = H.makeClass()
			local flammable = H.uniqueTag()
			local matched = {}
			local obs = Component.query(A, flammable):observe(function(instance)
				matched[instance] = true
			end)

			local p = part { aTag, flammable }
			expect(H.waitUntil(function()
				return matched[p] == true
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("withAttribute matches by value and by predicate, reactively", function()
			local A, aTag = H.makeClass()
			local redMatched, lowHpMatched = {}, {}
			local obsRed = Component.query(A):withAttribute("Team", "Red"):observe(function(i)
				redMatched[i] = true
			end)
			local obsHp = Component.query(A)
				:withAttribute("Hp", function(v)
					return type(v) == "number" and v > 0
				end)
				:observe(function(i)
					lowHpMatched[i] = true
				end)

			local p = part { aTag }
			p:SetAttribute("Team", "Blue")
			p:SetAttribute("Hp", 0)
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(redMatched[p]).never_exists()
			expect(lowHpMatched[p]).never_exists()

			p:SetAttribute("Team", "Red")
			p:SetAttribute("Hp", 50)
			expect(H.waitUntil(function()
				return redMatched[p] and lowHpMatched[p]
			end, 3)).is(true)

			obsRed:Disconnect()
			obsHp:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("a sub-query is a valid requirement", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local sub = Component.query(B)
			local matched = {}
			local obs = Component.query(A):with(sub):observe(function(i)
				matched[i] = true
			end)

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return matched[p] == true
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)
	end)

	describe("where + recheck", function()
		test("a where predicate re-evaluates when its recheck signal fires", function()
			local Signal = require(script.Parent.Parent.Parent.Signal :: any) :: any
			local A, aTag = H.makeClass()
			local gate = false
			local recheck = Signal.new()
			local matched = {}
			local obs = Component.query(A)
				:where(function()
					return gate
				end, recheck)
				:observe(function(i)
					matched[i] = true
				end)

			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(matched[p]).never_exists()

			gate = true
			recheck:Fire()
			expect(H.waitUntil(function()
				return matched[p] == true
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("GetMatches (one-shot)", function()
		test("returns currently-matching instances without subscribing", function()
			local A, aTag = H.makeClass()
			local p1 = part { aTag }
			local p2 = part { aTag }
			expect(H.waitStarted(A, p1, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			local matches = Component.query(A):GetMatches()
			local set = {}
			for _, inst in matches do
				set[inst] = true
			end
			expect(set[p1]).is(true)
			expect(set[p2]).is(true)

			A:Destroy()
			p1:Destroy()
			p2:Destroy()
		end)
	end)

	describe("validation", function()
		test("a query with no positive requirement errors", function()
			local Bad = H.makeClass()
			expect(function()
				Component.query():without(Bad):GetMatches()
			end).fails()
		end)

		test("a self-referential query errors", function()
			local A = H.makeClass()
			local q = Component.query(A)
			q:with(q)
			expect(function()
				q:GetMatches()
			end).fails()
		end)
	end)

	describe("GetOrCreateFromInstance", function()
		test("resolves for an already-started component", function()
			local A, aTag = H.makeClass()
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)
			local resolved = A:GetOrCreateFromInstance(p):expect()
			expect(resolved).is(A:FromInstance(p))
			A:Destroy()
			p:Destroy()
		end)

		test("tags and constructs an untagged instance", function()
			local A, tag = H.makeClass()
			local p = Instance.new("Part")
			p.Anchored = true
			p.Parent = workspace
			local comp = A:GetOrCreateFromInstance(p):expect()
			expect(comp).exists()
			expect(CollectionService:HasTag(p, tag)).is(true)
			A:Destroy()
			p:Destroy()
		end)

		test("rejects when ShouldConstruct vetoes", function()
			local ext = {
				ShouldConstruct = function()
					return false
				end,
			}
			local A = H.makeClass({}, { Extensions = { ext } })
			local p = Instance.new("Part")
			p.Anchored = true
			p.Parent = workspace
			local ok = A:GetOrCreateFromInstance(p):await()
			expect(ok).is(false)
			A:Destroy()
			p:Destroy()
		end)
	end)
end
