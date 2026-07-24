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

	describe("iter", function()
		test("visits every current match, cold and observed", function()
			local A, aTag = H.makeClass()
			local q = Component.query(A)
			local p1 = part { aTag }
			local p2 = part { aTag }
			expect(H.waitStarted(A, p1, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			-- Cold: falls back to a get() snapshot.
			local seen = {}
			local count = 0
			for inst in q:iter() do
				seen[inst] = true
				count += 1
			end
			expect(count).is(2)
			expect(seen[p1]).is(true)
			expect(seen[p2]).is(true)

			-- Observed: walks the live engine list.
			local obs = q:observe(function() end)
			seen, count = {}, 0
			for inst in q:iter() do
				seen[inst] = true
				count += 1
			end
			expect(count).is(2)
			expect(seen[p1]).is(true)
			expect(seen[p2]).is(true)

			obs:Disconnect()
			A:Destroy()
			p1:Destroy()
			p2:Destroy()
		end)
	end)

	describe("started sparse set", function()
		test("cold GetMatches excludes constructing and stopped components", function()
			local gate = false
			local A, aTag = H.makeClass({
				Construct = function()
					while not gate do
						task.wait()
					end
				end,
			})
			local q = Component.query(A)
			local p = part { aTag }

			-- Constructing (parked in Construct): not a match yet.
			expect(H.waitUntil(function()
				return A:GetLifecycleStatus(p) == "Constructing"
			end, 3)).is(true)
			expect(#q:GetMatches()).is(0)

			gate = true
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(#q:GetMatches()).is(1)
			expect(q:GetMatches()[1]).is(p)

			-- Stopped: gone from the match set again.
			CollectionService:RemoveTag(p, aTag)
			expect(H.waitUntil(function()
				return not A:Has(p)
			end, 3)).is(true)
			expect(#q:GetMatches()).is(0)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("validation", function()
		test("a query with no positive requirement errors", function()
			local Bad = H.makeClass()
			expect(function()
				Component.query():without(Bad):GetMatches()
			end).fails()
		end)

		test("builders are copy-on-write: chains branch independently", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local qA = Component.query(A)
			local withB = qA:with(B)
			local withoutB = qA:without(B)

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return A:Has(p) and B:Has(p)
			end, 3)).is(true)

			-- Deriving never reshaped qA, and the two branches are independent.
			expect(#qA:GetMatches()).is(1)
			expect(#withB:GetMatches()).is(1)
			expect(#withoutB:GetMatches()).is(0)

			A:Destroy()
			B:Destroy()
			p:Destroy()
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

	describe("contains", function()
		test("true only while the instance matches, cold and observed", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local q = Component.query(A):without(B)
			local p = part { aTag }
			local untagged = part {}
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Cold membership test (no candidate enumeration).
			expect(q:contains(p)).is(true)
			expect(q:contains(untagged)).is(false)

			-- Observed: O(1) engine lookup, same answer.
			local obs = q:observe(function() end)
			expect(q:contains(p)).is(true)

			-- Adding the excluded component drops it from the match set.
			CollectionService:AddTag(p, bTag)
			expect(H.waitUntil(function()
				return not q:contains(p)
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
			untagged:Destroy()
		end)
	end)

	describe("count", function()
		test("counts current matches, cold and observed", function()
			local A, aTag = H.makeClass()
			local q = Component.query(A)
			expect(q:count()).is(0)

			local p1 = part { aTag }
			local p2 = part { aTag }
			expect(H.waitStarted(A, p1, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			-- Cold: single-requirement class fast path (#startedList).
			expect(q:count()).is(2)
			expect(q:count()).is(#q:GetMatches())

			-- Observed: O(1) off the engine match list.
			local obs = q:observe(function() end)
			expect(q:count()).is(2)

			obs:Disconnect()
			A:Destroy()
			p1:Destroy()
			p2:Destroy()
		end)

		test("counts a join via the general scan, equal to get()", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local q = Component.query(A, B)
			local both = part { aTag, bTag }
			local onlyA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(both) and B:Has(both) and A:Has(onlyA)
			end, 3)).is(true)

			expect(q:count()).is(1)
			expect(q:count()).is(#q:GetMatches())

			A:Destroy()
			B:Destroy()
			both:Destroy()
			onlyA:Destroy()
		end)
	end)

	describe("first", function()
		test("returns a match or nil, cold and observed", function()
			local A, aTag = H.makeClass()
			local q = Component.query(A)

			-- Empty: nil.
			expect(q:first()).never_exists()

			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Cold: single-requirement class fast path (startedList[1]).
			expect(q:first()).is(p)

			-- Observed: O(1) off the engine.
			local obs = q:observe(function() end)
			expect(q:first()).is(p)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("returns a matching instance on a join via the general scan", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local q = Component.query(A, B)
			local both = part { aTag, bTag }
			local onlyA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(both) and B:Has(both) and A:Has(onlyA)
			end, 3)).is(true)

			-- `both` is the only full match; `onlyA` satisfies just one requirement.
			expect(q:first()).is(both)

			A:Destroy()
			B:Destroy()
			both:Destroy()
			onlyA:Destroy()
		end)
	end)
end
