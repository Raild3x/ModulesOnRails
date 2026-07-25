--!nonstrict
--[[
	Cold-read coverage for the query engine: the one-shot terminals
	(`get`/`GetMatches`/`count`/`first`/`iter`) when NO reactive engine is active,
	plus `Query.Pred` filter nodes and the selectivity-seeding scan. These paths
	are the general cold scan in `Runtime._collect` and the non-class single-source
	reads — the reactive specs never exercise them because an observed query answers
	straight off its engine.

	Each test uses freshly-tagged classes/tags so no structurally-equal query is
	interned elsewhere; that keeps every read on the cold path.
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any
	local Signal = require(script.Parent.Parent.Parent.Signal :: any) :: any
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

	-- tiniest `.is()` compares tables by identity, so assert set membership
	-- element-by-element instead of comparing two freshly-built tables.
	local function expectMatches(got, expected)
		local s = {}
		for _, inst in got do
			s[inst] = true
		end
		expect(#got).is(#expected)
		for _, e in expected do
			expect(s[e]).is(true)
		end
	end

	describe("cold reads on non-class single sources", function()
		test("cold get/count/first/iter on a single raw-tag source", function()
			local tag = H.uniqueTag()
			local q = Query(tag)
			-- Empty first: general scan touches no candidate.
			expect(q:first()).never_exists()
			expect(q:count()).is(0)

			local p1 = part { tag }
			local p2 = part { tag }

			-- get() dumps the tagged set directly (single-source tag branch).
			expectMatches(q:get(), { p1, p2 })
			-- count()/first() take the general scan, NOT the class fast path.
			expect(q:count()).is(2)
			expect(q:first() == p1 or q:first() == p2).is(true)

			-- iter() over the cold snapshot.
			local seen, n = {}, 0
			for inst in q:iter() do
				seen[inst] = true
				n += 1
			end
			expect(n).is(2)
			expect(seen[p1] and seen[p2]).is(true)

			p1:Destroy()
			p2:Destroy()
		end)

		test("cold get/count/first on a single Sub-query source", function()
			local inner = H.uniqueTag()
			local sub = Query(inner)
			local q = Query(Query.Sub(sub))

			local p = part { inner }
			local other = part { H.uniqueTag() }

			-- Single-source query branch: builds the per-call sub memo (ensure/sub).
			expectMatches(q:get(), { p })
			expect(q:count()).is(1)
			expect(q:first()).is(p)
			expect(q:contains(p)).is(true)
			expect(q:contains(other)).is(false)

			p:Destroy()
			other:Destroy()
		end)
	end)

	describe("cold general scan on joins with refinements", function()
		test("cold get on a class join with without/attribute/property/where", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local gate = true

			local q = Query(A, B):without(C):withAttribute("K", 1):withProperty("Anchored", true):where(function()
				return gate
			end)

			local match = part { aTag, bTag } -- full match
			match:SetAttribute("K", 1)
			local excluded = part { aTag, bTag, cTag } -- has C -> excluded
			excluded:SetAttribute("K", 1)
			local wrongAttr = part { aTag, bTag } -- K mismatch
			wrongAttr:SetAttribute("K", 2)

			expect(H.waitUntil(function()
				return A:Has(match) and B:Has(match) and C:Has(excluded) and A:Has(wrongAttr)
			end, 3)).is(true)

			-- Cold general scan: every rest-probe kind runs in `consider`.
			expectMatches(q:get(), { match })
			expect(q:count()).is(1)
			expect(q:first()).is(match)

			-- The where-gate flips the same cold result off.
			gate = false
			expect(#q:get()).is(0)

			A:Destroy()
			B:Destroy()
			C:Destroy()
			match:Destroy()
			excluded:Destroy()
			wrongAttr:Destroy()
		end)

		test("cold get on a join carrying an anyOf group", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local orTag = H.uniqueTag()

			-- Required A, plus (B OR orTag).
			local q = Query(A):withAny(B, orTag)

			local viaB = part { aTag, bTag }
			local viaTag = part { aTag, orTag }
			local neither = part { aTag }

			expect(H.waitUntil(function()
				return A:Has(viaB) and B:Has(viaB) and A:Has(viaTag) and A:Has(neither)
			end, 3)).is(true)

			expectMatches(q:get(), { viaB, viaTag })
			expect(q:count()).is(2)

			A:Destroy()
			B:Destroy()
			viaB:Destroy()
			viaTag:Destroy()
			neither:Destroy()
		end)
	end)

	describe("cold selectivity seeding (tag sizing)", function()
		test("a multi-tag join sizes tags, orders probes, and matches", function()
			local t1, t2, t3 = H.uniqueTag(), H.uniqueTag(), H.uniqueTag()
			local q = Query(t1, t2, t3)

			local all = part { t1, t2, t3 }
			local some = part { t1, t2 }
			local one = part { t1 }

			-- No class seed -> live tag sizing picks the narrowest tag, then probes
			-- the rest most-selective-first (multiple probes -> the sort runs).
			expectMatches(q:get(), { all })
			expect(q:count()).is(1)
			expect(q:first()).is(all)

			all:Destroy()
			some:Destroy()
			one:Destroy()
		end)

		test("a large tag population is converted to a hash-set probe", function()
			-- Populations above TAG_SIZING_EARLY_EXIT (32) skip the early exit, so
			-- sizing fetches every tag and the seed*3 > population rule converts a
			-- probe tag into a membership set instead of repeated HasTag calls.
			local t1, t2 = H.uniqueTag(), H.uniqueTag()
			local q = Query(t1, t2)
			local parts = {}
			-- 40 carry both tags (all match); 40 carry only t1 (fail the t2 probe).
			for i = 1, 40 do
				table.insert(parts, part { t1, t2 })
			end
			for i = 1, 40 do
				table.insert(parts, part { t1 })
			end

			expect(q:count()).is(40)

			for _, p in parts do
				p:Destroy()
			end
		end)
	end)

	describe("cold enumeration of a combinator source", function()
		test("an anyOf-only query whose member is an And enumerates via its narrowest child", function()
			local A, aTag = H.makeClass()
			local andTag = H.uniqueTag()
			local B, bTag = H.makeClass()

			-- No required source; the candidate set is the union of the anyOf group,
			-- one member of which is an And node enumerated through its class child.
			local q = Query():withAny(Query.And(A, andTag), B)

			local viaAnd = part { aTag, andTag }
			local viaB = part { bTag }
			local andMissingTag = part { aTag } -- A but not andTag -> no match

			expect(H.waitUntil(function()
				return A:Has(viaAnd) and B:Has(viaB) and A:Has(andMissingTag)
			end, 3)).is(true)

			expectMatches(q:get(), { viaAnd, viaB })

			A:Destroy()
			B:Destroy()
			viaAnd:Destroy()
			viaB:Destroy()
			andMissingTag:Destroy()
		end)
	end)

	describe("Query.Pred filter node", function()
		test("a Pred node in an anyOf group matches and reacts to its recheck signal", function()
			local A, aTag = H.makeClass()
			local D, dTag = H.makeClass()
			local gate = false
			local recheck = Signal.new()
			-- Required D, plus (A OR pred). A part with D and no A must satisfy the
			-- group through the predicate branch alone.
			local pred = Query.Pred(function()
				return gate
			end, recheck)
			local q = Query(D):withAny(A, pred)

			local viaPred = part { dTag }
			expect(H.waitStarted(D, viaPred, 3)).is(true)

			-- Cold: computes a signature over the Pred node and scans; no match yet.
			expect(q:contains(viaPred)).is(false)
			expect(#q:get()).is(0)

			-- Reactive: the recheck signal drives the Pred branch true.
			local live = {}
			local obs = q:observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)
			gate = true
			recheck:Fire()
			expect(H.waitUntil(function()
				return live[viaPred] == true
			end, 3)).is(true)

			obs:Disconnect()
			A:Destroy()
			D:Destroy()
			viaPred:Destroy()
		end)
	end)

	describe("error tolerance in user predicates and matchers", function()
		test("erroring where/matcher/Pred are caught and treated as no-match, cold", function()
			local A, aTag = H.makeClass()
			local absentTag = H.uniqueTag()

			-- Erroring :where predicate — caught, warned, counts as false.
			local qWhere = Query(A):where(function()
				error("bad predicate")
			end)
			-- Erroring attribute function-matcher — caught, warned, matcher fails.
			local qAttr = Query(A):withAttribute("K", function()
				error("bad matcher")
			end)
			-- Erroring Pred node evaluated via reqSatisfied inside an anyOf group
			-- whose other alternative (absentTag) is not present.
			local qCombo = Query(A):withAny(
				Query.Pred(function()
					error("bad pred node")
				end),
				absentTag
			)

			local p = part { aTag }
			p:SetAttribute("K", 1)
			expect(H.waitStarted(A, p, 3)).is(true)

			-- None crash; each erroring clause resolves to "no match".
			expect(#qWhere:get()).is(0)
			expect(#qAttr:get()).is(0)
			expect(#qCombo:get()).is(0)

			A:Destroy()
			p:Destroy()
		end)

		test("an erroring unyielding seed callback is reported, not crashed", function()
			local A, aTag = H.makeClass()
			local q = Query(A)
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Errors DURING the seed batch — pcall-isolated, reported loudly, and the
			-- Disconnect still succeeds.
			local obs = q:observeUnyielding(function()
				error("boom in seed callback")
			end)
			obs:Disconnect()

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("reactive seeding edges", function()
		test("observeUnyielding seeds over pre-existing matches", function()
			local A, aTag = H.makeClass()
			local q = Query(A)
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)

			-- The match exists BEFORE subscribing, so the seed loop (one shared
			-- coroutine) fires the callback for it.
			local seen = {}
			local obs = q:observeUnyielding(function(instance)
				seen[instance] = true
			end)
			expect(seen[p]).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("a yielding seed callback is reported loudly, not silently swallowed", function()
			local ScriptContext = game:GetService("ScriptContext")
			local A, aTag = H.makeClass()
			local q = Query(A)
			local p = part { aTag }
			expect(H.waitStarted(A, p, 3)).is(true)

			local caught = nil
			local conn = ScriptContext.Error:Connect(function(message)
				if type(message) == "string" and string.find(message, "YIELDED", 1, true) then
					caught = message
				end
			end)
			-- Yields DURING the seed batch -> the shared coroutine survives the resume,
			-- which is the violation the reporter fires on.
			local obs = q:observeUnyielding(function()
				task.wait(0.05)
			end)
			H.waitUntil(function()
				return caught ~= nil
			end, 2)
			conn:Disconnect()
			expect(caught ~= nil).is(true)

			obs:Disconnect()
			A:Destroy()
			p:Destroy()
		end)

		test("observing the same query instance twice reuses its attached engine", function()
			local A, aTag = H.makeClass()
			local q = Query(A)
			local p = part { aTag }

			local a, b = {}, {}
			local o1 = q:observe(function(i)
				a[i] = true
			end)
			-- Second observe on the SAME instance: self._engine is already attached.
			local o2 = q:observe(function(i)
				b[i] = true
			end)

			expect(H.waitUntil(function()
				return a[p] == true and b[p] == true
			end, 3)).is(true)

			-- One observer leaving must not tear the shared engine down.
			o1:Disconnect()
			local p2 = part { aTag }
			expect(H.waitUntil(function()
				return b[p2] == true
			end, 3)).is(true)

			o2:Disconnect()
			A:Destroy()
			p:Destroy()
			p2:Destroy()
		end)

		test("a Sub-query parent seeds from the sub engine's existing matches", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local sub = Query(B)
			local q = Query(A):with(Query.Sub(sub))

			-- The match exists BEFORE the parent activates, so the parent's seed
			-- enumeration reads it out of the already-live sub engine's match list.
			local p = part { aTag, bTag }
			-- Prime the sub engine so it already holds `p` at parent-activation time.
			local subHold = sub:track()
			expect(H.waitUntil(function()
				return sub:contains(p)
			end, 3)).is(true)

			local live = {}
			local obs = q:observe(function(i, jani)
				live[i] = true
				jani:Add(function()
					live[i] = nil
				end)
			end)
			expect(H.waitUntil(function()
				return live[p] == true
			end, 3)).is(true)

			obs:Disconnect()
			subHold:Disconnect()
			A:Destroy()
			B:Destroy()
			p:Destroy()
		end)
	end)

	describe("compose-by-value invariants", function()
		-- A raw Query is a valid Queryable ANYWHERE, including nested inside a
		-- combinator in an atomic (withAny / without) position. There, normalization
		-- does NOT splice it — `normalizeAnyMember` leaves combinator children
		-- untouched — so it survives in a requirement list and is compiled and
		-- evaluated as a by-value sub-query, indistinguishable from wrapping it in
		-- `Query.Sub`. These nested shapes are the ONLY ones that reach the
		-- raw-Query arms of compileReq / _signature / _enumerate; the direct
		-- spellings always splice or lower first. Both invariants are asserted
		-- across a battery of shapes in one test each to keep the noise down.

		local function matchSet(q)
			local set = {}
			for _, inst in q:get() do
				set[inst] = true
			end
			return set
		end

		test("a raw Query nested in a combinator == the same shape via Query.Sub", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local C, cTag = H.makeClass()
			local inner = Query(B):withAttribute("X", 1)

			-- Each pair is (raw-nested, Sub-nested) and must be indistinguishable in
			-- both structural signature and match set.
			local cases = {
				{
					Query():withAny(Query.And(inner, aTag), C),
					Query():withAny(Query.And(Query.Sub(inner), aTag), C),
				},
				{
					Query(A):without(Query.Or(inner, C)),
					Query(A):without(Query.Or(Query.Sub(inner), C)),
				},
			}

			-- Shared world: pAnd satisfies (inner AND aTag); pC has C; pExcluded has
			-- A and inner (excluded by the without cases); pA has A alone.
			local pAnd = part { aTag, bTag }
			pAnd:SetAttribute("X", 1)
			local pC = part { cTag }
			local pExcluded = part { aTag, bTag }
			pExcluded:SetAttribute("X", 1)
			local pA = part { aTag }
			expect(H.waitUntil(function()
				return A:Has(pA) and A:Has(pExcluded) and B:Has(pAnd) and B:Has(pExcluded) and C:Has(pC)
			end, 3)).is(true)

			for _, spellings in cases do
				local raw, sub = spellings[1], spellings[2]
				-- Same structural signature -> they intern to one engine.
				expect(raw:_signature()).is(sub:_signature())
				-- Same match set, cold (both non-vacuous).
				local rawGet = raw:get()
				expect(#rawGet > 0).is(true)
				expect(#rawGet).is(#sub:get())
				local subSet = matchSet(sub)
				for _, inst in rawGet do
					expect(subSet[inst]).is(true)
				end
				-- count() agrees with get() on the same shape.
				expect(raw:count()).is(#rawGet)
			end

			A:Destroy()
			B:Destroy()
			C:Destroy()
			pAnd:Destroy()
			pC:Destroy()
			pExcluded:Destroy()
			pA:Destroy()
		end)

		test("the compiled plan keeps only enumerable sources in `required`", function()
			-- required holds only class / tag / sub-query source kinds; combinators
			-- live in anyOf / negative and filters in the attribute/property/predicate
			-- fast paths, never in required. Checked across representative shapes.
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local sourceKinds = { class = true, tag = true, query = true }

			local shapes = {
				Query(A, B),
				Query(A, aTag):with(Query.Sub(Query(B))),
				Query(A):withAny(B, Query.And(A, B)),
				Query(A):without(Query.Or(B, aTag)):withAttribute("K", 1):where(function()
					return true
				end),
			}
			for _, q in shapes do
				local plan = q:_plan()
				for _, req in plan.required do
					expect(sourceKinds[req.kind] == true).is(true)
				end
			end

			A:Destroy()
			B:Destroy()
		end)
	end)
end
