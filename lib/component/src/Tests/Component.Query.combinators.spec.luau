--!nonstrict
--[[
	Builder-normalization, input-validation, and combinator-kind evaluation edges:
	the branches in Build (assertQueryable, queryToNode lowering, withAny collapse/
	flatten), Plan (isEnumerable through combinators, reqInUniverse/reqSatisfied
	over or/and/not kinds), that the behavioral specs never reach because they only
	use direct spellings.
]]

return function(t: any)
	local CollectionService = game:GetService("CollectionService")
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any
	local Query = Component.Query

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local function part(tags): Instance
		local p = Instance.new("Part")
		p.Anchored = true
		for _, tg in tags do
			CollectionService:AddTag(p, tg)
		end
		p.Parent = workspace
		return p
	end

	local function has(list, inst): boolean
		for _, i in list do
			if i == inst then
				return true
			end
		end
		return false
	end

	describe("input validation", function()
		test("every builder rejects a non-queryable argument", function()
			local A = H.makeClass()
			-- assertQueryable / isComponentClass reject numbers, booleans, and plain
			-- tables (no string `.Tag`), in every position.
			expect(function()
				Query(5)
			end).fails()
			expect(function()
				Query(A):with(true)
			end).fails()
			expect(function()
				Query(A):withAny {}
			end).fails()
			expect(function()
				Query(A):without(42)
			end).fails()
			-- Valid kinds pass through (the guard is not over-eager).
			Query("aTag"):_signature()
			Query(A):with(Query.Attr("X")):_signature()

			A:Destroy()
		end)
	end)

	describe("raw-query lowering in atomic positions (queryToNode)", function()
		test("without lowers a raw query by its clause count", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()

			-- Single-clause query -> the lone node.
			local oneClause = Query(A):without(Query(B))
			-- Multi-clause query WITH a negative -> And( positive, Not(negative) ).
			local withNeg = Query(A):without(Query(B):without(C))
			-- An empty query has nothing to lower.
			expect(function()
				Query(A):without(Component.query())
			end).fails()

			local pB = part { aTag, bTag }
			local pBC = part { aTag, bTag, cTag }
			local pA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(pB) and B:Has(pB) and A:Has(pBC) and C:Has(pBC) and A:Has(pA)
			end, 3)).is(true)

			-- without(Query(B)) excludes anything matching B.
			expect(oneClause:contains(pB)).is(false)
			expect(oneClause:contains(pA)).is(true)
			-- without(Query(B):without(C)) excludes (B AND not C): pB out, pBC kept.
			expect(withNeg:contains(pB)).is(false)
			expect(withNeg:contains(pBC)).is(true)
			expect(withNeg:contains(pA)).is(true)

			A:Destroy()
			B:Destroy()
			C:Destroy()
			pB:Destroy()
			pBC:Destroy()
			pA:Destroy()
		end)
	end)

	describe("combinator normalization in withAny", function()
		test("a single-child Or collapses to a required requirement; a multi-child Or flattens", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local dTag = H.uniqueTag()

			-- withAny(Or(B)) == with(B): a one-member group is required.
			local collapsed = Query(A):withAny(Query.Or(B))
			-- withAny(Or(B, C), dTag) flattens the Or's members into the group.
			local flattened = Query(A):withAny(Query.Or(B, C), dTag)

			local pAB = part { aTag, bTag }
			local pAC = part { aTag, cTag }
			local pAD = part { aTag, dTag }
			local pA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(pAB) and B:Has(pAB) and A:Has(pAC) and C:Has(pAC) and A:Has(pAD) and A:Has(pA)
			end, 3)).is(true)

			expect(collapsed:contains(pAB)).is(true)
			expect(collapsed:contains(pAC)).is(false)

			expect(flattened:contains(pAB)).is(true)
			expect(flattened:contains(pAC)).is(true)
			expect(flattened:contains(pAD)).is(true)
			expect(flattened:contains(pA)).is(false)

			A:Destroy()
			B:Destroy()
			C:Destroy()
			pAB:Destroy()
			pAC:Destroy()
			pAD:Destroy()
			pA:Destroy()
		end)
	end)

	describe("filter nodes in positive position", function()
		test("Prop and Pred nodes passed to :with compose like withProperty/where", function()
			local A, aTag = H.makeClass()
			local q = Query(A):with(Query.Prop("Anchored", true)):with(Query.Pred(function(i)
				return i.Name == "Yes"
			end))

			local match = part { aTag }
			match.Name = "Yes"
			local wrongName = part { aTag }
			wrongName.Name = "No"
			expect(H.waitUntil(function()
				return A:Has(match) and A:Has(wrongName)
			end, 3)).is(true)

			local got = q:get()
			expect(#got).is(1)
			expect(has(got, match)).is(true)

			A:Destroy()
			match:Destroy()
			wrongName:Destroy()
		end)
	end)

	describe("enumerability through combinators (validation)", function()
		test("Not makes an anyOf unbounded; And/Or enumerability is computed recursively", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local xTag = H.uniqueTag()

			-- An anyOf alternative that is `Not` is not a candidate source -> unbounded.
			expect(function()
				Component.query():withAny(A, Query.Not(B)):get()
			end).fails()

			-- And is enumerable when ANY child is (its first child here is a filter,
			-- the second a class); a nested Or is enumerable only when EVERY child is,
			-- so an Or with a filter child is NOT a source (but the And still is).
			local boundedAnd = Component.query():withAny(Query.And(Query.Attr("X", 1), B), A)
			local boundedOrInAnd = Component.query():withAny(Query.And(Query.Or(A, Query.Attr("Y", 1)), xTag), A)

			local pB = part { bTag }
			pB:SetAttribute("X", 1)
			local pA = part { aTag }
			expect(H.waitUntil(function()
				return B:Has(pB) and A:Has(pA)
			end, 3)).is(true)

			-- Both validate (no error) and read cold.
			expect(boundedAnd:contains(pB)).is(true)
			expect(boundedAnd:contains(pA)).is(true)
			expect(#boundedOrInAnd:get() >= 1).is(true)

			A:Destroy()
			B:Destroy()
			pB:Destroy()
			pA:Destroy()
		end)
	end)

	describe("combinator requirements under reactive evaluation", function()
		test("nested or/and members track in the candidate universe; a Not negative filters matches", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local xTag = H.uniqueTag()
			local yTag = H.uniqueTag()

			-- anyOf holds And( Or(B, xTag), yTag ) — the nested Or forces reqInUniverse
			-- over the or/and kinds, and an instance missing yTag exercises the
			-- "a required And child is not in the universe" path. A part matching none
			-- of the alternatives exercises the "no alternative satisfied" path.
			local qAny = Query(A):withAny(Query.And(Query.Or(B, xTag), yTag), C)
			local liveAny = {}
			local o1 = qAny:observe(function(i, j)
				liveAny[i] = true
				j:Add(function()
					liveAny[i] = nil
				end)
			end)

			-- negative Not(B): keep only A-instances that DO have B -> reqSatisfied "not".
			local qNot = Query(A):without(Query.Not(B))
			local liveNot = {}
			local o2 = qNot:observe(function(i, j)
				liveNot[i] = true
				j:Add(function()
					liveNot[i] = nil
				end)
			end)

			local pBY = part { aTag, bTag, yTag } -- (B via Or) AND yTag
			local pXY = part { aTag, xTag, yTag } -- (xTag via Or) AND yTag
			local pC = part { aTag, cTag } -- C alternative
			local pB = part { aTag, bTag } -- Or ok but no yTag; no C -> no match
			expect(H.waitUntil(function()
				return A:Has(pBY) and B:Has(pBY) and A:Has(pXY) and A:Has(pC) and C:Has(pC) and A:Has(pB) and B:Has(pB)
			end, 3)).is(true)
			task.wait(0.1)

			expect(liveAny[pBY]).is(true)
			expect(liveAny[pXY]).is(true)
			expect(liveAny[pC]).is(true)
			expect(liveAny[pB]).never_exists() -- Or ok but yTag missing, no C

			expect(liveNot[pBY]).is(true) -- has B -> not excluded
			expect(liveNot[pC]).never_exists() -- no B -> Not(B) true -> excluded

			o1:Disconnect()
			o2:Disconnect()
			A:Destroy()
			B:Destroy()
			C:Destroy()
			pBY:Destroy()
			pXY:Destroy()
			pC:Destroy()
			pB:Destroy()
		end)
	end)

	describe("builder & terminal edge cases", function()
		test("withAny() with no arguments is a no-op that returns an equivalent query", function()
			local A, aTag = H.makeClass()
			local q = Query(A):withAny()
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(q:contains(p)).is(true)
			A:Destroy()
			p:Destroy()
		end)

		test("a where predicate without a recheck signal still activates and disconnects idempotently", function()
			local A, aTag = H.makeClass()
			local gate = true
			-- No recheck signal: the activation's recheck-connect loop skips it.
			local q = Query(A):where(function()
				return gate
			end)
			local live = {}
			local obs = q:observe(function(i)
				live[i] = true
			end)
			local p = part { aTag }
			expect(H.waitUntil(function()
				return live[p] == true
			end, 3)).is(true)

			-- Disconnecting twice is a no-op the second time.
			obs:Disconnect()
			obs:Disconnect()

			A:Destroy()
			p:Destroy()
		end)
	end)
end
