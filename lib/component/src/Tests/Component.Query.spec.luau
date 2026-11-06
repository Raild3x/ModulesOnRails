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
				:withAttribute("Hp", function(_, v)
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

		test("withProperty matches by value and by predicate, reactively", function()
			local A, aTag = H.makeClass()
			local namedMatched, clearMatched = {}, {}
			local obsName = Component.query(A):withProperty("Name", "Target"):observe(function(i)
				namedMatched[i] = true
			end)
			local obsClear = Component.query(A)
				:withProperty("Transparency", function(_, v)
					return type(v) == "number" and v > 0.5
				end)
				:observe(function(i)
					clearMatched[i] = true
				end)

			local p = part { aTag }
			p.Name = "Other"
			p.Transparency = 0
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(namedMatched[p]).never_exists()
			expect(clearMatched[p]).never_exists()

			p.Name = "Target"
			p.Transparency = 0.8
			expect(H.waitUntil(function()
				return namedMatched[p] and clearMatched[p]
			end, 3)).is(true)

			obsName:Disconnect()
			obsClear:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("withProperty with no matcher requires the property merely exists", function()
			local A, aTag = H.makeClass()
			local matched = {}
			-- Parts have `Anchored`; the void matcher is a pure existence check.
			local obs = Component.query(A):withProperty("Anchored"):observe(function(i)
				matched[i] = true
			end)

			local p = part { aTag }
			expect(H.waitUntil(function()
				return matched[p] == true
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("withProperty with an explicit nil matcher matches only while the property is nil", function()
			-- Use an ObjectValue whose nillable `.Value` is unrelated to ancestry
			-- (nil-parenting a Part would instead stop the component by leaving its
			-- ancestor list, muddying what's being tested).
			local A, aTag = H.makeClass()
			local live = {}
			local obs = Component.query(A):withProperty("Value", nil):observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)

			local ov = Instance.new("ObjectValue")
			CollectionService:AddTag(ov, aTag)
			local target = Instance.new("Folder")
			ov.Value = target -- starts non-nil -> no match
			ov.Parent = workspace
			expect(H.waitStarted(A, ov, 3)).is(true)
			task.wait(0.1)
			expect(live[ov]).never_exists()

			ov.Value = nil
			expect(H.waitUntil(function()
				return live[ov] == true
			end, 3)).is(true)

			ov.Value = target
			expect(H.waitUntil(function()
				return live[ov] == nil
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			ov:Destroy()
			target:Destroy()
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

	describe("observeUnyielding", function()
		-- Captures unhandled errors (including those the reporter raises on a
		-- fresh thread) whose message contains `needle`, for the duration of `fn`.
		local function captureError(needle, fn)
			local ScriptContext = game:GetService("ScriptContext")
			local caught = nil
			local conn = ScriptContext.Error:Connect(function(message)
				if type(message) == "string" and string.find(message, needle, 1, true) then
					caught = message
				end
			end)
			fn()
			H.waitUntil(function()
				return caught ~= nil
			end, 2)
			conn:Disconnect()
			return caught
		end

		test("fires inline for current and future matches, cleans on unmatch", function()
			local A, aTag = H.makeClass()
			local live = {}
			local obs = Component.query(A):observeUnyielding(function(instance, jani)
				live[instance] = true
				jani:Add(function()
					live[instance] = nil
				end)
			end)

			local p = part { aTag }
			expect(H.waitUntil(function()
				return live[p] == true
			end, 3)).is(true)

			CollectionService:RemoveTag(p, aTag)
			expect(H.waitUntil(function()
				return live[p] == nil
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("a yielding callback is reported loudly and does not break sibling observers", function()
			local A, aTag = H.makeClass()
			local siblingSaw = false
			-- Sibling observer registered FIRST so it dispatches before the
			-- offending one on the same match event.
			local sibling = Component.query(A):observe(function()
				siblingSaw = true
			end)

			local message = captureError("observeUnyielding() callback YIELDED", function()
				local bad = Component.query(A):observeUnyielding(function()
					task.wait(0.05) -- contract violation
				end)
				local p = part { aTag }
				expect(H.waitStarted(A, p, 3)).is(true)
				task.wait(0.1)
				bad:Disconnect()
				p:Destroy()
			end)
			expect(message).exists()
			expect(siblingSaw).is(true)

			sibling:Disconnect()
			A:Destroy()
		end)

		test("an erroring callback is reported loudly and is isolated", function()
			local A, aTag = H.makeClass()
			local goodSaw = false
			local good = Component.query(A):observeUnyielding(function()
				goodSaw = true
			end)

			local message = captureError("observeUnyielding() callback errored", function()
				local bad = Component.query(A):observeUnyielding(function()
					error("boom in observer")
				end)
				local p = part { aTag }
				expect(H.waitStarted(A, p, 3)).is(true)
				task.wait(0.1)
				bad:Disconnect()
				p:Destroy()
			end)
			expect(message).exists()
			expect(goodSaw).is(true)

			good:Disconnect()
			A:Destroy()
		end)
	end)

	describe("track", function()
		test("a tracked query maintains a join across live adds and removes", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local q = Component.query(A):with(B)
			local tracked = q:track()

			local function has(inst)
				for _, m in q:GetMatches() do
					if m == inst then
						return true
					end
				end
				return false
			end

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return has(p)
			end, 3)).is(true)
			expect(q:contains(p)).is(true)
			expect(q:count()).is(1)

			-- Removing a required component drops it from the maintained set.
			CollectionService:RemoveTag(p, bTag)
			expect(H.waitUntil(function()
				return not has(p)
			end, 3)).is(true)
			expect(q:contains(p)).is(false)

			tracked:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)

		test("Disconnect releases the engine; reads still work cold", function()
			local A, aTag = H.makeClass()
			local q = Component.query(A)
			local tracked = q:track()
			local p = part { aTag }
			expect(H.waitUntil(function()
				return q:contains(p)
			end, 3)).is(true)

			tracked:Disconnect()
			expect(tracked.IsConnected).is(false)
			-- Cold read (no engine) still reports the current truth.
			expect(#q:GetMatches()).is(1)
			expect(q:GetMatches()[1]).is(p)

			-- Disconnect is idempotent.
			tracked:Disconnect()

			A:Destroy()
			p:Destroy()
		end)

		test("a tracked query and an observer of the same shape share one engine", function()
			local A, aTag = H.makeClass()
			local tracked = Component.query(A):track()
			local seen = {}
			local obs = Component.query(A):observe(function(i)
				seen[i] = true
			end)

			local p = part { aTag }
			-- The observer fires (engine is shared/eager) and the tracked read sees it.
			expect(H.waitUntil(function()
				return seen[p] == true
			end, 3)).is(true)
			expect(Component.query(A):contains(p)).is(true)

			obs:Disconnect()
			-- Engine survives on the tracker; reads stay correct.
			expect(Component.query(A):contains(p)).is(true)
			tracked:Disconnect()
			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("started sparse set", function()
		test("cold GetMatches excludes constructing and stopped components", function()
			local gate = false
			local A, aTag = H.makeClass {
				Construct = function()
					while not gate do
						task.wait()
					end
				end,
			}
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

	describe("composable nodes", function()
		local Query = Component.Query

		test("the module is callable and exposes static node constructors", function()
			local A, aTag = H.makeClass()
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Query(...) == Query.new(...); Component.query is the same module.
			expect(#Query(A):get()).is(1)
			expect(Component.query).is(Query)
			expect(type(Query.Attr)).is("function")
			expect(type(Query.Or)).is("function")
			expect(type(Query.Not)).is("function")

			A:Destroy()
			p:Destroy()
		end)

		test("Attr nodes work in with/without/withAny, reactively", function()
			local A, aTag = H.makeClass()
			local redLive, notRedLive, eitherLive = {}, {}, {}
			local obsRed = Query(A):with(Query.Attr("Team", "Red")):observe(function(i, jani)
				redLive[i] = true
				jani:Add(function()
					redLive[i] = nil
				end)
			end)
			local obsNotRed = Query(A):without(Query.Attr("Team", "Red")):observe(function(i, jani)
				notRedLive[i] = true
				jani:Add(function()
					notRedLive[i] = nil
				end)
			end)
			local obsEither = Query(A)
				:withAny(Query.Attr("Team", "Red"), Query.Attr("Team", "Blue"))
				:observe(function(i, jani)
					eitherLive[i] = true
					jani:Add(function()
						eitherLive[i] = nil
					end)
				end)

			local p = part { aTag }
			p:SetAttribute("Team", "Green")
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(redLive[p]).never_exists()
			expect(notRedLive[p]).is(true) -- Green is not Red
			expect(eitherLive[p]).never_exists()

			p:SetAttribute("Team", "Red")
			expect(H.waitUntil(function()
				return redLive[p] and eitherLive[p] and not notRedLive[p]
			end, 3)).is(true)

			p:SetAttribute("Team", "Blue")
			expect(H.waitUntil(function()
				return not redLive[p] and eitherLive[p] and notRedLive[p]
			end, 3)).is(true)

			obsRed:Disconnect()
			obsNotRed:Disconnect()
			obsEither:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("without(Prop) expresses property ABSENCE (class lacks the property)", function()
			local A, aTag = H.makeClass()
			local live = {}
			-- Parts have no PrimaryPart property; Models do (even when nil-valued).
			local obs = Query(A):without(Query.Prop("PrimaryPart")):observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)

			local p = part { aTag }
			local model = Instance.new("Model")
			CollectionService:AddTag(model, aTag)
			model.Parent = workspace
			expect(H.waitUntil(function()
				return A:Has(p) and A:Has(model)
			end, 3)).is(true)
			task.wait(0.1)

			expect(live[p]).is(true) -- Part lacks PrimaryPart -> absence matches
			expect(live[model]).never_exists() -- Model HAS the property (nil-valued counts as present)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
			model:Destroy()
		end)

		test("any-of matcher lists pass (instance, value) to predicates", function()
			local A, aTag = H.makeClass()
			local sawInstance, sawValue = nil, nil
			local live = {}
			local obs = Query(A):withProperty("Name", "Alpha", function(i, v)
				sawInstance, sawValue = i, v
				return v == "Zed"
			end):observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)

			local p = part { aTag }
			p.Name = "Other"
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(live[p]).never_exists()
			-- The predicate branch ran and received both arguments.
			expect(sawInstance).is(p)
			expect(sawValue).is("Other")

			p.Name = "Alpha" -- first value matcher
			expect(H.waitUntil(function()
				return live[p] == true
			end, 3)).is(true)
			p.Name = "Zed" -- predicate matcher
			task.wait(0.1)
			expect(live[p]).is(true)
			p.Name = "Miss"
			expect(H.waitUntil(function()
				return live[p] == nil
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("And/Or/Not nest and react to nested clause flips", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local sectionLive, orLive = {}, {}
			-- Negate a whole section: A minus (B AND Locked=true).
			local obsSection = Query(A):without(Query.And(B, Query.Attr("Locked", true))):observe(function(i, jani)
				sectionLive[i] = true
				jani:Add(function()
					sectionLive[i] = nil
				end)
			end)
			-- Or mixes a filter with a component requirement.
			local obsOr = Query(A):with(Query.Or(Query.Attr("Flag", 1), B)):observe(function(i, jani)
				orLive[i] = true
				jani:Add(function()
					orLive[i] = nil
				end)
			end)

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return A:Has(p) and B:Has(p)
			end, 3)).is(true)
			task.wait(0.1)
			expect(sectionLive[p]).is(true) -- B started but not Locked
			expect(orLive[p]).is(true) -- B satisfies the Or

			p:SetAttribute("Locked", true)
			expect(H.waitUntil(function()
				return sectionLive[p] == nil
			end, 3)).is(true)

			CollectionService:RemoveTag(p, bTag)
			expect(H.waitUntil(function()
				return orLive[p] == nil -- B gone and Flag unset -> Or fails
			end, 3)).is(true)
			p:SetAttribute("Flag", 1)
			expect(H.waitUntil(function()
				return orLive[p] == true -- attr branch of the Or
			end, 3)).is(true)

			obsSection:Disconnect()
			obsOr:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)

		test("structurally equal composed queries share one interned engine", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local live1, live2 = {}, {}
			-- Same requirements, reordered combinator children AND reordered matchers.
			local q1 = Query(A):with(Query.Or(Query.Attr("Team", "Red", "Blue"), B))
			local q2 = Query(A):with(Query.Or(B, Query.Attr("Team", "Blue", "Red")))
			local obs1 = q1:observe(function(i, jani)
				live1[i] = true
				jani:Add(function()
					live1[i] = nil
				end)
			end)
			local obs2 = q2:observe(function(i, jani)
				live2[i] = true
				jani:Add(function()
					live2[i] = nil
				end)
			end)

			local p = part { aTag, bTag }
			expect(H.waitUntil(function()
				return live1[p] == true and live2[p] == true
			end, 3)).is(true)

			-- Shared engine: disconnecting one observer must not kill the other's
			-- reactivity (refcounted interning).
			obs1:Disconnect()
			p:SetAttribute("Team", "Red")
			CollectionService:RemoveTag(p, bTag)
			expect(H.waitUntil(function()
				return live2[p] == true -- attr branch still satisfies the Or
			end, 3)).is(true)
			p:SetAttribute("Team", "Green")
			expect(H.waitUntil(function()
				return live2[p] == nil
			end, 3)).is(true)

			obs2:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)

		test("queries with no enumerable source error", function()
			local A = H.makeClass()
			-- Filter-only, Not-only, and Or-with-unbounded-branch are all unbounded.
			expect(function()
				Query(Query.Attr("X", 1)):get()
			end).fails()
			expect(function()
				Query(Query.Not(A)):get()
			end).fails()
			expect(function()
				Query(Query.Or(A, Query.Attr("X", 1))):get()
			end).fails()
			-- An And with one bounded child is fine.
			expect(#Query(Query.And(A, Query.Attr("X", 1))):get()).is(0)
			A:Destroy()
		end)
	end)

	describe("composition unification", function()
		local Query = Component.Query

		test("Query(q1):with(B) is literally q1:with(B) (compose by value)", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local q1 = Query(A)
			local nestedSpelling = Query(q1):with(B)
			local chainedSpelling = q1:with(B)

			-- One internal form: identical signatures, so they intern together.
			expect(nestedSpelling:_signature()).is(chainedSpelling:_signature())

			local pBoth = part { aTag, bTag }
			local pA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(pBoth) and B:Has(pBoth) and A:Has(pA)
			end, 3)).is(true)

			for _, q in { nestedSpelling, chainedSpelling } do
				expect(q:contains(pBoth)).is(true)
				expect(q:contains(pA)).is(false)
				expect(q:count()).is(1)
			end

			A:Destroy()
			B:Destroy()
			pBoth:Destroy()
			pA:Destroy()
		end)

		test("equivalent spellings converge to one signature", function()
			local A = H.makeClass()
			local B = H.makeClass()
			local C = H.makeClass()

			expect(Query(A, Query.And(B, C)):_signature()).is(Query(A, B, C):_signature())
			expect(Query(A):with(Query.Or(B, C)):_signature()).is(Query(A):withAny(B, C):_signature())
			expect(Query(A):with(Query.Not(B)):_signature()).is(Query(A):without(B):_signature())
			expect(Query(A, Query.Attr("D", 1)):_signature()).is(Query(A):withAttribute("D", 1):_signature())
			expect(Query(A, A):_signature()).is(Query(A):_signature())

			A:Destroy()
			B:Destroy()
			C:Destroy()
		end)

		test("a query in without/withAny stays atomic (De Morgan)", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local dTag = H.uniqueTag()
			local sub = Query(B):with(C)

			local pB = part { aTag, bTag }
			local pBC = part { aTag, bTag, cTag }
			local pD = part { aTag, dTag }
			expect(H.waitUntil(function()
				return A:Has(pB) and B:Has(pB) and A:Has(pBC) and B:Has(pBC) and C:Has(pBC) and A:Has(pD)
			end, 3)).is(true)

			-- without(sub) excludes only instances matching ALL of sub, not any part.
			local qWithout = Query(A):without(sub)
			expect(qWithout:contains(pB)).is(true) -- has B alone: not (B and C)
			expect(qWithout:contains(pBC)).is(false)

			-- withAny(sub, tag): sub is one atomic alternative.
			local qAny = Query(A):withAny(sub, dTag)
			expect(qAny:contains(pBC)).is(true)
			expect(qAny:contains(pD)).is(true)
			expect(qAny:contains(pB)).is(false)

			A:Destroy()
			B:Destroy()
			C:Destroy()
			pB:Destroy()
			pBC:Destroy()
			pD:Destroy()
		end)

		test("splicing can bound an otherwise unbounded query", function()
			local A, aTag = H.makeClass()
			local filterOnly = Query():withAttribute("Powered", true)
			-- Standalone it is unbounded and errors...
			expect(function()
				filterOnly:get()
			end).fails()
			-- ...but composed by value, the class bounds the spliced clauses.
			local q = Query(filterOnly):with(A)
			local pOn = part { aTag }
			pOn:SetAttribute("Powered", true)
			local pOff = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(pOn) and A:Has(pOff)
			end, 3)).is(true)
			expect(q:contains(pOn)).is(true)
			expect(q:contains(pOff)).is(false)

			A:Destroy()
			pOn:Destroy()
			pOff:Destroy()
		end)

		test("Query.Sub composes by reference with identical matching, reactively", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local sub = Query(B):with(C)
			local byValue = Query(A):with(sub)
			local byRef = Query(A):with(Query.Sub(sub))

			local live = {}
			local obs = byRef:observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)

			local p = part { aTag, bTag, cTag }
			expect(H.waitUntil(function()
				return live[p] == true
			end, 3)).is(true)
			expect(byValue:contains(p)).is(true)

			-- Sub-driven unmatch propagates to the by-reference parent.
			CollectionService:RemoveTag(p, cTag)
			expect(H.waitUntil(function()
				return live[p] == nil
			end, 3)).is(true)
			expect(byValue:contains(p)).is(false)

			obs:Disconnect()
			A:Destroy()
			B:Destroy()
			C:Destroy()
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
